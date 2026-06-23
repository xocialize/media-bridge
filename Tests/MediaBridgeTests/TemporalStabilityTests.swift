import XCTest
import CoreGraphics
@testable import MediaMeasure

final class TemporalStabilityTests: XCTestCase {
    private let w = 4, h = 4

    private final class Counter { var n = 0; func next() -> Int { defer { n += 1 }; return n } }

    private func grayFrame(_ v: Float) -> CGImage {
        VideoMatteProcessor.grayCGImage([Float](repeating: v, count: w * h), width: w, height: h)
    }
    private func zeroFlow(_ a: CGImage, _ b: CGImage) -> DenseFlow {
        DenseFlow(width: a.width, height: a.height, uv: [Float](repeating: 0, count: a.width * a.height * 2))
    }

    /// With zero flow the warped previous matte == the previous stabilized matte. A small within-tolerance
    /// jitter (0.50 → 0.55, tol 0.15, strength 0.6) is partly pulled back by the blend, so the stabilized
    /// output flickers less than the raw matte → a positive, predictable `reduction`.
    func testFlickerReductionOnSmallJitter() async throws {
        let frame = grayFrame(0)                       // content irrelevant — stub seams ignore it
        let count = Counter()
        let proc = VideoMatteProcessor(
            matte: { _ in self.grayFrame(count.next() == 0 ? 0.50 : 0.55) },
            flow: { a, b in self.zeroFlow(a, b) })

        _ = try await proc.next(frame)                 // frame 0 → stable 0.50 (no transition)
        _ = try await proc.next(frame)                 // frame 1 → raw 0.55, warped 0.50

        let s = try XCTUnwrap(proc.stability())
        XCTAssertEqual(s.transitions, 1)
        // input = |0.55 − 0.50| = 0.05; agreement = 1 − 0.05/0.15 = 0.667; w = 0.6·0.667 = 0.4;
        // output = 0.4·0.50 + 0.6·0.55 = 0.53 → |0.53 − 0.50| = 0.03; reduction = 1 − 0.03/0.05 = 0.4.
        XCTAssertEqual(s.inputFlicker, 0.05, accuracy: 0.005)
        XCTAssertEqual(s.outputFlicker, 0.03, accuracy: 0.006)
        XCTAssertEqual(s.reduction, 0.4, accuracy: 0.1)
    }

    /// A constant matte under zero flow has nothing to stabilize — both flickers are ~0 and `reduction` is 0,
    /// but the metric is still reported (transitions counted).
    func testConstantMatteIsZeroFlicker() async throws {
        let frame = grayFrame(0)
        let proc = VideoMatteProcessor(matte: { _ in self.grayFrame(0.5) }, flow: { a, b in self.zeroFlow(a, b) })
        for _ in 0..<4 { _ = try await proc.next(frame) }
        let s = try XCTUnwrap(proc.stability())
        XCTAssertEqual(s.transitions, 3)
        XCTAssertEqual(s.inputFlicker, 0, accuracy: 1e-4)
        XCTAssertEqual(s.outputFlicker, 0, accuracy: 1e-4)
        XCTAssertEqual(s.reduction, 0)
    }

    /// Single frame → no transition → nil metric (nothing to compare against).
    func testSingleFrameHasNoMetric() async throws {
        let proc = VideoMatteProcessor(matte: { _ in self.grayFrame(0.5) }, flow: { a, b in self.zeroFlow(a, b) })
        _ = try await proc.next(grayFrame(0))
        XCTAssertNil(proc.stability())
    }
}
