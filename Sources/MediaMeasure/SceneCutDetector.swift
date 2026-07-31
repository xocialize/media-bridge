import Foundation
import CoreGraphics
import CoreVideo

/// How the adaptive threshold's **scale** is estimated from the recent-delta window. Never an absolute
/// constant either way — bitrate and content change the scale of the statistic (the corpus spans 6× in
/// bits-per-pixel).
public enum SceneCutScale: Sendable, Equatable {
    /// `p90 + k·(p90 − median)`. **Default.** The upper tail tracks the window's *motion* mode, so the
    /// threshold sits above real movement rather than above the noise floor.
    ///
    /// 🔑 This is what makes limited animation survivable. Anime is drawn on twos/threes: two of every
    /// three transitions are near-zero duplicate frames, so the delta distribution is zero-inflated, the
    /// median lands on the duplicate floor and the MAD collapses — under `.medianAbsoluteDeviation` every
    /// new drawing becomes an "outlier" at *every* k (measured: precision 0.06–0.12 across k=4…20).
    case upperTail
    /// `median + k·MAD`. The classic robust-outlier rule. Well behaved on unimodal (live-action) delta
    /// distributions, but see the caveat above — it degenerates on zero-inflated ones.
    case medianAbsoluteDeviation
}

/// Tuning for `SceneCutDetector`.
///
/// The threshold is **adaptive** — derived from the clip's own recent deltas via `scale` — never an
/// absolute constant. `k` and `scale` are the knobs; the per-content-class evaluation receipt
/// (`mlxengine-todo/probes/n11_threshold_eval.out`) is the reference for choosing them.
public struct SceneCutOptions: Sendable, Equatable {
    /// Threshold sensitivity, interpreted per `scale`. Higher k = fewer, harder cuts.
    ///
    /// The default (2.0, with `.upperTail`) is chosen for **recall**, not F1, because the two errors are
    /// not symmetric in this detector's job: a false positive fires an unnecessary temporal reset and
    /// costs a little smoothing, while a *missed* cut carries temporal state across a shot boundary —
    /// exactly the artefact scene-cut detection exists to prevent.
    public var k: Double
    /// Scale estimator for the adaptive threshold. See `SceneCutScale`.
    public var scale: SceneCutScale
    /// Rolling window of recent transition deltas the causal threshold is computed over (~2 s at 24 fps).
    public var windowSize: Int
    /// Minimum deltas observed before the causal detector may fire (warmup — the statistic is meaningless
    /// on a handful of samples). Transitions during warmup are never cuts.
    public var minHistory: Int
    /// Refractory gap: after a cut fires, no further cut for this many transitions. Replaces the two-pass
    /// local-maxima suppression causally, and collapses a flash frame's in+out spike pair into one event.
    public var minGapFrames: Int
    /// Floor on the estimated scale so a perfectly static shot (scale → 0) doesn't declare every twitch
    /// a cut.
    public var madFloor: Double

    public init(k: Double = 2.0, scale: SceneCutScale = .upperTail, windowSize: Int = 48,
                minHistory: Int = 12, minGapFrames: Int = 6, madFloor: Double = 0.01) {
        self.k = k
        self.scale = scale
        self.windowSize = max(4, windowSize)
        self.minHistory = max(2, minHistory)
        self.minGapFrames = max(1, minGapFrames)
        self.madFloor = madFloor
    }
}

/// Verdict for one frame **transition** (previous frame → this frame).
public struct SceneCutDecision: Sendable, Equatable {
    /// True when this transition is a hard cut: the new frame starts a new shot.
    public let isCut: Bool
    /// The transition's score: mean absolute luma-grid difference vs the previous frame (0…255 scale).
    public let score: Double
    /// The adaptive threshold the score was judged against (`.infinity` during warmup).
    public let threshold: Double
}

