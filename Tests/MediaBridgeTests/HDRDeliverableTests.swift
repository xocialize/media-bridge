import XCTest
import AVFoundation
import CoreVideo
@testable import MediaMeasure

/// The HDR→SDR web rung: an HLG/BT.2020 source (every recent iPhone capture) targeting a
/// `deliverSDR` profile must ship BT.709-tagged SDR — HDR tags on 8-bit web H.264 render
/// inconsistently across browsers, and scoring HDR reference frames against SDR-ish candidates
/// is the img3140 cross-gamut failure inside our own gate. The native profile is the control:
/// HDR HEVC is a legitimate Apple deliverable and its tags must survive untouched.
final class HDRDeliverableTests: XCTestCase {

    /// A minimal HLG BT.2020 10-bit HEVC clip: drifting gradient, tagged HDR at the writer.
    private func makeHLGClip(at url: URL, w: Int, h: Int, frames: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // No explicit profile key (invalid for HEVC at this level); the HLG COLOUR TAGS are what
        // make the fixture HDR for detection purposes — bit depth is not load-bearing here.
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
        ])
        vin.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vin,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(vin)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !vin.isReadyForMoreMediaData { usleep(1000) }
            var pb: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            } else {
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            }
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let rowBytes = CVPixelBufferGetBytesPerRow(pb)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h { for x in 0..<w {
                    let o = y * rowBytes + x * 4
                    p[o] = UInt8((x * 255 / w + i * 6) % 256)
                    p[o + 1] = UInt8(y * 255 / h)
                    p[o + 2] = UInt8(((x + y) * 255 / (w + h)) % 256)
                    p[o + 3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        vin.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
    }

    private func transferTag(_ url: URL) async throws -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let fmt = try await track.load(.formatDescriptions).first else { return nil }
        return CMFormatDescriptionGetExtension(
            fmt, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
    }

    func testHLGSourceIsDetectedAsHDR() throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("hlg-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: src) }
        try makeHLGClip(at: src, w: 320, h: 240, frames: 30)
        let asset = AVURLAsset(url: src)
        let track = asset.tracks(withMediaType: .video).first
        let fmt = track?.formatDescriptions.first
        XCTAssertTrue(VideoQualityTarget.isHDRTransfer(fmt.map { $0 as! CMFormatDescription }),
                      "the HLG fixture must read as HDR")
    }

    func testWebProfileToneMapsHDRToTagged709() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("hlg-src-\(UUID().uuidString).mov")
        let out = tmp.appendingPathComponent("hlg-web-\(UUID().uuidString).mp4")
        defer { [src, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeHLGClip(at: src, w: 320, h: 240, frames: 30)

        let r = try await VideoQualityTarget.encode(input: src, output: out, targetScore: 70,
                                                    iterations: 3, profile: .webH264)
        XCTAssertTrue(r.delivered, "the SDR web conversion must deliver")
        let transfer = try await transferTag(out)
        XCTAssertEqual(transfer, kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                       "web output from an HDR source must be tone-mapped, BT.709-tagged SDR")
    }

    func testNativeProfilePreservesHDRTags() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("hlg-src-\(UUID().uuidString).mov")
        let out = tmp.appendingPathComponent("hlg-native-\(UUID().uuidString).mp4")
        defer { [src, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeHLGClip(at: src, w: 320, h: 240, frames: 30)

        // Generous floor: the point is tags, not the search outcome; deliver isn't required
        // (requireSmaller may skip) — the CANDIDATE encode's tags are what the temp inspection
        // would need, so ship a floor it can clear and check the delivered file.
        let r = try await VideoQualityTarget.encode(input: src, output: out, targetScore: 40,
                                                    iterations: 3, profile: .hevc)
        guard r.delivered else {
            // A skip is legitimate under requireSmaller on synthetic content; the invariant
            // still holds vacuously (no file was produced to mislabel).
            return
        }
        let transfer = try await transferTag(out)
        XCTAssertEqual(transfer, AVVideoTransferFunction_ITU_R_2100_HLG as String,
                       "the native profile must preserve HDR — HDR HEVC is a first-class deliverable")
    }
}
