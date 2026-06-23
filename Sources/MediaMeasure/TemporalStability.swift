import Foundation

/// Motion-compensated temporal-stability metric for a stabilized matte sequence — a flicker gate for video
/// matting. For each frame transition the processor already has the cur→prev flow and the flow-warped previous
/// **stabilized** matte (`warped`); flicker is how much a matte still differs from that motion-compensated
/// previous, averaged over **valid** (non-disoccluded) pixels — so genuine motion, which the flow tracks,
/// does not count, only residual jitter does.
///
/// Reported for the raw per-frame matte (`inputFlicker`, the flicker *before* stabilizing) and the stabilized
/// output (`outputFlicker`, the residual *after*). Both are mean absolute matte differences in `[0,1]` units;
/// lower is steadier. `reduction` is the fraction the temporal blend removed.
public struct TemporalStability: Sendable, Equatable {
    /// Frame transitions measured (= stabilized frames − shot starts; the first frame of a shot has no prev).
    public let transitions: Int
    /// Mean motion-compensated |rawMatte − warpedPrevStable| over valid pixels (flicker BEFORE stabilizing).
    public let inputFlicker: Float
    /// Mean motion-compensated |stabilizedMatte − warpedPrevStable| over valid pixels (residual AFTER).
    public let outputFlicker: Float

    public init(transitions: Int, inputFlicker: Float, outputFlicker: Float) {
        self.transitions = transitions
        self.inputFlicker = inputFlicker
        self.outputFlicker = outputFlicker
    }

    /// Fraction of motion-compensated flicker the stabilization removed (0…1); 0 when there was none to remove.
    public var reduction: Float { inputFlicker > 0 ? max(0, 1 - outputFlicker / inputFlicker) : 0 }
}

/// Outcome of a measured video-matte run: frames written + the temporal-stability metric (nil when there were
/// no transitions to measure — e.g. a single-frame clip).
public struct VideoMatteOutcome: Sendable, Equatable {
    public let framesWritten: Int
    public let stability: TemporalStability?
    public init(framesWritten: Int, stability: TemporalStability?) {
        self.framesWritten = framesWritten
        self.stability = stability
    }
}
