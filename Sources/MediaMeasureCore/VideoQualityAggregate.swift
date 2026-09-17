//
// VideoQualityAggregate.swift — MediaMeasureCore
//
// How a clip's per-frame scores become one verdict, and how many frames get scored in the first
// place. Both are pure arithmetic, and both are load-bearing promises rather than implementation
// details — so they live here, where a browser compiles the same source the Mac does, instead of
// being transcribed into whatever language the host happens to be.
//
// The frame-by-frame scoring around them is not here: that needs a decoder, which is platform work.
// Only the laws are shared.
//

/// Aggregated per-frame SSIMULACRA2 of a video pair.
///
/// For "perceptually equivalent" the **worst frames** matter most — one bad frame is visible — so
/// `minimum` and `p10` gate a quality target, never the mean alone. A mean can sit comfortably above
/// a floor while a whole stretch of the clip sits under it.
public struct VideoQualityScore: Sendable {
    public let mean: Double
    public let minimum: Double
    public let p10: Double          // 10th-percentile frame (worst-ish)
    public let framesScored: Int
    /// The per-frame scores behind the aggregates, in decode order of the SAMPLED frames. Exposed
    /// so a refinement pass can score only NEW frames and merge, instead of re-scoring from
    /// scratch — the near-gate rescore was measured at 42% of a near-floor item's wall precisely
    /// because it threw this sample away (PERFORMANCE-BASELINE §4.3).
    public let scores: [Double]

    public init(mean: Double, minimum: Double, p10: Double, framesScored: Int, scores: [Double]) {
        self.mean = mean
        self.minimum = minimum
        self.p10 = p10
        self.framesScored = framesScored
        self.scores = scores
    }
}

public enum VideoQuality {

    public enum ScoreError: Error { case noVideoTrack, dimensionMismatch, noFramesScored }

    /// Frames to aim for when sampling a clip. Twelve is the floor because a p10 taken over fewer
    /// samples stops being a percentile and becomes a noisy minimum; sixteen caps the cost.
    public static let defaultMinScoredFrames = 12
    public static let defaultMaxScoredFrames = 16

    /// Reduce per-frame scores to the standard aggregate. Public so callers can MERGE samples —
    /// a base pass plus an offset refinement pass — and re-aggregate without re-scoring.
    /// Returns nil for an empty sample rather than trapping, since "nothing was scored" is a
    /// real outcome a host has to report rather than crash on.
    public static func aggregate(_ scores: [Double]) -> VideoQualityScore? {
        guard !scores.isEmpty else { return nil }
        let sorted = scores.sorted()
        let mean = scores.reduce(0, +) / Double(scores.count)
        let p10 = sorted[Int(Double(sorted.count - 1) * 0.1)]
        return VideoQualityScore(mean: mean, minimum: sorted[0], p10: p10,
                                 framesScored: scores.count, scores: scores)
    }

    /// The sampling stride for a clip of `frameCount` frames.
    ///
    /// ⚠️ Do NOT "regularize" this — not to an even number, not to a round one. Measured
    /// 2026-08-14 (forgebench 20260814-142039 plus stride-5 dense rescores): an even sampling
    /// lattice resonates with content and GOP periodicity and **over-reads p10 by ~3.3 points**,
    /// against ~1.3 for the raw stride's phase-walking lattice. A search fed the tidier number
    /// ships smaller files that only *sampled* above the floor — which is the one failure this
    /// whole mechanism exists to prevent.
    public static func samplingStride(frameCount: Int,
                                      minScoredFrames: Int = defaultMinScoredFrames) -> Int {
        max(1, frameCount / max(1, minScoredFrames))
    }

    /// How many frames a given stride actually scores, capped.
    public static func sampledFrameCount(frameCount: Int, stride: Int,
                                         cap: Int = defaultMaxScoredFrames) -> Int {
        min(cap, (frameCount + max(1, stride) - 1) / max(1, stride))
    }
}