/// **Hard-cut (shot-boundary) detector** — the missing input to the shot resets that
/// `VideoMatteProcessor.reset()`, `VideoConsistencyProcessor.reset()` and `TemporalStability` already
/// document (GAP-PROGRAM N11). Per-frame statistic on frames the pipeline already decodes: a 40×24 luma
/// grid, frame-to-frame mean absolute difference, cuts as outliers above an adaptive threshold derived
/// from the clip's own recent deltas. Marginal cost in-pipeline is microseconds per frame.
///
/// **Scope: hard cuts only.** Dissolves, fades and wipes are gradual ramps this statistic does not
/// separate from motion — V1 explicitly does not detect them.
///
/// ⚠️ **Measured accuracy is strongly content-dependent** (hand-marked, 60 s per class, defaults;
/// receipt: `mlxengine-todo/probes/n11_threshold_eval.out`):
///
/// | content class | precision | recall |
/// |---|---|---|
/// | SD television (live action) | 0.48 | 0.91 |
/// | clean HD action | 0.74 | 0.93 |
/// | bitrate-starved live action | 0.41 | 1.00 |
/// | **anime (limited animation)** | **0.23** | **0.75** |
///
/// Known false positives, all measured rather than assumed: **global lighting transitions** within one
/// shot (a subway car entering a tunnel produces cut-magnitude deltas with no shot change) and, in anime,
/// **new drawings** on twos/threes. Flashes/strobes also fire; the refractory gap merges a flash's in+out
/// spike pair into one event but cannot remove it. **Anime is the weak class and no `k` fixes it** — see
/// `SceneCutScale.upperTail` for why, and prefer treating a fired cut as advisory on that content.
///
/// Precision below 1.0 is deliberate. For the reset this drives the errors are asymmetric — see
/// `SceneCutOptions.k`.
///
/// **Causal vs two-pass.** The streaming API (`next(_:)`) is **causal**: the threshold is computed over a
/// rolling window of *recent* deltas only, so it works frame-by-frame with zero lookahead. Two guards keep
/// the rolling statistics honest: a delta that fires as a cut is **excluded** from the window (a cut spike
/// must not poison the threshold it was judged against), and an above-threshold delta that was
/// refractory-suppressed is admitted **clamped to the threshold** (so sustained fast motion still lifts the
/// statistics instead of freezing them). Callers that hold the whole clip should prefer the two-pass
/// `cutTransitions(deltas:)`, which uses global statistics and local-maxima suppression (no warmup, no
/// causality compromise).
///
/// Deterministic: identical input sequences produce identical decisions. Stateful + serial; feed
/// transitions in order. Not thread-safe.
public final class SceneCutDetector {
    /// Luma-grid geometry (fixed; the measured configuration from the N11 probe).
    public static let gridWidth = 40
    public static let gridHeight = 24

    public let options: SceneCutOptions
    private var previousGrid: [Double]?
    private var window: [Double] = []          // recent non-cut transition deltas, oldest first
    private var transitionsSinceCut = Int.max  // no refractory suppression before the first cut

    public init(options: SceneCutOptions = .init()) {
        self.options = options
    }

    /// Forget all history (previous frame and rolling statistics) — call when the *caller* knows a new
    /// independent clip starts. A detected cut does NOT require this; the detector handles its own state.
    public func reset() {
        previousGrid = nil
        window.removeAll()
        transitionsSinceCut = .max
    }

    // MARK: - Streaming (causal)

    /// Feed the next frame in order. Returns the verdict for the transition (previous frame → this frame),
    /// or nil for the first frame after init/`reset()` (no transition exists yet).
    public func next(_ frame: CGImage) -> SceneCutDecision? {
        next(lumaGrid: Self.lumaGrid(of: frame))
    }

    /// As `next(_:)`, for callers already holding a BGRA pixel buffer (avoids the CGImage hop).
    /// Returns nil for the first frame, or if the buffer isn't 32BGRA.
    public func next(_ pixelBuffer: CVPixelBuffer) -> SceneCutDecision? {
        guard let grid = Self.lumaGrid(of: pixelBuffer) else { return nil }
        return next(lumaGrid: grid)
    }

    /// As `next(_:)`, for callers off the CVPixelBuffer/CGImage path that compute the 40×24 luma grid
    /// themselves (`Self.gridWidth × Self.gridHeight` values, 0…255 luma, row-major).
    public func next(lumaGrid grid: [Double]) -> SceneCutDecision? {
        defer { previousGrid = grid }
        guard let prev = previousGrid, prev.count == grid.count, !grid.isEmpty else { return nil }
        var sum = 0.0
        for i in 0..<grid.count { sum += abs(grid[i] - prev[i]) }
        return next(delta: sum / Double(grid.count))
    }

    /// The causal decision itself, on a transition's already-computed delta. Feeding a clip's deltas
    /// through this in order is **exactly** what the frame-based `next` overloads do — offline evaluation
    /// and the shipping streaming path share this one state machine rather than two copies of it.
    public func next(delta: Double) -> SceneCutDecision {
        guard window.count >= options.minHistory else {
            window.append(delta)
            transitionsSinceCut = transitionsSinceCut == .max ? .max : transitionsSinceCut + 1
            return SceneCutDecision(isCut: false, score: delta, threshold: .infinity)
        }

        let threshold = Self.threshold(over: window, k: options.k, scale: options.scale,
                                       madFloor: options.madFloor)
        let outlier = delta > threshold
        let isCut = outlier && transitionsSinceCut >= options.minGapFrames

        if isCut {
            transitionsSinceCut = 0
        } else {
            transitionsSinceCut = transitionsSinceCut == .max ? .max : transitionsSinceCut + 1
            // Suppressed outliers are admitted clamped; a fired cut is excluded entirely.
            window.append(outlier ? threshold : delta)
            if window.count > options.windowSize { window.removeFirst() }
        }
        return SceneCutDecision(isCut: isCut, score: delta, threshold: threshold)
    }

