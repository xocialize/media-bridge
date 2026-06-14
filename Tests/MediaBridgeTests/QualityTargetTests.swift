import XCTest
import CoreGraphics
@testable import MediaMeasure

final class QualityTargetTests: XCTestCase {

    /// A small (fast to score), moderately-compressible image: gradient base + mild deterministic noise.
    private func makeImage(_ n: Int = 96) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n { for x in 0..<n {
            let noise = ((x * 131 + y * 57) % 64) - 32
            let i = (y * n + x) * 4
            bytes[i] = UInt8(clamping: x * 2 + noise)
            bytes[i + 1] = UInt8(clamping: y * 2 + noise)
            bytes[i + 2] = UInt8(clamping: 128 + noise)
            bytes[i + 3] = 255
        } }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    func testSearchMeetsTarget() throws {
        let img = makeImage()
        let r = try ImageQualityTarget.encodeHEIC(img, targetScore: 80, iterations: 6)
        XCTAssertTrue(r.metTarget, "target 80 should be reachable within quality ≤ 1")
        XCTAssertGreaterThanOrEqual(r.score, 76, "achieved score meets the target within search granularity")
        XCTAssertGreaterThan(r.data.count, 0)
        XCTAssertLessThanOrEqual(r.quality, 1.0)
    }

    /// Higher target ⇒ higher chosen quality ⇒ larger file. Validates the search direction without
    /// depending on absolute scores.
    func testHigherTargetUsesMoreQuality() throws {
        let img = makeImage()
        let low = try ImageQualityTarget.encodeHEIC(img, targetScore: 70, iterations: 6)
        let high = try ImageQualityTarget.encodeHEIC(img, targetScore: 92, iterations: 6)
        XCTAssertLessThanOrEqual(low.quality, high.quality, "lower target needs no more quality")
        XCTAssertGreaterThanOrEqual(high.score, low.score, "higher target → higher achieved score")
    }

    func testSearchPureMonotonic() throws {
        // The pure search on a synthetic monotonic oracle: lowest x with x*100 >= 60 → ~0.6.
        let r = try QualityTargetSearch.search(target: 60, iterations: 16) { $0 * 100 }
        XCTAssertTrue(r.metTarget)
        XCTAssertEqual(r.quality, 0.6, accuracy: 0.02)
    }
}
