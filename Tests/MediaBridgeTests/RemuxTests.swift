import XCTest
import AVFoundation
import CoreMedia
@testable import MediaBridge

/// `remuxToMP4` — the passthrough rewrap. The whole contract is "not one media byte touched":
/// both streams must come out byte-identical, only the wrapper changes.
final class RemuxTests: XCTestCase {

    func testRemuxIsByteIdenticalOnBothStreams() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("remux-src-\(UUID().uuidString).mov")
        let out = tmp.appendingPathComponent("remux-out-\(UUID().uuidString).mp4")
        defer { [src, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeMOV(at: src, w: 320, h: 240, frames: 30)

        try await MediaBridge.remuxToMP4(input: src, output: out)

        // Container changed…
        let info = try await MediaBridge.probe(url: out)
        XCTAssertEqual(info.container, .mp4)
        XCTAssertEqual(info.videoStreams.first?.codecID, "V_MPEG4/ISO/AVC")
        XCTAssertEqual(info.audioStreams.first?.codecID, "A_AAC")

        // …and not one media byte did.
        let srcVideo = try await sampleBytes(src, .video)
        let outVideo = try await sampleBytes(out, .video)
        XCTAssertEqual(srcVideo, outVideo, "video bitstream must passthrough byte-identical")
        let srcAudio = try await sampleBytes(src, .audio)
        let outAudio = try await sampleBytes(out, .audio)
        XCTAssertEqual(srcAudio, outAudio, "audio bitstream must passthrough byte-identical")

        // Size stays in the same neighborhood (container trivia only).
        let srcBytes = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let outBytes = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        XCTAssertLessThan(abs(outBytes - srcBytes), max(srcBytes / 10, 64 * 1024),
                          "a remux must not meaningfully change file size (\(srcBytes) → \(outBytes))")
    }

    func testRemuxRefusesUnreadableSource() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-missing-\(UUID().uuidString).mov")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-noout-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            try await MediaBridge.remuxToMP4(input: missing, output: out)
            XCTFail("expected a thrown export failure")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                           "a failed remux must leave no bytes at output")
        }
    }

    // MARK: - Fixtures

    /// Total stored sample payload of the first track of `type` — byte-identity across a mux is the
    /// passthrough proof.
    private func sampleBytes(_ url: URL, _ type: AVMediaType) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: type).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        guard reader.startReading() else { return 0 }
        var total = 0
        while let sb = out.copyNextSampleBuffer() { total += CMSampleBufferGetTotalSampleSize(sb) }
        return total
    }

    /// H.264 + AAC in .mov — the "web-safe streams, wrong wrapper" capture shape.
    private func makeMOV(at url: URL, w: Int, h: Int, frames: Int) throws {
        let fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_500_000]])
        vin.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(vin)
        let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
        ain.expectsMediaDataInRealTime = false
        writer.add(ain)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            while !vin.isReadyForMoreMediaData { usleep(500) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buf = pb else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buf)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h { for x in 0..<w {
                    let o = y * rowBytes + x * 4
                    p[o] = UInt8((x * 255 / w + i * 6) % 256)
                    p[o + 1] = UInt8(y * 255 / h)
                    p[o + 2] = UInt8((x + y) * 255 / (w + h))
                    p[o + 3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        vin.markAsFinished()

        let sampleRate = 44_100
        let total = frames * sampleRate / fps
        var written = 0
        while written < total {
            while !ain.isReadyForMoreMediaData { usleep(500) }
            let chunk = min(4096, total - written)
            ain.append(try Self.pcmSine(frames: chunk, startFrame: written, sampleRate: sampleRate))
            written += chunk
        }
        ain.markAsFinished()

        let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
        guard writer.status == .completed else {
            throw NSError(domain: "RemuxTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "fixture writer failed"])
        }
    }

    private static func pcmSine(frames: Int, startFrame: Int, sampleRate: Int) throws -> CMSampleBuffer {
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
        CMSampleBufferCreate(allocator: nil, dataBuffer: bb, dataReady: true,
                             makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
                             sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        return sb!
    }
}
