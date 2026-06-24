import XCTest
import AVFoundation
import CoreVideo
import CoreGraphics
@testable import MediaMeasure

final class VideoConsistencyPipelineTests: XCTestCase {
    private let w = 64, h = 48                                  // source; HEVC-safe once 2×'d (128×96)

    private func makeClip(at url: URL, frames: Int) throws {
        let fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
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

    // Stub SR: 2× nearest upscale (so output dimensions differ from source — exercises the peek-first sizing).
    private func upscale2x(_ src: CGImage) -> CGImage {
        let ow = src.width * 2, oh = src.height * 2
        var bytes = [UInt8](repeating: 0, count: ow * oh * 4)
        let ctx = CGContext(data: &bytes, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: ow * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: ow, height: oh))
        return ctx.makeImage()!
    }

    /// Read → 2× enhance (stub) → temporal stabilize → opaque HEVC, end to end. The output track must carry
    /// every frame at the enhanced 2× resolution.
    func testEnhanceToVideoUpscales() async throws {
        let inURL = FileManager.default.temporaryDirectory.appendingPathComponent("vc-in-\(UUID()).mp4")
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("vc-out-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: inURL); try? FileManager.default.removeItem(at: outURL) }
        try makeClip(at: inURL, frames: 5)

        let outcome = try await VideoConsistencyPipeline.enhanceToVideo(
            input: inURL, output: outURL,
            enhance: { self.upscale2x($0) },
            flow: { a, _ in DenseFlow(width: a.width, height: a.height,
                                      uv: [Float](repeating: 0, count: a.width * a.height * 2)) })

        XCTAssertEqual(outcome.framesWritten, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))

        let asset = AVURLAsset(url: outURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width.rounded()), w * 2, "output is the enhanced 2× width")
        XCTAssertEqual(Int(size.height.rounded()), h * 2, "output is the enhanced 2× height")

        // Count decodable frames in the output.
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out); reader.startReading()
        var n = 0
        while out.copyNextSampleBuffer() != nil { n += 1 }
        XCTAssertEqual(n, 5, "all frames encoded + decodable")
    }
}
