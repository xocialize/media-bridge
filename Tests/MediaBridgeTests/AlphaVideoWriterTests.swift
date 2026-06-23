import XCTest
import AVFoundation
import CoreVideo
@testable import MediaMeasure

final class AlphaVideoWriterTests: XCTestCase {
    /// Premultiplied-BGRA buffer: white premultiplied by a per-column alpha (so B=G=R=A = alpha).
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

    /// Write a clip whose alpha is 255 on the left half, 64 on the right; confirm the matte survives the
    /// ProRes 4444 round-trip (i.e. AVFoundation actually encodes alpha, not an opaque frame).
    func testProRes4444PreservesAlpha() async throws {
        let w = 16, h = 8
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("alpha-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }

        var remaining = 4
        let written = try await AlphaVideoWriter.writeProRes4444(to: out, width: w, height: h, frameRate: 30) {
            guard remaining > 0 else { return nil }
            remaining -= 1
            return self.makeBGRA(width: w, height: h) { $0 < w / 2 ? 255 : 64 }
        }
        XCTAssertEqual(written, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))

        let alpha = try await firstFrameAlpha(out, width: w, height: h)
        // Left column should be ~opaque, right column ~64 — and crucially NOT both 255 (which would mean
        // alpha was dropped and the frame written opaque).
        let left = Int(alpha[2]), right = Int(alpha[w - 3])
        XCTAssertEqual(left, 255, accuracy: 6, "left half should stay opaque")
        XCTAssertEqual(right, 64, accuracy: 6, "right-half alpha must survive (ProRes 4444 carries alpha)")
        XCTAssertLessThan(right, 160, "alpha was not dropped to opaque")
    }
}
