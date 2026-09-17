import XCTest
@testable import MediaMeasureCore

/// The rate controller's job is to move bits between frames without moving the meaning of the knob
/// above it. These pin the properties that make that true — the sign of the correction, the
/// stability of `base`, and the sub-integer behaviour — rather than any particular output, because
/// the constants are fitted and will be refitted.
final class FrameRateControlTests: XCTestCase {

    /// A clip with one genuinely hard stretch in the middle.
    private func clip(n: Int = 60, keyEvery: Int = 30) -> (bytes: [Int], isKey: [Bool]) {
        var bytes = [Int](repeating: 0, count: n)
        var isKey = [Bool](repeating: false, count: n)
        for i in 0..<n {
            isKey[i] = i % keyEvery == 0
            if isKey[i] { bytes[i] = 200_000 }
            else if (20..<30).contains(i) { bytes[i] = 24_000 }   // the hard stretch
            else { bytes[i] = 6_000 }
        }
        return (bytes, isKey)
    }

    // MARK: the direction of the correction

    func testComplexFramesGetALowerQuantizerThanEasyOnes() {
        let c = clip()
        let o = FrameRateControl.offsets(frameBytes: c.bytes, frameIsKey: c.isKey)
        /* Frame 25 is in the hard stretch, frame 5 is not. Negative offset = more bits.
           This is the sign that is OPPOSITE to x264's qcomp, so it is worth pinning: get it
           backwards and every frame moves the wrong way while the code still "works". */
        XCTAssertLessThan(o[25], o[5], "a complex frame must be given a LOWER quantizer than an easy one")
        XCTAssertLessThan(o[25], 0, "the hard stretch should be below the clip's centre")
        XCTAssertGreaterThan(o[5], 0, "an easy frame should give bits up")
    }

    func testTheCorrectionScalesWithStrength() {
        let c = clip()
        let weak = FrameRateControl.offsets(frameBytes: c.bytes, frameIsKey: c.isKey, strength: 0.5)
        let strong = FrameRateControl.offsets(frameBytes: c.bytes, frameIsKey: c.isKey, strength: 2.0)
        XCTAssertLessThan(strong[25], weak[25])
        /* Strength zero must be exactly the flat-quantizer behaviour we are trying to beat, so a
           regression can always be bisected against it. */
        let off = FrameRateControl.offsets(frameBytes: c.bytes, frameIsKey: c.isKey, strength: 0)
        for v in off { XCTAssertEqual(v, 0, accuracy: 1e-12) }
    }

    // MARK: keeping `base` meaningful

    func testOffsetsAreMeanZeroSoTheSearchKnobDoesNotDrift() {
        for bytes in [clip().bytes, clip(n: 97, keyEvery: 48).bytes] {
            let isKey = (0..<bytes.count).map { $0 % 30 == 0 }
            let o = FrameRateControl.offsets(frameBytes: bytes, frameIsKey: isKey)
            let mean = o.reduce(0, +) / Double(o.count)
            XCTAssertEqual(mean, 0, accuracy: 1e-9,
                           "a non-zero mean offset silently rescales `base`, and the bisection above would be searching a moving target")
        }
    }

