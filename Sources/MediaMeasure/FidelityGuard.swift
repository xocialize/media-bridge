//
// FidelityGuard.swift — MediaMeasure
//
// N8 Axis B — the **fidelity / anti-hallucination** axis, zero-weight half.
// See `mlxengine-todo/GAP-PROGRAM.md` §N8.
//
// Two measures, both weight-free, license-free and license-exposure-free:
//
//   1. `downsampleConsistency` — for any ×N upscale, downsample the result back onto the source
//      grid and compare. **Any detail that does not survive that round trip was invented, not
//      recovered.** This is the only measurement in N8 with a ground-truth rather than a merely
//      correlational interpretation, and nothing in the category ships it.
//
//   2. `perOctaveSSIM` — SSIM per octave as a *vector*, never a scalar. Legitimate denoise and
//      sharpen live almost entirely in the top one or two octaves; hallucination and geometry
//      drift move mid and low frequencies. The expected signature is "top octave changed a lot,
//      everything below unchanged" — any deviation from that shape is a bug, and the shape is
//      invisible to a single number.
//
// Both report a **worst-tile** figure alongside the global one. Gating on the mean is the mistake
// N8 names explicitly: a hallucinated face in a 24 MP landscape moves a global score by nothing.
//
// 🔑 Framing that has to survive contact with the UI: in a before/after setup a full-reference
// score is monotone in *how much the image changed*, not in whether it improved — a pipeline that
// maximizes one converges on the identity function. Nothing here is a quality signal. Quality is
// Axis A (`NR(after) − NR(before)`, engine-backed, not in this package). These are the guard.
//
// Deliberately NOT here: DISTS. It needs VGG16 weights, which makes it neither weight-free nor
// license-clean (torchvision has never issued an explicit grant for its weights — N8's footnote).
// It belongs behind the engine seam if it is ever wanted, not in a net-clean measurement target.
//

import CoreGraphics
import Foundation

public enum FidelityGuard {

    public enum GuardError: Error, Equatable {
        /// CGImage could not be rasterized to bytes.
        case rasterFailed
        /// Too small to carry a valid SSIM region after border cropping.
        case tooSmall
        /// The result is smaller than the source in some dimension — not an upscale or a restore.
        case resultSmallerThanSource
    }

    // MARK: - Tile map

    /// Per-tile values over an image, row-major. The point of this type is `worst`: a global mean
    /// hides exactly the localized failure this whole axis exists to catch.
    public struct TileMap: Sendable, Equatable {
        public let columns: Int
        public let rows: Int
        /// Tile edge length in pixels, on the grid the values were computed over.
        public let tileSize: Int
        /// `columns * rows` values, row-major, top-left origin.
        public let values: [Double]

        public init(columns: Int, rows: Int, tileSize: Int, values: [Double]) {
            self.columns = columns
            self.rows = rows
            self.tileSize = tileSize
            self.values = values
        }

        /// The value to gate on.
        public var worst: Double { values.min() ?? .nan }

        public var mean: Double {
            values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
        }

        public func value(column: Int, row: Int) -> Double {
            precondition(column >= 0 && column < columns && row >= 0 && row < rows)
            return values[row * columns + column]
        }
    }

    // MARK: - 1 · Downsample consistency

    public struct DownsampleConsistency: Sendable, Equatable {
        /// Detected scale factor of `result` over `source` (1.0 for a same-size restore).
        public let scaleX: Double
        public let scaleY: Double
        /// dB over gamma-encoded luma; `.infinity` when the round trip is bit-exact.
        public let psnr: Double
        /// Global mean SSIM over the valid (border-cropped) region.
        public let ssim: Double
        /// Per-tile SSIM. **Gate on `ssimTiles.worst`, display the map.**
        public let ssimTiles: TileMap

        /// Convenience: the number a UI would show as "Fidelity", 0…100.
        public var fidelityPercent: Double { max(0, min(1, ssim)) * 100 }
    }