    /// Run the **causal** detector over a whole clip's transition deltas → cut transition indices.
    /// For offline evaluation and receipts; the result is identical to streaming the frames.
    public static func causalCutTransitions(deltas: [Double],
                                            options: SceneCutOptions = .init()) -> [Int] {
        let det = SceneCutDetector(options: options)
        return deltas.indices.filter { det.next(delta: deltas[$0]).isCut }
    }

    // MARK: - Two-pass (whole clip in hand)

    /// Two-pass detection over a full clip's transition deltas: global `median + k·MAD` threshold, cuts as
    /// **local maxima** above it (a single transition's ramp neighbours collapse to one cut). Returns indices
    /// into `deltas` (delta `i` = the transition from frame `i` to frame `i+1`). Prefer this over the
    /// streaming API when the caller has the whole clip — no warmup, no causality compromise.
    public static func cutTransitions(deltas: [Double], k: Double = 2.0,
                                      scale: SceneCutScale = .upperTail,
                                      madFloor: Double = 0.01) -> [Int] {
        guard deltas.count > 2 else { return [] }
        let thresh = threshold(over: deltas, k: k, scale: scale, madFloor: madFloor)
        var cuts: [Int] = []
        for i in 0..<deltas.count where deltas[i] > thresh {
            let l = i > 0 ? deltas[i - 1] : 0
            let r = i < deltas.count - 1 ? deltas[i + 1] : 0
            if deltas[i] >= l && deltas[i] >= r { cuts.append(i) }
        }
        return cuts
    }

    /// The adaptive threshold over `values`, per `scale`.
    public static func threshold(over values: [Double], k: Double,
                                 scale: SceneCutScale = .upperTail,
                                 madFloor: Double = 0.01) -> Double {
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        switch scale {
        case .medianAbsoluteDeviation:
            let absDev = values.map { abs($0 - median) }.sorted()
            let mad = max(absDev[absDev.count / 2], madFloor)
            return median + k * mad
        case .upperTail:
            let i = min(sorted.count - 1, max(0, Int((0.90 * Double(sorted.count - 1)).rounded())))
            let p90 = sorted[i]
            return p90 + k * max(p90 - median, madFloor)
        }
    }

    // MARK: - Luma grids

    /// 40×24 luma grid of a frame (BT.601 luma, 0…255, row-major). Downsampling is nearest-sample
    /// (point sampling at cell centers), matching the measured probe configuration.
    public static func lumaGrid(of image: CGImage) -> [Double] {
        let gw = gridWidth, gh = gridHeight
        var bytes = [UInt8](repeating: 0, count: gw * gh * 4)
        if let ctx = CGContext(data: &bytes, width: gw, height: gh, bitsPerComponent: 8,
                               bytesPerRow: gw * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: gw, height: gh))
        }
        var grid = [Double](repeating: 0, count: gw * gh)
        for i in 0..<(gw * gh) {
            let p = i * 4    // RGBA
            grid[i] = 0.299 * Double(bytes[p]) + 0.587 * Double(bytes[p + 1]) + 0.114 * Double(bytes[p + 2])
        }
        return grid
    }

    /// 40×24 luma grid of a **32BGRA** pixel buffer (point-sampled at cell centers — byte-identical to the
    /// N11 probe's statistic). Returns nil for other pixel formats.
    public static func lumaGrid(of pixelBuffer: CVPixelBuffer) -> [Double]? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer), w > 0, h > 0 else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = baseAddr.assumingMemoryBound(to: UInt8.self)
        let gw = gridWidth, gh = gridHeight
        var grid = [Double](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            let y = gy * h / gh + h / (2 * gh)
            for gx in 0..<gw {
                let x = gx * w / gw + w / (2 * gw)
                let p = y * stride + x * 4    // BGRA
                grid[gy * gw + gx] = 0.114 * Double(base[p]) + 0.587 * Double(base[p + 1])
                    + 0.299 * Double(base[p + 2])
            }
        }
        return grid
    }
}
