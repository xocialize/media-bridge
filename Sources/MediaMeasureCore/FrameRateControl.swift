//
// FrameRateControl.swift — MediaMeasureCore
//
// Per-frame quantizer allocation: which frames get the bits.
//
// This exists because of a measurement, not a theory. Encoders shipped in browsers hand back a
// bitrate knob and a rate controller tuned for streaming, and a streaming controller spends its
// budget by the CLOCK — it holds a bitrate through easy passages and starves the hard ones. A
// quality floor read at the 10th percentile is the exact opposite bet: it is a bet on UNIFORMITY,
// and it collects nothing for a high mean. Taking a flat quantizer away from that controller was
// already worth +16.3 p10 at matched bytes on the signage corpus. This is the next step — spending
// the remaining headroom where the frames actually need it.
//
// Two problems, one mechanism:
//
//   1. THE SPREAD. At a flat quantizer a clip's frames do not score alike. Measured on
//      tp_layersb_1080p at quantizer 24, over 24 sampled frames: a frame's score falls ~1.63 points
//      for every DOUBLING of its encoded size, r = -0.69, which accounts for 47% of the spread.
//      Every point a frame sits above the floor is bytes the gate will never reward.
//
//   2. THE STEP. A quantizer is an integer, and one step is worth ~11% of the file. On one 4K
//      master the search wanted a value between 21 and 22 and could only say 21, shipping a file
//      11% larger than the floor required. Real-valued `base` plus per-frame offsets makes the
//      EFFECTIVE rate continuous, because as `base` drifts the frames cross their rounding
//      boundaries a few at a time.
//
// Note the direction, which is the opposite of x264's `qcomp` and deliberately so. x264 gives
// complex frames a HIGHER quantizer, because complexity masks artifacts and its target is a
// bitrate. Ours is a perceptual floor on the worst frames, and complex frames measurably score
// LOWER at a fixed quantizer, so here they get a lower one. Copying qcomp's sign would move every
// frame the wrong way.
//
// And note what this is NOT: a dither. A dither manufactures worse frames, which a 10th-percentile
// gate punishes by construction. This moves frames TOWARD each other — the worst frames gain bits
// and the frames with headroom give them up.
//
// The signal is the per-frame encoded size from a probe pass, which is free: the encoder has
// already done the analysis, and it reports it for EVERY frame rather than only the sampled ones.
// That last part is load-bearing. A policy keyed on which frames happen to be scored would be
// optimising the sample instead of the video, which is the same failure the sampling stride's
// warning exists to prevent.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Musl)
import Musl
#endif

public enum FrameRateControl {

    /// How many quantizer steps to move a frame per doubling of its encoded size.
    ///
    /// This is a fitted slope, not a taste setting: score falls ~1.63 points per doubling and one
    /// quantizer step is worth ~1.25 points, so the correction is ~1.30. Because it comes from a
    /// least-squares fit it already carries its own shrinkage — a noisy predictor regresses toward
    /// the mean, so applying the *fitted* slope is the correct amount rather than an overcorrection.
    /// Raising it past the fit does not flatten harder, it amplifies the 53% the model cannot explain.
    public static let defaultStrength = 1.30

    /// Frames each side to average complexity over.
    ///
    /// A single frame's size is a noisy read on how hard its neighbourhood is — one badly-predicted
    /// frame after a cut is not evidence that the second after it is hard. x264 blurs complexity for
    /// the same reason. Kept small because a wide window smears real scene boundaries.
    public static let defaultBlurRadius = 2

    /// The furthest a frame may be moved from `base`, in quantizer steps.
    ///
    /// A cap matters because the signal is a ratio and ratios have no natural bound: one near-black
    /// frame a hundredth the reference size would otherwise ask for an offset of +6.6 and come back
    /// visibly broken. Four steps is roughly a 40% byte swing, which is as much as a per-frame
    /// decision should be trusted with on a 47% model.
    public static let defaultMaxOffset = 4.0

    /// Quantizer steps to subtract from a keyframe.
    ///
    /// The one rate-control rule nobody argues about: a keyframe is referenced by everything after
    /// it, so bits spent there are spent on the whole group.
    public static let defaultKeyFrameBoost = 3

