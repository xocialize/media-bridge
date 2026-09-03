import AVFoundation
import CoreGraphics
import CoreVideo
import XCTest
@testable import MediaBridge
@testable import MediaMeasure

/// The encoder is where flattening physically happens, so the refusal lives there too: every
/// direct consumer of `VideoQualityTarget.encode` / `VideoConsistencyPipeline.enhanceToVideo` —
/// benches, CLIs, the Kit — inherits it without re-implementing the probe-level check.
/// `flattenAlpha: true` is the one explicit way through.
final class EncodeAlphaGuardTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        super.tearDown()
    }

    private func scratchURL(_ ext: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("encode-alpha-\(UUID().uuidString).\(ext)")
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

    private func makeAlphaMOV(_ codec: AlphaVideoWriter.Codec, frames: Int = 12) async throws -> URL {
        let url = scratchURL("mov")
        let w = 96, h = 64
        var remaining = frames
        _ = try await AlphaVideoWriter.write(to: url, codec: codec, width: w, height: h, frameRate: 30) {
            guard remaining > 0 else { return nil }
            remaining -= 1
            return (self.makeBGRA(width: w, height: h) { $0 < w / 2 ? 255 : 64 }, nil)
        }
        return url
    }

    // MARK: - VideoQualityTarget.encode

    func testEncodeRefusesAlphaSourceByDefault() async throws {
        let input = try await makeAlphaMOV(.hevcWithAlpha)
        let out = scratchURL("mp4")
        do {
            _ = try await VideoQualityTarget.encode(input: input, output: out, targetScore: 75,
                                                    iterations: 1)
            XCTFail("an alpha source must be refused, not flattened")
        } catch VideoQualityTarget.EncodeError.alphaSource {
            // expected — and the message must tell the caller how to opt in
            XCTAssertTrue(String(describing: VideoQualityTarget.EncodeError.alphaSource)
                            .contains("flattenAlpha"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "a refusal writes nothing")
    }

    func testEncodeFlattensOnlyWhenAskedTo() async throws {
        let input = try await makeAlphaMOV(.proRes4444)
        let out = scratchURL("mp4")
        let r = try await VideoQualityTarget.encode(input: input, output: out, targetScore: 50,
                                                    iterations: 2, flattenAlpha: true)
        XCTAssertEqual(r.sourceWidth, 96)
        XCTAssertEqual(r.sourceHeight, 64)
        // The opt-in produces an OPAQUE deliverable: the probe must not see alpha on it.
        if r.delivered {
            let info = try await MediaBridge.probe(url: out)
            XCTAssertEqual(info.videoStreams.first?.hasAlpha, false)
        }
    }

    // MARK: - VideoConsistencyPipeline.enhanceToVideo

    func testPipelineRefusesAlphaSourceByDefault() async throws {
        let input = try await makeAlphaMOV(.hevcWithAlpha, frames: 4)
        let out = scratchURL("mp4")
        do {
            _ = try await VideoConsistencyPipeline.enhanceToVideo(
                input: input, output: out,
                enhance: { $0 },
                flow: { a, _ in
                    DenseFlow(width: a.width, height: a.height,
                              uv: [Float](repeating: 0, count: a.width * a.height * 2))
                })
            XCTFail("an alpha source must be refused, not flattened")
        } catch VideoConsistencyPipeline.PipelineError.alphaSource {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "a refusal writes nothing")
    }
}
