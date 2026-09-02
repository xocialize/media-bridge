import AVFoundation
import CoreVideo
import XCTest
@testable import MediaBridge
@testable import MediaMeasure

/// `MediaInfo.videoStreams[…].hasAlpha` — the probe-level answer to "would an opaque encode throw
/// something away?".
///
/// It has to exist at probe time because nothing downstream can tell. An opaque re-encode of an
/// alpha source produces a complete, plausible, fully-opaque video, and the quality gate cannot
/// object: SSIMULACRA2 composites both sides over an opaque ground before scoring, so a flattened
/// candidate is measured against a flattened reference and clears its floor. The flatten is
/// invisible in the bytes, invisible in the score, and shows up only as a wrong file at a venue.
final class ProbeAlphaTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        super.tearDown()
    }

    private func scratchURL(_ ext: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-alpha-\(UUID().uuidString).\(ext)")
        scratch.append(u)
        return u
    }

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

    private func makeAlphaMOV(_ codec: AlphaVideoWriter.Codec) async throws -> URL {
        let url = scratchURL("mov")
        let w = 64, h = 32
        var remaining = 8
        _ = try await AlphaVideoWriter.write(to: url, codec: codec, width: w, height: h, frameRate: 30) {
            guard remaining > 0 else { return nil }
            remaining -= 1
            return (self.makeBGRA(width: w, height: h) { $0 < w / 2 ? 255 : 64 }, nil)
        }
        return url
    }

    /// An opaque HEVC mp4 — the negative control. Without one, a `hasAlpha` that always returned
    /// true would pass every other case here.
    private func makeOpaqueMP4() async throws -> URL {
        let url = scratchURL("mp4")
        let writer = try NativeMP4Writer(output: url, width: 64, height: 32)
        for i in 0..<8 {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &pb)
            let buffer = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0x40,
                   CVPixelBufferGetBytesPerRow(buffer) * 32)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try await writer.appendVideo(buffer, ptsNanos: Int64(i) * 33_000_000)
        }
        try await writer.finish()
        return url
    }

    func testProResAlphaIsReported() async throws {
        let info = try await MediaBridge.probe(url: try await makeAlphaMOV(.proRes4444))
        XCTAssertEqual(info.videoStreams.first?.hasAlpha, true)
    }

    func testHEVCWithAlphaIsReported() async throws {
        let info = try await MediaBridge.probe(url: try await makeAlphaMOV(.hevcWithAlpha))
        XCTAssertEqual(info.videoStreams.first?.hasAlpha, true)
    }

    func testOpaqueVideoReportsNoAlpha() async throws {
        let info = try await MediaBridge.probe(url: try await makeOpaqueMP4())
        XCTAssertEqual(info.videoStreams.first?.hasAlpha, false,
                       "an opaque HEVC mp4 must not claim alpha — otherwise the flag gates nothing")
    }
}