    /// Downsample `result` back onto `source`'s grid and measure how much of it was really there.
    ///
    /// - Parameters:
    ///   - source: the input the pipeline was given.
    ///   - result: the pipeline's output. Must be ≥ `source` in both dimensions.
    ///   - tileSize: tile edge on the source grid. Smaller finds smaller lies, at more noise per tile.
    ///
    /// ⚠️ **The downsampling filter is part of the measurement, not an implementation detail.** This
    /// uses an area (box) average, which is the correct antialiasing reduction and the one that makes
    /// "did this detail survive?" a fair question. A different kernel would charge the model for the
    /// *filter's* mismatch on top of its own invention. If a caller ever needs a different reduction,
    /// it must be a parameter with the score re-baselined, never a silent swap.
    public static func downsampleConsistency(source: CGImage,
                                             result: CGImage,
                                             tileSize: Int = 128) throws -> DownsampleConsistency {
        let src = try lumaPlane(from: source)
        let res = try lumaPlane(from: result)

        guard res.width >= src.width, res.height >= src.height else {
            throw GuardError.resultSmallerThanSource
        }

        // Reduce the result onto the source grid. When the two already match this is a no-op copy,
        // so a same-size restore degenerates to a direct comparison — still the right question.
        let reduced = areaResample(res.samples, res.width, res.height,
                                   toWidth: src.width, toHeight: src.height)

        let psnr = self.psnr(src.samples, reduced)
        let map = try ssimMap(src.samples, reduced, width: src.width, height: src.height,
                              includeLuminance: true)
        let tiles = tileStats(map, tileSize: tileSize)

        return DownsampleConsistency(
            scaleX: Double(res.width) / Double(src.width),
            scaleY: Double(res.height) / Double(src.height),
            psnr: psnr,
            ssim: map.mean,
            ssimTiles: tiles
        )
    }

    // MARK: - 2 · Per-octave SSIM

    public struct OctaveSSIM: Sendable, Equatable {
        /// One value per octave, `[0]` = finest. Contrast·structure SSIM over each Laplacian band.
        public let bands: [Double]
        /// The residual lowpass left under the finest `bands.count` octaves — full SSIM, since a
        /// lowpass image has a meaningful local mean.
        public let base: Double
        /// Per-tile contrast·structure SSIM of the **finest** band, for locating a change.
        public let finestBandTiles: TileMap

        /// How far each band sits below unchanged. **This, not the raw value, is the quantity with
        /// dynamic range** — see `hasExpectedSignature`.
        public var bandDeficits: [Double] { bands.map { 1.0 - $0 } }

        /// The shape check: legitimate denoise/sharpen changes the top octave and leaves the rest
        /// alone; a change that reaches mid and low frequencies is geometry drift or invention.
        ///
        /// 🔑 **This is deliberately a *relative* test, and that was a measured correction rather
        /// than a preference.** Contrast·structure SSIM on a Laplacian band is compressed hard
        /// against 1.0 — measured on a 1/f fixture, unsharp masking gives
        /// `[0.996, 0.998, 0.999, 1.000]` and a one-pixel translation gives
        /// `[0.986, 0.981, 0.981, 0.987]`. Those are only ~0.015 apart in absolute terms, so **any
        /// absolute tolerance either passes both or fails both** — an earlier draft of this
        /// predicate used one and cheerfully certified geometry drift as clean sharpening. The
        /// signal is entirely in the *shape*: sharpening's deficit collapses with depth, drift's
        /// does not. Comparing deficits recovers the full separation (0.25 vs 1.36 on the same two
        /// fixtures).
        ///
        /// - Parameter ratio: how large the deepest bands' deficit may be relative to the top
        ///   octave's. 0.5 cleanly separates the two cases above.
        /// - Returns: `true` when the change is confined to the top octaves.
        public func hasExpectedSignature(ratio: Double = 0.5) -> Bool {
            let deficits = bandDeficits
            guard deficits.count > 2 else { return true }
            let deep = deficits.dropFirst(2).max().map { Swift.max($0, 1.0 - base) } ?? (1.0 - base)
            // Nothing moved anywhere — an identical pair must not be judged on a ratio of noise.
            let top = deficits[0]
            if Swift.max(top, deep) < 1e-3 { return true }
            return deep <= ratio * top
        }
    }

