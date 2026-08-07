import XCTest
import AVFoundation
import CoreGraphics
@testable import MediaMeasure

/// The web-deliverable tier: `ImageQualityTarget.encodePNG` (lossless universal still) and
/// `VideoQualityTarget.EncodeProfile.webH264` (H.264 + AAC in mp4 — the one combination every
/// browser decodes). The delivery rule difference under test: a format *conversion* delivers even
/// when larger than the source; the quality floor is never waived.
final class WebDeliverableTests: XCTestCase {

    // MARK: - encodePNG

    /// A small (fast to score), moderately-compressible image: gradient base + mild deterministic noise.
    private func makeImage(_ n: Int = 96) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n { for x in 0..<n {
            let noise = ((x * 131 + y * 57) % 64) - 32
            let i = (y * n + x) * 4
            bytes[i] = UInt8(clamping: x * 2 + noise)
            bytes[i + 1] = UInt8(clamping: y * 2 + noise)
            bytes[i + 2] = UInt8(clamping: 128 + noise)
            bytes[i + 3] = 255
        } }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    /// The score is measured on the round-trip, and for an 8-bit sRGB source the round-trip is
    /// lossless — the measurement must actually say so (≈100), not merely "high".
    func testEncodePNGRoundTripIsLosslessAndMeasured() throws {
        let img = makeImage()
        let r = try ImageQualityTarget.encodePNG(img)
        XCTAssertGreaterThan(r.data.count, 0)
        XCTAssertGreaterThanOrEqual(r.score, 99.5, "8-bit sRGB → PNG round-trip must measure lossless")

        // The bytes really are a decodable PNG of the same geometry.
        let src = CGImageSourceCreateWithData(r.data as CFData, nil)
        let type = src.flatMap { CGImageSourceGetType($0) } as String?
        XCTAssertEqual(type, "public.png")
        let decoded = try XCTUnwrap(src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(decoded.width, img.width)
        XCTAssertEqual(decoded.height, img.height)
    }

    // MARK: - webH264 video profile

    /// HEVC + ALAC source → web profile must deliver an H.264 + AAC mp4 (both tracks re-coded).
    /// Delivery must track ONLY the floor (`requireSmaller: false`): whichever way the size falls,
    /// `delivered == metTarget` — the conversion is the point even when the mp4 is larger.
    func testWebProfileDeliversH264WithAACAudio() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("web-src-\(UUID().uuidString).mov")
        let out = tmp.appendingPathComponent("web-out-\(UUID().uuidString).mp4")
        defer { [src, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeClip(at: src, w: 320, h: 240, frames: 30,
                     videoCodec: .hevc, audioFormatID: kAudioFormatAppleLossless)

        let r = try await VideoQualityTarget.encode(input: src, output: out, targetScore: 70,
                                                    iterations: 3, profile: .webH264)
        XCTAssertTrue(r.metTarget, "floor 70 must be reachable on compressible content")
        XCTAssertEqual(r.delivered, r.metTarget,
                       "web delivery ignores size — the floor is the only gate")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))

        let asset = AVURLAsset(url: out)
        let vtracks = try await asset.loadTracks(withMediaType: .video)
        let vfmts = try await XCTUnwrap(vtracks.first).load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(vfmts.first)),
                       kCMVideoCodecType_H264, "web video must be H.264")
        let atracks = try await asset.loadTracks(withMediaType: .audio)
        let afmts = try await XCTUnwrap(atracks.first).load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(afmts.first)),
                       kAudioFormatMPEG4AAC, "non-AAC source audio must be re-encoded to AAC for the web")
    }

    /// AAC source audio under the web profile must passthrough (no generation loss), not re-encode.
    /// Passthrough vs re-encode is invisible in the codec ID, so this gates on the untouched
    /// audio bitstream: identical audio sample-data byte counts source → output.
    func testWebProfilePassesThroughAACAudio() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("web-aac-src-\(UUID().uuidString).mp4")
        let out = tmp.appendingPathComponent("web-aac-out-\(UUID().uuidString).mp4")
        defer { [src, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeClip(at: src, w: 320, h: 240, frames: 30,
                     videoCodec: .hevc, audioFormatID: kAudioFormatMPEG4AAC)

        let r = try await VideoQualityTarget.encode(input: src, output: out, targetScore: 70,
                                                    iterations: 3, profile: .webH264)
        XCTAssertTrue(r.delivered)
        let srcAudio = try await audioSampleBytes(URL(fileURLWithPath: src.path))
        let outAudio = try await audioSampleBytes(URL(fileURLWithPath: out.path))
        XCTAssertEqual(srcAudio, outAudio, "AAC audio must passthrough byte-identical, never re-encode")
    }

    /// A floor the content genuinely cannot reach (pure noise at a thin ceiling, floor 90) must
    /// still deliver under the web profile — best-effort ceiling encode, `metTarget == false` told
    /// honestly — while the native profile keeps the historical no-file miss. A conversion's caller
    /// asked for a playable file, not a smaller one.
    func testWebProfileDeliversBestEffortOnFloorMiss() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("noise-src-\(UUID().uuidString).mov")
        let webOut = tmp.appendingPathComponent("noise-web-\(UUID().uuidString).mp4")
        let nativeOut = tmp.appendingPathComponent("noise-native-\(UUID().uuidString).mp4")
        defer { [src, webOut, nativeOut].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeClip(at: src, w: 320, h: 240, frames: 30,
                     videoCodec: .hevc, audioFormatID: nil, noise: true)

        let web = try await VideoQualityTarget.encode(input: src, output: webOut, targetScore: 90,
                                                      iterations: 3, profile: .webH264)
        XCTAssertFalse(web.metTarget, "noise at a thin ceiling cannot clear 90 — precondition")
        XCTAssertTrue(web.delivered, "best-effort must deliver the ceiling encode anyway")
        XCTAssertTrue(FileManager.default.fileExists(atPath: webOut.path))
        XCTAssertLessThan(web.score, 90, "the receipt must carry the honest shortfall")

        let native = try await VideoQualityTarget.encode(input: src, output: nativeOut, targetScore: 90,
                                                         iterations: 3)
        XCTAssertFalse(native.metTarget)
        XCTAssertFalse(native.delivered, "the native profile keeps the no-file miss")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nativeOut.path))
    }

    /// The NATIVE profile keeps the historical delivery rule — floor met AND smaller — and a file
    /// exists exactly when `delivered` says so (the no-orphan guarantee, whichever way it falls).
    func testNativeProfileStillRequiresSmaller() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("native-src-\(UUID().uuidString).mov")
        let out = tmp.appendingPathComponent("native-out-\(UUID().uuidString).mp4")
        defer { [src, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeClip(at: src, w: 320, h: 240, frames: 30,
                     videoCodec: .hevc, audioFormatID: nil)

        let r = try await VideoQualityTarget.encode(input: src, output: out, targetScore: 70,
                                                    iterations: 3)
        XCTAssertEqual(r.delivered, r.metTarget && r.outputBytes < r.inputBytes,
                       "native delivery rule unchanged: floor met AND smaller")
        XCTAssertEqual(FileManager.default.fileExists(atPath: out.path), r.delivered,
                       "a file exists exactly when the result says it was delivered")
    }

    // MARK: - Fixtures

    /// Total compressed audio payload of a file's first audio track (0 when none) — byte-identity
    /// across a mux is the passthrough proof.
    private func audioSampleBytes(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)   // stored bitstream
        reader.add(out)
        guard reader.startReading() else { return 0 }
        var total = 0
        while let sb = out.copyNextSampleBuffer() { total += CMSampleBufferGetTotalSampleSize(sb) }
        return total
    }

    /// Synthetic clip: a smooth animated gradient (compressible — the floor must be *reachable*,
    /// which pure noise, the one pathological content class, is not) + an optional 440 Hz mono
    /// audio track in the requested codec. `.mov` container so ALAC muxes. `noise: true` flips the
    /// frames to LCG noise — the deliberately floor-unreachable fixture for best-effort tests.
    private func makeClip(at url: URL, w: Int, h: Int, frames: Int,
                          videoCodec: AVVideoCodecType, audioFormatID: AudioFormatID?,
                          noise: Bool = false) throws {
        let fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Pin a real source bitrate: a default-quality gradient lands ≈0.1 Mbps, and 2× of that is
        // too thin a ceiling for H.264 to clear the floor — the search would miss by a point.
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: videoCodec, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]])
        vin.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(vin)

        var ain: AVAssetWriterInput?
        if let audioFormatID {
            var settings: [String: Any] = [
                AVFormatIDKey: audioFormatID, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1]
            if audioFormatID == kAudioFormatAppleLossless {
                settings[AVEncoderBitDepthHintKey] = 16     // required for ALAC writer inputs
            }
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            ain = a
        }

        writer.startWriting(); writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            while !vin.isReadyForMoreMediaData { usleep(1000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let rowBytes = CVPixelBufferGetBytesPerRow(pb)
                let p = base.assumingMemoryBound(to: UInt8.self)
                if noise {
                    var seed = UInt32(truncatingIfNeeded: i &* 2654435761 | 1)
                    for j in 0..<(rowBytes * h) {       // incompressible LCG noise
                        seed = seed &* 1664525 &+ 1013904223
                        p[j] = UInt8(truncatingIfNeeded: seed >> 16)
                    }
                } else {
                    for y in 0..<h { for x in 0..<w {  // smooth drifting gradient (BGRA)
                        let o = y * rowBytes + x * 4
                        p[o] = UInt8((x * 255 / w + i * 6) % 256)
                        p[o + 1] = UInt8(y * 255 / h)
                        p[o + 2] = UInt8((x + y) * 255 / (w + h))
                        p[o + 3] = 255
                    } }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        vin.markAsFinished()

        if let ain {
            let sampleRate = 44_100
            let total = frames * sampleRate / fps
            var written = 0
            while written < total {
                while !ain.isReadyForMoreMediaData { usleep(1000) }
                let chunk = min(4096, total - written)
                ain.append(try pcmSine(frames: chunk, startFrame: written, sampleRate: sampleRate))
                written += chunk
            }
            ain.markAsFinished()
        }

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else {
            throw NSError(domain: "WebDeliverableTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "fixture writer failed: \(String(describing: writer.error))"])
        }
    }

    /// A CMSampleBuffer of mono 16-bit 440 Hz PCM starting at `startFrame`.
    private func pcmSine(frames: Int, startFrame: Int, sampleRate: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &fmt)

        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            samples[i] = Int16(8000 * sin(2 * .pi * 440 * Double(startFrame + i) / Double(sampleRate)))
        }
        let byteCount = frames * 2
        var bb: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: byteCount, flags: 0, blockBufferOut: &bb)
        samples.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!,
                                              offsetIntoDestination: 0, dataLength: byteCount)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: nil, dataBuffer: bb, dataReady: true,
                                          makeDataReadyCallback: nil, refcon: nil,
                                          formatDescription: fmt, sampleCount: frames,
                                          sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                          sampleBufferOut: &sb)
        guard status == noErr, let sb else {
            throw NSError(domain: "WebDeliverableTests", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "pcm sample buffer create failed"])
        }
        return sb
    }
}
