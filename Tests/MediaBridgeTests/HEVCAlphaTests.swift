import XCTest
import AVFoundation
import CoreVideo
@testable import MediaMeasure

/// HEVC-with-alpha is the reason an alpha-preserving path is not a compression sacrifice.
///
/// The constraint that forces `.mov` is real — no mp4 configuration carries alpha — but the *codec* need
/// not change. ProRes 4444 is an intermediate: visually lossless and enormous. `hevcWithAlpha` keeps the
/// delivery codec, so transparency costs a container change rather than the size story.
final class HEVCAlphaTests: XCTestCase {

    private func makeBGRA(width: Int, height: Int, alpha: (Int) -> UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            for x in 0..<width {
                let a = alpha(x), i = y * stride + x * 4
                base[i] = a; base[i + 1] = a; base[i + 2] = a; base[i + 3] = a
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    private func firstFrameAlpha(_ url: URL, width: Int, height: Int) async throws -> [UInt8] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw XCTSkip("no video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out); reader.startReading()
        guard let sample = out.copyNextSampleBuffer(), let buf = CMSampleBufferGetImageBuffer(sample) else {
            throw XCTSkip("no frame decoded")
        }
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        var alpha = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { alpha[y * width + x] = base[y * stride + x * 4 + 3] } }
        return alpha
    }

    private func write(_ codec: AlphaVideoWriter.Codec, to url: URL, w: Int, h: Int, frames: Int) async throws {
        var remaining = frames
        _ = try await AlphaVideoWriter.write(to: url, codec: codec, width: w, height: h, frameRate: 30) {
            guard remaining > 0 else { return nil }
            remaining -= 1
            return (self.makeBGRA(width: w, height: h) { $0 < w / 2 ? 255 : 64 }, nil)
        }
    }

    func testHEVCWithAlphaPreservesAlpha() async throws {
        let w = 64, h = 32
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("hevc-alpha-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }

        try await write(.hevcWithAlpha, to: out, w: w, h: h, frames: 8)
        let alpha = try await firstFrameAlpha(out, width: w, height: h)

        // Lossy codec: assert the matte's SHAPE survived, not exact bytes. An opaque encode — the failure
        // this guards — returns 255 everywhere, which these bounds reject.
        let left = Int(alpha[w / 4]), right = Int(alpha[w / 2 + w / 4])
        XCTAssertGreaterThan(left, 200, "opaque half must stay near 255")
        XCTAssertLessThan(right, 140, "semi-transparent half must stay near 64, not flatten to opaque")
        XCTAssertGreaterThan(left - right, 60, "the alpha step must survive")
    }

    /// The size argument for choosing HEVC over ProRes when preserving transparency.
    func testHEVCWithAlphaIsFarSmallerThanProRes() async throws {
        let w = 320, h = 240, frames = 24
        let dir = FileManager.default.temporaryDirectory
        let hevc = dir.appendingPathComponent("h-\(UUID().uuidString).mov")
        let prores = dir.appendingPathComponent("p-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: hevc); try? FileManager.default.removeItem(at: prores)
        }

        try await write(.hevcWithAlpha, to: hevc, w: w, h: h, frames: frames)
        try await write(.proRes4444, to: prores, w: w, h: h, frames: frames)

        let hevcBytes = try FileManager.default.attributesOfItem(atPath: hevc.path)[.size] as! Int
        let proresBytes = try FileManager.default.attributesOfItem(atPath: prores.path)[.size] as! Int
        print("[alpha-size] hevcWithAlpha=\(hevcBytes) proRes4444=\(proresBytes) ratio=\(Double(proresBytes)/Double(hevcBytes))")
        XCTAssertLessThan(hevcBytes, proresBytes,
                          "hevcWithAlpha must beat ProRes 4444 or the delivery argument collapses")
    }
}
