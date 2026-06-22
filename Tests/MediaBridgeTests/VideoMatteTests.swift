import XCTest
import CoreGraphics
@testable import MediaMeasure

final class VideoMatteTests: XCTestCase {
    private let w = 8, h = 8

    private func uniformMatte(_ v: Float) -> CGImage {
        VideoMatteProcessor.grayCGImage([Float](repeating: v, count: w * h), width: w, height: h)
    }
    private func zeroFlow(_ cur: CGImage, _ prev: CGImage) -> DenseFlow {
        DenseFlow(width: cur.width, height: cur.height,
                  uv: [Float](repeating: 0, count: cur.width * cur.height * 2))
    }
    private func meanAbsDelta(_ a: [Float]) -> Float {
        zip(a.dropFirst(), a).map { abs($0 - $1) }.reduce(0, +) / Float(a.count - 1)
    }
    /// Drive the processor over a list of fresh uniform-matte values with a static (zero-flow) scene.
    private func run(_ vals: [Float], strength: Float, tolerance: Float) async throws -> [Float] {
        var queue = vals.map(uniformMatte)
        let proc = VideoMatteProcessor(
            options: .init(temporalStrength: strength, agreementTolerance: tolerance),
            matte: { _ in queue.removeFirst() },
            flow: { cur, prev in self.zeroFlow(cur, prev) })
        let frame = uniformMatte(0.5)
        var out: [Float] = []
        for _ in vals { out.append(VideoMatteProcessor.grayFloats(try await proc.next(frame))[0]) }
        return out
    }

    /// Sub-tolerance jitter on a static scene gets smoothed → less frame-to-frame flicker than the fresh input.
    func testTemporalSmoothingReducesFlicker() async throws {
        let fresh: [Float] = [0.78, 0.82, 0.78, 0.82, 0.78, 0.82]   // ±0.02 jitter, gap 0.04 < tol 0.15
        let stable = try await run(fresh, strength: 0.6, tolerance: 0.15)
        XCTAssertEqual(stable[0], fresh[0], accuracy: 0.01)         // frame 0 = passthrough (no history)
        XCTAssertLessThan(meanAbsDelta(stable), meanAbsDelta(fresh) * 0.8)  // flicker materially reduced
    }

    /// A large frame-to-frame change (a real edit / new coverage) exceeds tolerance → trust the fresh matte.
    func testLargeChangePreserved() async throws {
        let fresh: [Float] = [0.2, 0.9, 0.2, 0.9]                   // gap 0.7 ≫ tol 0.15 → agreement 0
        let stable = try await run(fresh, strength: 0.6, tolerance: 0.15)
        for i in fresh.indices { XCTAssertEqual(stable[i], fresh[i], accuracy: 0.01) }
    }

    /// strength 0 = per-frame passthrough (no smoothing): stable matches fresh exactly.
    func testZeroStrengthIsPassthrough() async throws {
        let fresh: [Float] = [0.3, 0.5, 0.4, 0.6]
        let stable = try await run(fresh, strength: 0, tolerance: 0.15)
        for i in fresh.indices { XCTAssertEqual(stable[i], fresh[i], accuracy: 0.01) }
    }
}
