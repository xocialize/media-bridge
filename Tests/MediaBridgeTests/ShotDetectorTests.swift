import XCTest
import CoreVideo
@testable import MediaBridge

final class ShotDetectorTests: XCTestCase {

    /// Two stable "shots" with a hard cut between them → exactly one boundary at the cut.
    func testBoundariesOnSyntheticSignatures() {
        let shotA = [Float]([1, 0, 0, 0])      // constant signature for frames 0..9
        let shotB = [Float]([0, 0, 0, 1])      // constant, very different, for frames 10..19
        var sigs = [[Float]](repeating: shotA, count: 10)
        sigs += [[Float]](repeating: shotB, count: 10)

        let cuts = ShotDetector.boundaries(signatures: sigs, threshold: 0.5, minShotFrames: 3)
        XCTAssertEqual(cuts, [0, 10])
    }

    func testDebounceSuppressesRapidCuts() {
        // Alternating every frame, but minShotFrames=6 suppresses all but the spaced ones.
        let a = [Float]([1, 0]), b = [Float]([0, 1])
        let sigs = (0..<12).map { $0 % 2 == 0 ? a : b }
        let cuts = ShotDetector.boundaries(signatures: sigs, threshold: 0.5, minShotFrames: 6)
        XCTAssertEqual(cuts.first, 0)
        XCTAssertTrue(cuts.dropFirst().allSatisfy { $0 % 6 == 0 || $0 >= 6 })
        // Consecutive cuts are ≥ 6 apart.
        for i in 1..<cuts.count { XCTAssertGreaterThanOrEqual(cuts[i] - cuts[i - 1], 6) }
    }

    /// The signature of a solid-color frame is a normalized histogram summing to 1, and two
    /// different solid colors are far apart in L1.
    func testSignatureOfSolidColors() {
        func solid(_ b: UInt8, _ g: UInt8, _ r: UInt8) -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<64 { for x in 0..<64 {
                let p = y * bpr + x * 4
                base[p] = b; base[p + 1] = g; base[p + 2] = r; base[p + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            return buf
        }
        let black = ShotDetector.signature(of: solid(0, 0, 0))
        let white = ShotDetector.signature(of: solid(255, 255, 255))
        XCTAssertEqual(black.reduce(0, +), 1, accuracy: 1e-4)
        XCTAssertGreaterThan(ShotDetector.distance(black, white), 1.5, "opposite colors are far apart")
        XCTAssertEqual(ShotDetector.distance(black, black), 0, accuracy: 1e-6)
    }
}
