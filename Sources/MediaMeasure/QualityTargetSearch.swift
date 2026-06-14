//
// QualityTargetSearch.swift — MediaMeasure
//
// Binary search for the LOWEST encoder quality knob (smallest output) whose measured quality score
// still meets a target. Pure and oracle-agnostic — `measure` does the encode+score; this just
// drives the search. Salvaged from format-bridge's QualityTargetSearch, rewired to any score oracle
// (SSIMULACRA2). Assumes score is (roughly) monotonic increasing in quality.
//

import Foundation

public enum QualityTargetSearch {

    public struct Result: Sendable {
        public let quality: Double      // the chosen knob in [lo, hi]
        public let score: Double        // its measured score
        public let metTarget: Bool      // false ⇒ even `hi` couldn't reach the target
    }

    /// Find the lowest `quality ∈ [lo, hi]` with `measure(quality) >= target`. Runs `iterations`
    /// bisections; returns the best knob that met the target (or `hi` if none did).
    public static func search(target: Double, lo: Double = 0.0, hi: Double = 1.0,
                              iterations: Int = 8,
                              measure: (Double) throws -> Double) rethrows -> Result {
        var low = lo, high = hi
        var best: Result?

        // If even the top quality can't reach the target, return it (best effort).
        let hiScore = try measure(high)
        if hiScore < target { return Result(quality: high, score: hiScore, metTarget: false) }
        best = Result(quality: high, score: hiScore, metTarget: true)

        for _ in 0..<iterations {
            let mid = (low + high) / 2
            let s = try measure(mid)
            if s >= target {
                best = Result(quality: mid, score: s, metTarget: true)   // meets it → try lower
                high = mid
            } else {
                low = mid                                                // too low → raise
            }
        }
        return best ?? Result(quality: hi, score: hiScore, metTarget: true)
    }
}
