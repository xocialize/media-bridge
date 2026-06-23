import XCTest
@testable import MediaMeasure

final class FlowWarpTests: XCTestCase {
    // A 4×4 ramp matte (value = x/3) for predictable sampling.
    private func ramp(_ w: Int, _ h: Int) -> [Float] {
        (0..<(w * h)).map { Float($0 % w) / Float(w - 1) }
    }

    func testZeroFlowIsIdentity() {
        let w = 4, h = 4, m = ramp(w, h)
        let flow = DenseFlow(width: w, height: h, uv: [Float](repeating: 0, count: w * h * 2))
        let (warped, valid) = FlowWarp.backwardWarp(prevMatte: m, width: w, height: h, flow: flow)
        XCTAssertEqual(warped, m)                       // zero flow → unchanged
        XCTAssertTrue(valid.allSatisfy { $0 })          // all in-bounds
    }

    func testConstantShiftSamplesShifted() {
        // Backward-warp by u=+1: output(x,y) samples source(x+1,y) → the ramp shifts left by one column.
        let w = 4, h = 4, m = ramp(w, h)
        var uv = [Float](repeating: 0, count: w * h * 2)
        for p in 0..<(w * h) { uv[p * 2] = 1 }          // u = +1 everywhere
        let flow = DenseFlow(width: w, height: h, uv: uv)
        let (warped, valid) = FlowWarp.backwardWarp(prevMatte: m, width: w, height: h, flow: flow)
        // column 0 now holds the old column 1's value (1/3); last column samples x=4 → out of bounds → invalid.
        XCTAssertEqual(warped[0], 1.0 / 3.0, accuracy: 1e-5)
        XCTAssertTrue(valid[0])
        XCTAssertFalse(valid[w - 1])                    // x=3 + u=1 = 4 > maxX → disocclusion
    }

    func testUpscaleScalesDisplacementsByRatio() {
        // Constant field (u=2, v=3) at 4×4, upscaled ×2 → 8×8 with displacements scaled by the ratio
        // (u→4, v→6): a 1-px move at the reduced scale is 2 px at full scale.
        let w = 4, h = 4
        var uv = [Float](repeating: 0, count: w * h * 2)
        for p in 0..<(w * h) { uv[p * 2] = 2; uv[p * 2 + 1] = 3 }
        let up = DenseFlow(width: w, height: h, uv: uv).upscaled(toWidth: 8, toHeight: 8)
        XCTAssertEqual(up.width, 8); XCTAssertEqual(up.height, 8)
        XCTAssertEqual(up.uv.count, 8 * 8 * 2)
        for (i, c) in up.uv.enumerated() {
            XCTAssertEqual(c, i % 2 == 0 ? 4 : 6, accuracy: 1e-4)   // u=4, v=6 everywhere
        }
    }

    func testUpscaleSameSizeIsIdentity() {
        let w = 4, h = 4
        let f = DenseFlow(width: w, height: h, uv: ramp(w, h).flatMap { [$0, -$0] })
        XCTAssertEqual(f.upscaled(toWidth: w, toHeight: h), f)      // no-op when already sized
    }

    func testOutOfBoundsMarkedInvalid() {
        let w = 4, h = 4, m = ramp(w, h)
        var uv = [Float](repeating: 0, count: w * h * 2)
        for p in 0..<(w * h) { uv[p * 2] = -10; uv[p * 2 + 1] = -10 }   // push everything off-frame
        let flow = DenseFlow(width: w, height: h, uv: uv)
        let (_, valid) = FlowWarp.backwardWarp(prevMatte: m, width: w, height: h, flow: flow)
        XCTAssertTrue(valid.allSatisfy { !$0 })
    }
}
