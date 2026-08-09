import XCTest
import AVFoundation
@testable import MediaMeasure

/// `maxHeight` is a RESOLUTION CLASS — it caps the SHORT side. The literal-height reading turned
/// portrait phone video into thumbnails (1080×1920 @ maxHeight 1080 → 608×1080), which no
/// consumer means by "1080p".
final class ResolutionClassTests: XCTestCase {

    private func makeClip(at url: URL, w: Int, h: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]])
        vin.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vin,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(vin)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<30 {
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
                    p[o + 1] = UInt8(y * 255 / h); p[o + 2] = 128; p[o + 3] = 255
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

    private func dims(_ url: URL) async throws -> (Int, Int) {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
        let size = try await XCTUnwrap(track).load(.naturalSize)
        return (Int(abs(size.width).rounded()), Int(abs(size.height).rounded()))
    }

    /// Portrait ABOVE the class downscales to the class on its SHORT side.
    func testPortraitAboveClassDownscalesByShortSide() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("rc-p4k-\(UUID().uuidString).mov")
        let out = tmp.appendingPathComponent("rc-p4k-out-\(UUID().uuidString).mp4")
        defer { [src, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeClip(at: src, w: 1080, h: 1920)     // portrait, above a 540 class
        let r = try await VideoQualityTarget.encode(input: src, output: out, targetScore: 60,
                                                    maxHeight: 540, iterations: 3,
                                                    profile: .webH264)
        XCTAssertTrue(r.delivered)
        let (w, h) = try await dims(out)
        XCTAssertEqual(w, 540, "portrait: the SHORT side (width) takes the cap")
        XCTAssertEqual(h, 960)
    }

    /// Portrait AT the class is already that class — untouched.
    func testPortraitAtClassIsNotDownscaled() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("rc-pat-\(UUID().uuidString).mov")
        let out = tmp.appendingPathComponent("rc-pat-out-\(UUID().uuidString).mp4")
        defer { [src, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeClip(at: src, w: 540, h: 960)       // 540p-class portrait
        let r = try await VideoQualityTarget.encode(input: src, output: out, targetScore: 60,
                                                    maxHeight: 540, iterations: 3,
                                                    profile: .webH264)
        XCTAssertTrue(r.delivered)
        let (w, h) = try await dims(out)
        XCTAssertEqual(w, 540, "a 540×960 portrait IS 540p-class — no downscale")
        XCTAssertEqual(h, 960)
    }

    /// Landscape keeps the historical behavior exactly (height is the short side).
    func testLandscapeBehaviorUnchanged() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("rc-l-\(UUID().uuidString).mov")
        let out = tmp.appendingPathComponent("rc-l-out-\(UUID().uuidString).mp4")
        defer { [src, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeClip(at: src, w: 1920, h: 1080)
        let r = try await VideoQualityTarget.encode(input: src, output: out, targetScore: 60,
                                                    maxHeight: 540, iterations: 3,
                                                    profile: .webH264)
        XCTAssertTrue(r.delivered)
        let (w, h) = try await dims(out)
        XCTAssertEqual(h, 540)
        XCTAssertEqual(w, 960)
    }
}
