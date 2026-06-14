import XCTest
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import ImageBridge

/// The salvaged (binary-free) ImageBridge: ImageIO decode/encode round-trip + the FrameProcessor
/// AI-chain seam through the orchestrator. No oxipng, no subprocess.
final class ImageBridgeTests: XCTestCase {

    private func writeTestPNG() throws -> URL {
        let w = 64, h = 64
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            bytes[i] = UInt8(x * 4); bytes[i + 1] = UInt8(y * 4); bytes[i + 2] = 128; bytes[i + 3] = 255
        } }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let img = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        return url
    }

    func testDecodeEncodeRoundTrip() throws {
        let png = try writeTestPNG()
        defer { try? FileManager.default.removeItem(at: png) }

        let (frames, meta) = try ImageBridgeFactory.makeDecoder().decode(url: png)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(CVPixelBufferGetWidth(frames[0]), 64)
        XCTAssertEqual(meta.width, 64)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: out) }
        try ImageBridgeFactory.makeEncoder().encode(
            frames[0], settings: StillEncoderSettings(format: .heic, quality: 0.8),
            metadata: nil, to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))

        // Re-decode the HEIC to confirm it's valid.
        let (back, _) = try ImageBridgeFactory.makeDecoder().decode(url: out)
        XCTAssertEqual(CVPixelBufferGetWidth(back[0]), 64)
    }

    /// A FrameProcessor that inverts BGRA — proves the AI-chain seam runs in the orchestrator.
    private struct Invert: FrameProcessor {
        func process(_ pb: CVPixelBuffer) -> CVPixelBuffer {
            CVPixelBufferLockBaseAddress(pb, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h { for x in 0..<w {
                let p = y * bpr + x * 4
                base[p] = 255 - base[p]; base[p + 1] = 255 - base[p + 1]; base[p + 2] = 255 - base[p + 2]
            } }
            return pb
        }
    }

    func testOrchestratorRunsFrameProcessor() throws {
        let png = try writeTestPNG()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png); try? FileManager.default.removeItem(at: out) }

        try ImageBridgeFactory.makeOrchestrator().convert(
            input: png, output: out, settings: StillEncoderSettings(format: .png),
            frameProcessor: Invert())
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))

        // The orchestrated output is the inverted image: top-left was ~(0,0,128) → ~(255,255,127).
        let (frames, _) = try ImageBridgeFactory.makeDecoder().decode(url: out)
        CVPixelBufferLockBaseAddress(frames[0], .readOnly)
        let base = CVPixelBufferGetBaseAddress(frames[0])!.assumingMemoryBound(to: UInt8.self)
        let b = base[0], g = base[1], r = base[2]
        CVPixelBufferUnlockBaseAddress(frames[0], .readOnly)
        XCTAssertGreaterThan(Int(r), 200, "red inverted from ~0")
        XCTAssertGreaterThan(Int(g), 200, "green inverted from ~0")
        _ = b
    }
}
