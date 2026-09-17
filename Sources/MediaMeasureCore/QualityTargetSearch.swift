//
// QualityTargetSearch.swift — MediaMeasureCore
//
// Binary search for the LOWEST encoder quality knob (smallest output) whose measured quality score
// still meets a target. Pure and oracle-agnostic — `measure` does the encode+score; this just
// drives the search. Salvaged from format-bridge's QualityTargetSearch, rewired to any score oracle
// (SSIMULACRA2). Assumes score is (roughly) monotonic increasing in quality.
//
// The law lives in `Stepper`, and `search` is a thin driver over it. That split exists so a host
// whose `measure` is ASYNCHRONOUS can run the identical search: a browser encodes with canvas and
// scores on the GPU, both of which return promises, and a callback-driven search cannot await. It
// steps the same state machine instead of reimplementing the bisection in another language — which
// matters because "the lowest knob that still clears the floor" IS the product's promise, and two
// implementations of it would be free to drift.
//
// No imports needed: this is arithmetic over Double. Deliberately kept that way so the search
// compiles anywhere the estimator does.
//

public enum QualityTargetSearch {

    public struct Result: Sendable {
        public let quality: Double      // the chosen knob in [lo, hi]
        public let score: Double        // its measured score
        public let metTarget: Bool      // false ⇒ even `hi` couldn't reach the target

        public init(quality: Double, score: Double, metTarget: Bool) {
            self.quality = quality
            self.score = score
            self.metTarget = metTarget
        }
    }

    /// The search as a resumable state machine.
    ///
    /// Drive it by calling `next(nil)` once, then `next(score)` with the measurement of whatever
    /// knob it last asked for, until it answers `.finished`.
    public struct Stepper: Sendable {

        public enum Step: Sendable {
            /// Measure this quality knob and hand the score back to the next `next(_:)`.
            case measure(Double)
            /// The search is over.
            case finished(Result)
        }

        private enum Phase: Sendable {
            case ceiling          // probing `hi` — can the target be reached at all?
            case bisect(Int)      // bisection round n
            case done
        }

        private let target: Double
        private let hi: Double
        private let iterations: Int
        private var low: Double
        private var high: Double
        private var phase: Phase = .ceiling
        private var best: Result?
        private var pendingQuality: Double = 0

        public init(target: Double, lo: Double = 0.0, hi: Double = 1.0, iterations: Int = 8) {
            self.target = target
            self.hi = hi
            self.iterations = iterations
            self.low = lo
            self.high = hi
        }

        /// Advance. Pass nil on the first call, then the score of the last requested knob.
        public mutating func next(_ score: Double?) -> Step {
            switch phase {
            case .ceiling:
                guard let hiScore = score else {
                    // First call: ask for the ceiling. Probing `hi` first is not an optimisation —
                    // it is how "this floor is unreachable" stays distinguishable from "here is a
                    // best effort", which the caller must not confuse.
                    pendingQuality = hi
                    return .measure(hi)
                }
                if hiScore < target {
                    phase = .done
                    return .finished(Result(quality: hi, score: hiScore, metTarget: false))
                }
                best = Result(quality: hi, score: hiScore, metTarget: true)
                return beginBisect(round: 0)

            case .bisect(let round):
                if let s = score {
                    if s >= target {
                        best = Result(quality: pendingQuality, score: s, metTarget: true)
                        high = pendingQuality          // meets it → try lower
                    } else {
                        low = pendingQuality           // too low → raise
                    }
                }
                return beginBisect(round: round + 1)

            case .done:
                return .finished(best ?? Result(quality: hi, score: target, metTarget: true))
            }
        }

        private mutating func beginBisect(round: Int) -> Step {
            guard round < iterations else {
                phase = .done
                return .finished(best ?? Result(quality: hi, score: target, metTarget: true))
            }
            phase = .bisect(round)
            pendingQuality = (low + high) / 2
            return .measure(pendingQuality)
        }
    }

    /// Find the lowest `quality ∈ [lo, hi]` with `measure(quality) >= target`. Runs `iterations`
    /// bisections; returns the best knob that met the target (or `hi` if none did).
    public static func search(target: Double, lo: Double = 0.0, hi: Double = 1.0,
                              iterations: Int = 8,
                              measure: (Double) throws -> Double) rethrows -> Result {
        var stepper = Stepper(target: target, lo: lo, hi: hi, iterations: iterations)
        var score: Double?
        while true {
            switch stepper.next(score) {
            case .measure(let q): score = try measure(q)
            case .finished(let r): return r
            }
        }
    }
}
