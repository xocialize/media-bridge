import XCTest
import AVFoundation
import CoreVideo
import CoreGraphics
@testable import MediaMeasure

final class VideoMattePipelineTests: XCTestCase {
    private let w = 32, h = 16

    /// Synthetic H.264 clip (noisy frames so it encodes real content) → mp4.
    private func makeClip(at url: URL, frames: Int) throws {
        let fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let p = base.assumingMemoryBound(to: UInt8.self)
                var seed = UInt32(truncatingIfNeeded: i &* 2654435761 | 1)
                for j in 0..<(CVPixelBufferGetBytesPerRow(buf) * h) {
                    seed = seed &* 1664525 &+ 1013904223; p[j] = UInt8(truncatingIfNeeded: seed >> 16)
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
    }

    private func firstFrameAlpha(_ url: URL) async throws -> [UInt8] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out); reader.startReading()
        let buf = CMSampleBufferGetImageBuffer(out.copyNextSampleBuffer()!)!
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        var a = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { a[y * w + x] = base[y * stride + x * 4 + 3] } }
        return a
    }

    /// Read → (stub) matte → temporal blend → composite → ProRes 4444 alpha, end to end. Stub matte is a
    /// left-half-opaque / right-half-half-coverage column; zero flow (static scene). The output cutout's
    /// alpha must reflect that matte — proving the whole chain wires up.
    func testEndToEndMatteToProRes4444() async throws {
        let inURL = FileManager.default.temporaryDirectory.appendingPathComponent("vm-in-\(UUID()).mp4")
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("vm-out-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: inURL); try? FileManager.default.removeItem(at: outURL) }
        try makeClip(at: inURL, frames: 5)

        let mattePattern = VideoMatteProcessor.grayCGImage(
            (0..<(w * h)).map { $0 % w < w / 2 ? 1.0 : 0.5 }, width: w, height: h)
        let written = try await VideoMattePipeline.matteToProRes4444(
            input: inURL, output: outURL,
            matte: { _ in mattePattern },
            flow: { cur, _ in DenseFlow(width: cur.width, height: cur.height,
                                        uv: [Float](repeating: 0, count: cur.width * cur.height * 2)) })

        XCTAssertEqual(written, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        let alpha = try await firstFrameAlpha(outURL)
        XCTAssertEqual(Int(alpha[2]), 255, accuracy: 8, "left half opaque")
        XCTAssertEqual(Int(alpha[w - 3]), 128, accuracy: 10, "right-half matte coverage survives end-to-end")
    }
}