    /// SSIM per octave. Both images must be the same size — resolution-changing pipelines should
    /// run `downsampleConsistency` instead, or pass the reduced result.
    ///
    /// 🔑 **The luminance term is dropped on the bands, deliberately.** SSIM factors as `l·c·s`, and
    /// a bandpass signal has a local mean of approximately zero — so `l` is both meaningless and
    /// numerically unstable there, and keeping it would swamp the structural signal this measure
    /// exists to isolate. Same reasoning V9's protocol uses to drop `l` when scoring relighting: the
    /// term fires on the intended effect rather than on the damage. The `base` level keeps `l`,
    /// because a lowpass image does have a meaningful mean.
    public static func perOctaveSSIM(reference: CGImage,
                                     distorted: CGImage,
                                     octaves: Int = 4,
                                     tileSize: Int = 128) throws -> OctaveSSIM {
        var a = try lumaPlane(from: reference)
        var b = try lumaPlane(from: distorted)

        // Tolerate a size difference by reducing the larger onto the smaller — the caller most
        // likely wants the octave view of an upscale, and silently comparing mismatched grids
        // would be worse than either throwing or reducing.
        if a.width != b.width || a.height != b.height {
            let w = min(a.width, b.width), h = min(a.height, b.height)
            a = Plane(samples: areaResample(a.samples, a.width, a.height, toWidth: w, toHeight: h),
                      width: w, height: h)
            b = Plane(samples: areaResample(b.samples, b.width, b.height, toWidth: w, toHeight: h),
                      width: w, height: h)
        }

        var bands: [Double] = []
        var finestTiles: TileMap?
        var currentA = a, currentB = b

        for _ in 0..<max(0, octaves) {
            // Stop before a level too small to carry a valid SSIM region.
            guard currentA.width >= minimumSide * 2, currentA.height >= minimumSide * 2 else { break }

            let nextA = downscaleBy2(currentA)
            let nextB = downscaleBy2(currentB)

            // Laplacian band = level − upsample(next level).
            let bandA = subtract(currentA.samples,
                                 upscale(nextA, toWidth: currentA.width, toHeight: currentA.height))
            let bandB = subtract(currentB.samples,
                                 upscale(nextB, toWidth: currentB.width, toHeight: currentB.height))

            let map = try ssimMap(bandA, bandB, width: currentA.width, height: currentA.height,
                                  includeLuminance: false)
            bands.append(map.mean)
            if finestTiles == nil { finestTiles = tileStats(map, tileSize: tileSize) }

            currentA = nextA
            currentB = nextB
        }

        let baseMap = try ssimMap(currentA.samples, currentB.samples,
                                  width: currentA.width, height: currentA.height,
                                  includeLuminance: true)

        return OctaveSSIM(
            bands: bands,
            base: baseMap.mean,
            finestBandTiles: finestTiles ?? TileMap(columns: 0, rows: 0, tileSize: tileSize, values: [])
        )
    }

    // MARK: - PSNR

