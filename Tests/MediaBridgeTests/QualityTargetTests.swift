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

    /// `channelScalars:` was a flag in disguise: non-nil meant "use the GPU", and the closure was
    /// discarded in favour of the resident whole-score path. That is right for the callers who
    /// pass `SSIMULACRA2Metal.shared?.channelScalarsFunction`, and wrong for anyone injecting a
    /// backend they need honored. `backend:` names the choice; these three cases pin all of it,
    /// including that the legacy reading is preserved byte-for-byte.
    func testScoringBackendIsHonoredAndLegacyReadingPreserved() throws {
        final class Spy: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
            func hit() { lock.lock(); count += 1; lock.unlock() }
        }
        let spy = Spy()
        // Deterministic stand-in — the contract under test is WHETHER this runs, not what it returns.
        let injected: SSIMULACRA2.ChannelScalars = { _, _, _, _, _ in
            spy.hit()
            return SSIMULACRA2.ChannelResult(ssimL1: 0.99, ssimL4: 0.99, artifactL1: 0.01,
                                             artifactL4: 0.01, detailL1: 0.01, detailL4: 0.01)
        }
        let img = makeImage()

        // 1. `.injected` is honored exactly — the whole point of the new case.
        _ = try ImageQualityTarget.encodeHEIC(img, targetScore: 80, iterations: 2,
                                              backend: .injected(injected))
        XCTAssertGreaterThan(spy.calls, 0, "an injected backend must actually be called")

        // 2. An explicit backend WINS over the legacy parameter, and `.cpu` is not silently
        //    upgraded to the GPU just because a device is present.
        let afterInjected = spy.calls
        _ = try ImageQualityTarget.encodeHEIC(img, targetScore: 80, iterations: 2,
                                              channelScalars: injected, backend: .cpu)
        XCTAssertEqual(spy.calls, afterInjected, "backend: .cpu must override channelScalars:")

        // 3. Legacy reading, preserved verbatim: with no explicit backend a non-nil
        //    `channelScalars` still means "prefer the resident GPU path", closure discarded.
        //    Only assertable when that path exists — otherwise the fallback legitimately calls it.
        if let gpu = SSIMULACRA2Metal.shared, gpu.residentAvailable {
            let afterCPU = spy.calls
            _ = try ImageQualityTarget.encodeHEIC(img, targetScore: 80, iterations: 2,
                                                  channelScalars: injected)
            XCTAssertEqual(spy.calls, afterCPU,
                           "legacy channelScalars: must keep routing to the resident path unchanged")
        }
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