    /// Per-frame quantizer offsets, in steps, from per-frame encoded sizes.
    ///
    /// Negative means "spend more here". The result is re-centred to mean zero so `base` keeps a
    /// stable meaning across clips — without that, a clip whose frames are mostly below the
    /// reference would silently shift the whole scale and the bisection above this would be
    /// searching a moving target.
    ///
    /// - Parameters:
    ///   - frameBytes: encoded size of every frame from a probe pass, in decode order.
    ///   - frameIsKey: which of those are keyframes. Keyframes are 10–50× their neighbours and are
    ///     excluded from both the reference and the blur — left in, one keyframe drags the
    ///     reference up and every inter frame looks easy by comparison.
    public static func offsets(frameBytes: [Int],
                               frameIsKey: [Bool],
                               strength: Double = defaultStrength,
                               blurRadius: Int = defaultBlurRadius,
                               maxOffset: Double = defaultMaxOffset) -> [Double] {
        let n = frameBytes.count
        guard n > 0 else { return [] }
        guard frameIsKey.count == n else { return [Double](repeating: 0, count: n) }

        /* Work in log space throughout: complexity is a ratio, and a geometric mean is the only
           average that does not let one 30 KB frame define "typical" for a clip of 3 KB frames. */
        var logSize = [Double](repeating: 0, count: n)
        for i in 0..<n {
            logSize[i] = log2(Double(max(frameBytes[i], 1)))
        }

        /* Blur over inter frames only. A keyframe keeps its own unblurred value, which it then
           does not use — its offset comes out of the same formula but the boost dominates. */
        var blurred = logSize
        if blurRadius > 0 {
            for i in 0..<n {
                var sum = 0.0
                var count = 0
                let lo = max(0, i - blurRadius)
                let hi = min(n - 1, i + blurRadius)
                for j in lo...hi where !frameIsKey[j] {
                    sum += logSize[j]
                    count += 1
                }
                blurred[i] = count > 0 ? sum / Double(count) : logSize[i]
            }
        }

        /* The reference is the typical INTER frame. Fall back to all frames only if a clip is
           somehow all keyframes, where every offset collapses to zero anyway. */
        var refSum = 0.0
        var refCount = 0
        for i in 0..<n where !frameIsKey[i] {
            refSum += blurred[i]
            refCount += 1
        }
        if refCount == 0 {
            for i in 0..<n { refSum += blurred[i] }
            refCount = n
        }
        let reference = refSum / Double(refCount)

        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let raw = -strength * (blurred[i] - reference)
            out[i] = min(max(raw, -maxOffset), maxOffset)
        }

        /* Re-centre AFTER clamping, so clamping cannot smuggle a bias into `base`. */
        var mean = 0.0
        for v in out { mean += v }
        mean /= Double(n)
        for i in 0..<n { out[i] -= mean }
        return out
    }

    /// Turn a real-valued base quantizer plus offsets into the integers an encoder accepts.
    ///
    /// `base` is deliberately a Double. That is the whole of the sub-integer mechanism: rounding
    /// happens per frame against a per-frame offset, so a base of 21.4 puts some frames at 21 and
    /// some at 22, and moving it to 21.5 moves only the frames sitting closest to a boundary. The
    /// file size therefore varies continuously with the knob, which an integer quantizer cannot do.
    ///
    /// Which frames cross first is not arbitrary — a frame's offset is its complexity, so the ones
    /// giving up a step are the ones the model says have headroom.
    public static func quantizers(base: Double,
                                  offsets: [Double],
                                  frameIsKey: [Bool],
                                  range: ClosedRange<Int>,
                                  keyFrameBoost: Int = defaultKeyFrameBoost) -> [Int] {
        let n = offsets.count
        guard n > 0, frameIsKey.count == n else { return [] }
        var out = [Int](repeating: range.lowerBound, count: n)
        for i in 0..<n {
            let boost = frameIsKey[i] ? Double(keyFrameBoost) : 0
            let q = (base + offsets[i] - boost).rounded()
            out[i] = min(max(Int(q), range.lowerBound), range.upperBound)
        }
        return out
    }

    /// Offsets and quantizers in one step, for a host that has no reason to hold the offsets.
    public static func plan(frameBytes: [Int],
                            frameIsKey: [Bool],
                            base: Double,
                            range: ClosedRange<Int>,
                            strength: Double = defaultStrength,
                            blurRadius: Int = defaultBlurRadius,
                            maxOffset: Double = defaultMaxOffset,
                            keyFrameBoost: Int = defaultKeyFrameBoost) -> [Int] {
        let o = offsets(frameBytes: frameBytes, frameIsKey: frameIsKey,
                        strength: strength, blurRadius: blurRadius, maxOffset: maxOffset)
        return quantizers(base: base, offsets: o, frameIsKey: frameIsKey,
                          range: range, keyFrameBoost: keyFrameBoost)
    }
}