    /// PSNR in dB over planes in [0, 1]. `.infinity` when the planes are identical — reported rather
    /// than clamped, so "bit-exact" stays distinguishable from "very good".
    static func psnr(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count)
        guard !a.isEmpty else { return .nan }
        var sum = 0.0
        for i in 0..<a.count {
            let d = Double(a[i] - b[i])
            sum += d * d
        }
        let mse = sum / Double(a.count)
        guard mse > 0 else { return .infinity }
        return 10 * log10(1.0 / mse)
    }

    // MARK: - SSIM

    /// The per-pixel SSIM map over the **valid** region — the border is cropped by the filter radius
    /// rather than edge-clamped into the statistics, which is the textbook treatment and keeps a
    /// frame's edge from dominating a tile score.
    struct SSIMMap {
        let values: [Float]
        let width: Int
        let height: Int
        /// Offset of the valid region within the original image, for tile addressing.
        let originX: Int
        let originY: Int

        var mean: Double {
            guard !values.isEmpty else { return .nan }
            var s = 0.0
            for v in values { s += Double(v) }
            return s / Double(values.count)
        }
    }

    /// Canonical Wang et al. SSIM: σ=1.5 Gaussian over an 11×11 window, C1=(0.01·L)², C2=(0.03·L)²
    /// with L=1 for planes in [0, 1].
    static let ssimSigma: Float = 1.5
    static let ssimRadius = 5              // 11×11, the canonical window
    static let ssimC1: Float = 0.0001      // (0.01 · 1.0)²
    static let ssimC2: Float = 0.0009      // (0.03 · 1.0)²
    static var minimumSide: Int { ssimRadius * 2 + 1 }

    static func ssimMap(_ a: [Float], _ b: [Float], width: Int, height: Int,
                        includeLuminance: Bool) throws -> SSIMMap {
        guard width >= minimumSide, height >= minimumSide else { throw GuardError.tooSmall }
        let kernel = gaussianKernel(sigma: ssimSigma, radius: ssimRadius)

        let mu1 = blur(a, width, height, kernel)
        let mu2 = blur(b, width, height, kernel)
        let s11 = blur(multiply(a, a), width, height, kernel)
        let s22 = blur(multiply(b, b), width, height, kernel)
        let s12 = blur(multiply(a, b), width, height, kernel)

        let vw = width - ssimRadius * 2
        let vh = height - ssimRadius * 2
        var out = [Float](repeating: 0, count: vw * vh)

        for y in 0..<vh {
            let srcRow = (y + ssimRadius) * width + ssimRadius
            let dstRow = y * vw
            for x in 0..<vw {
                let p = srcRow + x
                let m1 = mu1[p], m2 = mu2[p]
                let v1 = s11[p] - m1 * m1
                let v2 = s22[p] - m2 * m2
                let cov = s12[p] - m1 * m2
                let cs = (2 * cov + ssimC2) / (v1 + v2 + ssimC2)
                if includeLuminance {
                    let l = (2 * m1 * m2 + ssimC1) / (m1 * m1 + m2 * m2 + ssimC1)
                    out[dstRow + x] = l * cs
                } else {
                    out[dstRow + x] = cs
                }
            }
        }
        return SSIMMap(values: out, width: vw, height: vh, originX: ssimRadius, originY: ssimRadius)
    }

    // MARK: - Tiles

    /// Mean of the map within each tile. Partial edge tiles are kept and averaged over the pixels
    /// they actually contain — dropping them would blind the gate to a corner, which is precisely
    /// where a border artifact lands.
    static func tileStats(_ map: SSIMMap, tileSize: Int) -> TileMap {
        let size = max(8, tileSize)
        guard map.width > 0, map.height > 0 else {
            return TileMap(columns: 0, rows: 0, tileSize: size, values: [])
        }
        let columns = max(1, (map.width + size - 1) / size)
        let rows = max(1, (map.height + size - 1) / size)
        var values = [Double](repeating: .nan, count: columns * rows)

        for row in 0..<rows {
            let y0 = row * size, y1 = min(y0 + size, map.height)
            for column in 0..<columns {
                let x0 = column * size, x1 = min(x0 + size, map.width)
                var sum = 0.0
                var count = 0
                for y in y0..<y1 {
                    let base = y * map.width
                    for x in x0..<x1 { sum += Double(map.values[base + x]); count += 1 }
                }
                values[row * columns + column] = count > 0 ? sum / Double(count) : .nan
            }
        }
        return TileMap(columns: columns, rows: rows, tileSize: size, values: values)
    }

    // MARK: - Planes

    struct Plane {
        let samples: [Float]
        let width: Int
        let height: Int
    }

    /// Rasterize to sRGB bytes and take Rec.709 luma, **gamma-encoded — not linearized.**
    ///
    /// This is the same reasoning N1 gives for working on gamma-encoded luma: sensor noise is
    /// signal-dependent (σ² = a·Y + b), so in linear light one threshold is far too aggressive in
    /// shadows and too timid in highlights, while gamma encoding is approximately variance
    /// stabilizing. A perceptual guard wants the perceptually-uniform domain, and SSIM's constants
    /// are defined against display-referred values anyway.
    static func lumaPlane(from image: CGImage) throws -> Plane {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw GuardError.rasterFailed
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var out = [Float](repeating: 0, count: w * h)
        for p in 0..<(w * h) {
            let r = Float(rgba[p * 4 + 0])
            let g = Float(rgba[p * 4 + 1])
            let b = Float(rgba[p * 4 + 2])
            out[p] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
        }
        return Plane(samples: out, width: w, height: h)
    }

    // MARK: - Resampling

    /// Separable area (box) average to arbitrary dimensions, with fractional edge weights. Exact for
    /// integer ratios, correct for non-integer ones, and a no-op copy when the dimensions match.
    static func areaResample(_ src: [Float], _ sw: Int, _ sh: Int,
                             toWidth dw: Int, toHeight dh: Int) -> [Float] {
        precondition(dw > 0 && dh > 0 && sw > 0 && sh > 0)
        if sw == dw && sh == dh { return src }

        // Horizontal pass: sw × sh → dw × sh
        var horizontal = [Float](repeating: 0, count: dw * sh)
        let xRatio = Double(sw) / Double(dw)
        for x in 0..<dw {
            let x0 = Double(x) * xRatio
            let x1 = Double(x + 1) * xRatio
            let first = Int(x0), last = min(sw - 1, Int(x1.nextDown))
            for y in 0..<sh {
                var sum = 0.0, weight = 0.0
                let row = y * sw
                for sx in first...last {
                    let w = min(Double(sx + 1), x1) - max(Double(sx), x0)
                    guard w > 0 else { continue }
                    sum += Double(src[row + sx]) * w
                    weight += w
                }
                horizontal[y * dw + x] = weight > 0 ? Float(sum / weight) : src[row + first]
            }
        }

        // Vertical pass: dw × sh → dw × dh
        var out = [Float](repeating: 0, count: dw * dh)
        let yRatio = Double(sh) / Double(dh)
        for y in 0..<dh {
            let y0 = Double(y) * yRatio
            let y1 = Double(y + 1) * yRatio
            let first = Int(y0), last = min(sh - 1, Int(y1.nextDown))
            for x in 0..<dw {
                var sum = 0.0, weight = 0.0
                for sy in first...last {
                    let w = min(Double(sy + 1), y1) - max(Double(sy), y0)
                    guard w > 0 else { continue }
                    sum += Double(horizontal[sy * dw + x]) * w
                    weight += w
                }
                out[y * dw + x] = weight > 0 ? Float(sum / weight) : horizontal[first * dw + x]
            }
        }
        return out
    }

    /// 2×2 box average with edge clamp — the pyramid reduction. Matches `SSIMULACRA2`'s own.
    static func downscaleBy2(_ plane: Plane) -> Plane {
        let w = plane.width, h = plane.height
        let ow = (w + 1) / 2, oh = (h + 1) / 2
        var out = [Float](repeating: 0, count: ow * oh)
        for oy in 0..<oh {
            for ox in 0..<ow {
                var sum: Float = 0
                for iy in 0..<2 {
                    let y = min(oy * 2 + iy, h - 1)
                    for ix in 0..<2 {
                        let x = min(ox * 2 + ix, w - 1)
                        sum += plane.samples[y * w + x]
                    }
                }
                out[oy * ow + ox] = sum * 0.25
            }
        }
        return Plane(samples: out, width: ow, height: oh)
    }

    /// Bilinear expansion back to a parent level's dimensions — the pyramid's expand step.
    static func upscale(_ plane: Plane, toWidth dw: Int, toHeight dh: Int) -> [Float] {
        let sw = plane.width, sh = plane.height
        var out = [Float](repeating: 0, count: dw * dh)
        let xScale = Double(sw) / Double(dw)
        let yScale = Double(sh) / Double(dh)
        for y in 0..<dh {
            let fy = max(0, (Double(y) + 0.5) * yScale - 0.5)
            let y0 = min(sh - 1, Int(fy)), y1 = min(sh - 1, y0 + 1)
            let wy = Float(fy - Double(y0))
            for x in 0..<dw {
                let fx = max(0, (Double(x) + 0.5) * xScale - 0.5)
                let x0 = min(sw - 1, Int(fx)), x1 = min(sw - 1, x0 + 1)
                let wx = Float(fx - Double(x0))
                let top = plane.samples[y0 * sw + x0] * (1 - wx) + plane.samples[y0 * sw + x1] * wx
                let bottom = plane.samples[y1 * sw + x0] * (1 - wx) + plane.samples[y1 * sw + x1] * wx
                out[y * dw + x] = top * (1 - wy) + bottom * wy
            }
        }
        return out
    }

    // MARK: - Small ops

    static func multiply(_ a: [Float], _ b: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { out[i] = a[i] * b[i] }
        return out
    }

    static func subtract(_ a: [Float], _ b: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { out[i] = a[i] - b[i] }
        return out
    }

    static func gaussianKernel(sigma: Float, radius: Int) -> [Float] {
        var k = [Float](); k.reserveCapacity(radius * 2 + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let v = expf(-Float(i * i) / (2 * sigma * sigma))
            k.append(v); sum += v
        }
        return k.map { $0 / sum }
    }

    /// Separable FIR blur with edge clamp — same shape as `SSIMULACRA2.blur`, kept local because
    /// that one is private and this target has no cross-file internal blur seam.
    static func blur(_ src: [Float], _ w: Int, _ h: Int, _ kernel: [Float]) -> [Float] {
        let r = kernel.count / 2
        var tmp = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                var acc: Float = 0
                for k in -r...r { acc += src[row + min(max(x + k, 0), w - 1)] * kernel[k + r] }
                tmp[row + x] = acc
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var acc: Float = 0
                for k in -r...r { acc += tmp[min(max(y + k, 0), h - 1) * w + x] * kernel[k + r] }
                out[y * w + x] = acc
            }
        }
        return out
    }
}
