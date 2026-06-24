import XCTest
import CoreGraphics
@testable import MediaMeasure

final class VideoConsistencyTests: XCTestCase {
    private let w = 8, h = 8
    private final class Counter { var n = 0; func next() -> Int { defer { n += 1 }; return n } }

    private func grayFrame(_ v: Float) -> CGImage {
        VideoConsistencyProcessor.rgbCGImage([Float](repeating: v, count: w * h * 3), width: w, height: h)
    }
    private func zeroFlow(_ a: CGImage, _ b: CGImage) -> DenseFlow {
        DenseFlow(width: a.width, height: a.height, uv: [Float](repeating: 0, count: a.width * a.height * 2))
    }

    // MARK: FlowWarp multi-channel

    func testChannelsZeroFlowIsIdentity() {
        let c = 3, prev = (0..<(w * h * c)).map { Float($0 % 7) / 6 }
        let flow = DenseFlow(width: w, height: h, uv: [Float](repeating: 0, count: w * h * 2))
        let (warped, valid) = FlowWarp.backwardWarpChannels(prev: prev, width: w, height: h, channels: c, flow: flow)
        for i in 0..<prev.count { XCTAssertEqual(warped[i], prev[i], accuracy: 1e-6) }
        XCTAssertTrue(valid.allSatisfy { $0 })
    }

    func testChannelsConstantShiftAndOOB() {
        let c = 3
        // u=+1 everywhere → output(x) samples source(x+1); last column samples x=w → OOB → invalid.
        var uv = [Float](repeating: 0, count: w * h * 2)
        for p in 0..<(w * h) { uv[p * 2] = 1 }
        let prev = (0..<(w * h * c)).map { Float(($0 / c) % w) }   // value = column index, all channels
        let (warped, valid) = FlowWarp.backwardWarpChannels(
            prev: prev, width: w, height: h, channels: c, flow: DenseFlow(width: w, height: h, uv: uv))
        XCTAssertEqual(warped[0], 1, accuracy: 1e-5)              // col 0 ← col 1's value
        XCTAssertTrue(valid[0])
        XCTAssertFalse(valid[w - 1])                              // last col shifted off-frame
    }

    // MARK: VideoConsistencyProcessor

    /// Small within-tolerance jitter (0.50 → 0.53, tol 0.06, strength 0.5) under zero flow → the stabilized
    /// output flickers less than the raw enhanced frame (positive, bounded reduction).
    func testReducesFlickerOnSmallJitter() async throws {
        let src = grayFrame(0)
        let count = Counter()
        let proc = VideoConsistencyProcessor(
            enhance: { _ in self.grayFrame(count.next() == 0 ? 0.50 : 0.53) },
            flow: { a, b in self.zeroFlow(a, b) })
        _ = try await proc.next(src)
        _ = try await proc.next(src)
        let s = try XCTUnwrap(proc.stability())
        XCTAssertEqual(s.transitions, 1)
        XCTAssertEqual(s.inputFlicker, 0.03, accuracy: 0.005)
        XCTAssertLessThan(s.outputFlicker, s.inputFlicker)        // stabilization removed flicker
        XCTAssertGreaterThan(s.reduction, 0.1)
    }

    func testConstantOutputIsZeroFlicker() async throws {
        let src = grayFrame(0)
        let proc = VideoConsistencyProcessor(enhance: { _ in self.grayFrame(0.5) }, flow: { a, b in self.zeroFlow(a, b) })
        for _ in 0..<4 { _ = try await proc.next(src) }
        let s = try XCTUnwrap(proc.stability())
        XCTAssertEqual(s.transitions, 3)
        XCTAssertEqual(s.outputFlicker, 0, accuracy: 1e-4)
    }

    /// A big jump (> tolerance) is treated as real change — kept fresh, not smeared (reduction ≈ 0).
    func testLargeChangeIsNotSmeared() async throws {
        let src = grayFrame(0)
        let count = Counter()
        let proc = VideoConsistencyProcessor(
            enhance: { _ in self.grayFrame(count.next() == 0 ? 0.2 : 0.8) },   // 0.6 jump ≫ tol 0.06
            flow: { a, b in self.zeroFlow(a, b) })
        _ = try await proc.next(src)
        let out = try await proc.next(src)
        // Output should still read ~0.8 (fresh preserved), not pulled toward 0.2.
        let f = VideoConsistencyProcessor.rgbFloats(out, width: w, height: h)
        XCTAssertEqual(f[0], 0.8, accuracy: 0.02)
    }

    func testSingleFrameHasNoMetric() async throws {
        let proc = VideoConsistencyProcessor(enhance: { _ in self.grayFrame(0.5) }, flow: { a, b in self.zeroFlow(a, b) })
        _ = try await proc.next(grayFrame(0))
        XCTAssertNil(proc.stability())
    }
}
