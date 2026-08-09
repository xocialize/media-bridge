import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import MediaMeasure

/// GIF → H.264 mezzanine: frame count, per-frame timing (with the ≤10 ms → 100 ms browser
/// convention), even-dimension handling, and the router's cheap animation probe.
final class GIFVideoTests: XCTestCase {

    /// An animated GIF with per-frame delays; content drifts per frame so encodes are non-trivial.
    private func makeGIF(at url: URL, w: Int, h: Int, frames: Int, delay: Double) throws {
        let dst = CGImageDestinationCreateWithURL(url as CFURL,
                                                  UTType.gif.identifier as CFString,
                                                  frames, nil)!
        CGImageDestinationSetProperties(dst, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for i in 0..<frames {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let o = (y * w + x) * 4
                bytes[o] = UInt8((x * 255 / w + i * 23) % 256)
                bytes[o + 1] = UInt8((y * 255 / h + i * 11) % 256)
                bytes[o + 2] = UInt8((i * 37) % 256)
                bytes[o + 3] = 255
            } }
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            CGImageDestinationAddImage(dst, ctx.makeImage()!, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dst) else { throw GIFVideo.GIFError.writeFailed("fixture") }
    }

    func testFrameCountProbe() throws {
        let tmp = FileManager.default.temporaryDirectory
        let gif = tmp.appendingPathComponent("probe-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: gif) }
        try makeGIF(at: gif, w: 64, h: 64, frames: 12, delay: 0.1)
        XCTAssertEqual(GIFVideo.frameCount(gif), 12)
    }

    func testMezzanineHonorsFramesAndTiming() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let gif = tmp.appendingPathComponent("anim-\(UUID().uuidString).gif")
        let mezz = tmp.appendingPathComponent("anim-\(UUID().uuidString).mp4")
        defer { [gif, mezz].forEach { try? FileManager.default.removeItem(at: $0) } }
        // 121×83 — odd dims on purpose; 24 frames at 80 ms.
        try makeGIF(at: gif, w: 121, h: 83, frames: 24, delay: 0.08)

        let r = try await GIFVideo.renderMezzanine(input: gif, output: mezz)
        XCTAssertEqual(r.frames, 24)
        XCTAssertEqual(r.width, 120, "odd width rounds down to even")
        XCTAssertEqual(r.height, 82, "odd height rounds down to even")
        XCTAssertEqual(r.duration, 24 * 0.08, accuracy: 0.02)

        let asset = AVURLAsset(url: mezz)
        let dur = try await asset.load(.duration).seconds
        // The track's duration ends at the LAST frame's PTS (its own delay extends past what a
        // sample-less container records) — assert the neighbourhood, not exactness.
        XCTAssertEqual(dur, 24 * 0.08, accuracy: 0.15)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await XCTUnwrap(track).load(.naturalSize)
        XCTAssertEqual(Int(size.width), 120)
        XCTAssertEqual(Int(size.height), 82)
    }

    func testTinyDelaysRenderAtBrowserConvention() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let gif = tmp.appendingPathComponent("fast-\(UUID().uuidString).gif")
        let mezz = tmp.appendingPathComponent("fast-\(UUID().uuidString).mp4")
        defer { [gif, mezz].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeGIF(at: gif, w: 64, h: 64, frames: 10, delay: 0.0)   // pathological "0 delay"

        let r = try await GIFVideo.renderMezzanine(input: gif, output: mezz)
        // ImageIO itself may clamp a stored 0 to 0.1 — either way the OUTPUT timing must be the
        // 100 ms convention, never a 0-length or literal-0 pacing.
        XCTAssertEqual(r.duration, 1.0, accuracy: 0.05,
                       "10 zero-delay frames must render as ~10 × 100 ms")
    }

    func testSingleFrameGIFRefusesHonestly() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let gif = tmp.appendingPathComponent("still-\(UUID().uuidString).gif")
        let mezz = tmp.appendingPathComponent("still-\(UUID().uuidString).mp4")
        defer { [gif, mezz].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeGIF(at: gif, w: 64, h: 64, frames: 1, delay: 0.1)
        do {
            _ = try await GIFVideo.renderMezzanine(input: gif, output: mezz)
            XCTFail("single-frame GIF must refuse (it belongs to the still race)")
        } catch let e as GIFVideo.GIFError {
            guard case .notAnimated = e else { return XCTFail("wrong error: \(e)") }
        }
    }
}