    func testClampingCannotSmuggleABiasIntoBase() {
        /* One frame a hundredth of the reference would ask for an offset far past the cap. If
           re-centring happened before the clamp, the cap would leave a net bias behind. */
        var (bytes, isKey) = clip()
        bytes[40] = 30
        let o = FrameRateControl.offsets(frameBytes: bytes, frameIsKey: isKey)
        let mean = o.reduce(0, +) / Double(o.count)
        XCTAssertEqual(mean, 0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(o.map(abs).max() ?? 0, FrameRateControl.defaultMaxOffset + 1e-9)
    }

    func testKeyframesDoNotDefineWhatTypicalMeans() {
        /* A keyframe is 10-50x its neighbours. Counted in the reference, it drags the centre up and
           every inter frame reads as easy. The inter frames' offsets must not move when only the
           keyframes get bigger. */
        let c = clip()
        var heavier = c.bytes
        for i in 0..<heavier.count where c.isKey[i] { heavier[i] *= 8 }
        let a = FrameRateControl.offsets(frameBytes: c.bytes, frameIsKey: c.isKey)
        let b = FrameRateControl.offsets(frameBytes: heavier, frameIsKey: c.isKey)
        for i in 0..<a.count where !c.isKey[i] {
            XCTAssertEqual(a[i], b[i], accuracy: 1e-9, "inter frame \(i) moved because a KEYFRAME grew")
        }
    }

    // MARK: the sub-integer mechanism

    func testFileSizeCanMoveWithoutBaseCrossingAnInteger() {
        /* The point of a real-valued base: between 21.0 and 22.0 the assignment must change
           GRADUALLY, a few frames at a time, rather than all at once. That is what makes the
           effective rate continuous where an integer quantizer jumps ~11% of the file. */
        let c = clip()
        let o = FrameRateControl.offsets(frameBytes: c.bytes, frameIsKey: c.isKey)
        let range = 0...51
        var lastCount = -1
        var distinctSteps = 0
        for t in stride(from: 21.0, through: 22.0, by: 0.1) {
            let q = FrameRateControl.quantizers(base: t, offsets: o, frameIsKey: c.isKey, range: range)
            let atOrAbove22 = q.enumerated().filter { !c.isKey[$0.offset] && $0.element >= 22 }.count
            if atOrAbove22 != lastCount { distinctSteps += 1; lastCount = atOrAbove22 }
        }
        XCTAssertGreaterThan(distinctSteps, 2,
                             "the allocation must change more than once across a single quantizer step, or there is no sub-integer control")
    }

    func testRaisingTheBaseNeverLowersAnyFrameQuantizer() {
        /* Monotonicity is what the bisection above assumes. If raising the knob could lower some
           frame's quantizer, bytes could move the wrong way and the search would converge on
           nonsense. */
        let c = clip()
        let o = FrameRateControl.offsets(frameBytes: c.bytes, frameIsKey: c.isKey)
        var previous = FrameRateControl.quantizers(base: 18.0, offsets: o, frameIsKey: c.isKey, range: 0...51)
        for t in stride(from: 18.25, through: 30.0, by: 0.25) {
            let now = FrameRateControl.quantizers(base: t, offsets: o, frameIsKey: c.isKey, range: 0...51)
            for i in 0..<now.count {
                XCTAssertGreaterThanOrEqual(now[i], previous[i],
                                            "frame \(i) went DOWN when the base went up (base \(t))")
            }
            previous = now
        }
    }

    // MARK: bounds and degenerate inputs

    func testQuantizersStayInRangeAndKeyframesGetTheBoost() {
        let c = clip()
        let o = FrameRateControl.offsets(frameBytes: c.bytes, frameIsKey: c.isKey)
        let q = FrameRateControl.quantizers(base: 24, offsets: o, frameIsKey: c.isKey, range: 10...40)
        for v in q { XCTAssertTrue((10...40).contains(v)) }
        XCTAssertLessThan(q[0], q[1], "a keyframe must come out below the frames that reference it")
    }

    func testDegenerateInputsAreAnAnswerRatherThanATrap() {
        XCTAssertTrue(FrameRateControl.offsets(frameBytes: [], frameIsKey: []).isEmpty)
        /* Mismatched lengths are a caller bug; returning zeros keeps the encode flat and correct
           rather than trapping inside a wasm module where the trace is lost. */
        let mismatch = FrameRateControl.offsets(frameBytes: [1, 2, 3], frameIsKey: [true])
        XCTAssertEqual(mismatch, [0, 0, 0])
        /* A perfectly uniform clip has nothing to redistribute. */
        let flat = FrameRateControl.offsets(frameBytes: [5000, 5000, 5000, 5000],
                                            frameIsKey: [true, false, false, false])
        for v in flat { XCTAssertEqual(v, 0, accuracy: 1e-9) }
        /* A zero-byte frame must not become log2(0). */
        let zeroed = FrameRateControl.offsets(frameBytes: [0, 6000, 6000, 6000],
                                              frameIsKey: [false, false, false, false])
        for v in zeroed { XCTAssertTrue(v.isFinite) }
    }

    func testBlurSmoothsAOneFrameSpikeButKeepsARealStretch() {
        var (bytes, isKey) = clip()
        bytes[45] = 24_000                                     // a single-frame spike
        let blurred = FrameRateControl.offsets(frameBytes: bytes, frameIsKey: isKey, blurRadius: 2)
        let sharp = FrameRateControl.offsets(frameBytes: bytes, frameIsKey: isKey, blurRadius: 0)
        XCTAssertGreaterThan(blurred[45], sharp[45],
                             "a lone spike should be discounted — one hard frame is not evidence its neighbours are hard")
        /* The ten-frame stretch is real and must survive the blur nearly intact. */
        XCTAssertLessThan(blurred[25], sharp[25] + 0.35)
    }
}
