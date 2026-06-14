//
// ShotDetector.swift — MediaBridge
//
// Shot-boundary detection: a coarse per-frame signature (downsampled RGB histogram) plus an L1-
// distance threshold marks cuts. Pure and FFmpeg-free — salvaged verbatim from format-bridge (the
// algorithm operated on signatures the caller computed; the signature helper is added here). Useful
// for scene-aware keyframe placement / segment-wise optimization.
//

import CoreVideo
import Foundation

public enum ShotDetector {

    /// Frame indices where a new shot starts (always includes 0). A cut is declared when the L1
    /// distance between consecutive signatures exceeds `threshold` and at least `minShotFrames`
    /// have elapsed since the last cut (debounce).
    public static func boundaries(signatures: [[Float]],
                                  threshold: Float = 0.35,
                                  minShotFrames: Int = 6) -> [Int] {
        guard !signatures.isEmpty else { return [] }
        var starts = [0]
        var lastCut = 0
        for i in 1..<signatures.count {
            let d = distance(signatures[i - 1], signatures[i])
            if d > threshold && (i - lastCut) >= minShotFrames {
                starts.append(i)
                lastCut = i
            }
        }
        return starts
    }

    /// L1 distance between two equal-length signatures.
    public static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .greatestFiniteMagnitude }
        var sum: Float = 0
        for i in 0..<a.count { sum += abs(a[i] - b[i]) }
        return sum
    }

    /// Coarse normalized RGB histogram of a BGRA pixel buffer (`bins` per channel → `bins*3` values,
    /// summing to 1). Cheap and resolution-independent — good enough to separate shots.
    public static func signature(of pixelBuffer: CVPixelBuffer, bins: Int = 8) -> [Float] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer), w > 0, h > 0 else {
            return [Float](repeating: 0, count: bins * 3)
        }
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let src = base.assumingMemoryBound(to: UInt8.self)
        let shift = 8 - Int(log2(Double(bins)).rounded())     // 256 → bins
        var hist = [Float](repeating: 0, count: bins * 3)
        // Subsample on a fixed grid (≤ ~64×64 taps) so cost is independent of resolution.
        let stepX = max(1, w / 64), stepY = max(1, h / 64)
        var count: Float = 0
        var y = 0
        while y < h {
            let row = y * bpr
            var x = 0
            while x < w {
                let p = row + x * 4
                let b = Int(src[p + 0]) >> shift
                let g = Int(src[p + 1]) >> shift
                let r = Int(src[p + 2]) >> shift
                hist[b] += 1
                hist[bins + g] += 1
                hist[2 * bins + r] += 1
                count += 1
                x += stepX
            }
            y += stepY
        }
        if count > 0 { for i in hist.indices { hist[i] /= (count * 3) } }   // normalize to sum 1
        return hist
    }
}
