//
// SSIMULACRA2.swift — MediaMeasure
//
// Pure-Swift port of the SSIMULACRA2 perceptual image-quality metric (F1 — removes the libjxl
// `ssimulacra2` binary dependency). Faithful reimplementation of the reference algorithm:
// sRGB→linear→XYB (libjxl opsin), 6-scale multi-scale SSIM + edge-difference maps over a σ=1.5
// Gaussian blur, 1-norm + 4-norm reductions, a trained 108-weight linear combination, and the final
// polynomial → score in (-∞, 100]. 100 = identical.
//
// Ported from the SSIMULACRA2 reference (Cloudinary / libjxl, BSD-3-Clause) and the rust-av port
// (rust-av/ssimulacra2). Constants are taken verbatim from those sources. The reference uses a
// recursive (IIR) Gaussian; this port uses a true FIR Gaussian at the same σ=1.5 — within a small
// fraction of a point of the reference (validated against the libjxl binary).
//

import CoreGraphics
import Foundation

public enum SSIMULACRA2 {

    public enum ScoreError: Error { case tooSmall, dimensionMismatch, rasterFailed }

    /// SSIMULACRA2 score for `distorted` vs `reference` (must be same dimensions, ≥ 8×8). 100 = identical.
    public static func score(reference: CGImage, distorted: CGImage) throws -> Double {
        guard reference.width == distorted.width, reference.height == distorted.height else {
            throw ScoreError.dimensionMismatch
        }
        guard reference.width >= 8, reference.height >= 8 else { throw ScoreError.tooSmall }
        return try multiScale(reference: reference, distorted: distorted, kernel: gaussianKernel(sigma: 1.5))
    }

    private struct Scale {
        var avgSsim = [Double](repeating: 0, count: 6)    // [c*2 + n]
        var avgEdge = [Double](repeating: 0, count: 12)   // [c*4 + k]
    }

    private static func multiScale(reference: CGImage, distorted: CGImage,
                                   kernel: [Float]) throws -> Double {
        var p1 = try linearRGB(from: reference)
        var p2 = try linearRGB(from: distorted)
        var w = reference.width, h = reference.height
        var scales: [Scale] = []

        for scale in 0..<6 {
            if w < 8 || h < 8 { break }
            if scale > 0 {
                let d1 = downscaleBy2(p1.0, p1.1, p1.2, w, h)
                let d2 = downscaleBy2(p2.0, p2.1, p2.2, w, h)
                p1 = (d1.0, d1.1, d1.2); p2 = (d2.0, d2.1, d2.2)
                w = d1.3; h = d1.4
                if w < 8 || h < 8 { break }
            }
            // linear RGB → positive XYB planes
            let x1 = toPositiveXYB(p1.0, p1.1, p1.2, count: w * h)
            let x2 = toPositiveXYB(p2.0, p2.1, p2.2, count: w * h)

            var s = Scale()
            for c in 0..<3 {
                let i1 = x1[c], i2 = x2[c]
                let mu1 = blur(i1, w, h, kernel)
                let mu2 = blur(i2, w, h, kernel)
                let s11 = blur(mul(i1, i1), w, h, kernel)
                let s22 = blur(mul(i2, i2), w, h, kernel)
                let s12 = blur(mul(i1, i2), w, h, kernel)

                // SSIM map.
                let n = w * h
                var sumD = 0.0, sumD4 = 0.0
                for p in 0..<n {
                    let m1 = mu1[p], m2 = mu2[p]
                    let muDiff = m1 - m2
                    let numM = 1.0 - Double(muDiff * muDiff)
                    let numS = 2.0 * Double(s12[p] - m1 * m2) + C2
                    let denomS = Double((s11[p] - m1 * m1) + (s22[p] - m2 * m2)) + C2
                    var d = 1.0 - (numM * numS) / denomS
                    d = max(d, 0.0)
                    sumD += d
                    sumD4 += d * d * d * d
                }
                s.avgSsim[c * 2 + 0] = sumD / Double(n)
                s.avgSsim[c * 2 + 1] = (sumD4 / Double(n)).squareRoot().squareRoot()

                // Edge-difference map.
                var aSum = 0.0, a4 = 0.0, dSum = 0.0, d4 = 0.0
                for p in 0..<n {
                    let d1 = (1.0 + Double(abs(i2[p] - mu2[p]))) /
                             (1.0 + Double(abs(i1[p] - mu1[p]))) - 1.0
                    let artifact = max(d1, 0.0)
                    let detail = max(-d1, 0.0)
                    aSum += artifact; a4 += artifact * artifact * artifact * artifact
                    dSum += detail;   d4 += detail * detail * detail * detail
                }
                s.avgEdge[c * 4 + 0] = aSum / Double(n)
                s.avgEdge[c * 4 + 1] = (a4 / Double(n)).squareRoot().squareRoot()
                s.avgEdge[c * 4 + 2] = dSum / Double(n)
                s.avgEdge[c * 4 + 3] = (d4 / Double(n)).squareRoot().squareRoot()
            }
            scales.append(s)
        }

        return finalScore(scales)
    }

    private static func finalScore(_ scales: [Scale]) -> Double {
        var ssim = 0.0
        var i = 0
        for c in 0..<3 {
            for s in scales {
                for n in 0..<2 {
                    ssim += weights[i] * abs(s.avgSsim[c * 2 + n]); i += 1
                    ssim += weights[i] * abs(s.avgEdge[c * 4 + n]); i += 1
                    ssim += weights[i] * abs(s.avgEdge[c * 4 + n + 2]); i += 1
                }
            }
        }
        ssim *= 0.9562382616834844
        ssim = 6.248496625763138e-5 * ssim * ssim * ssim
             + 2.326765642916932 * ssim
             - 0.020884521182843837 * ssim * ssim
        if ssim > 0 {
            return pow(ssim, 0.6276336467831387) * -10.0 + 100.0
        }
        return 100.0
    }

    // MARK: - Trained weights (verbatim from the reference; channel-major × 6 scales × [n,ssim/art/det])

    private static let weights: [Double] = [
        0.0, 0.0007376606707406586, 0.0, 0.0, 0.0007793481682867309, 0.0,
        0.0, 0.0004371155730107379, 0.0, 1.1041726426657346,
        0.00066284834129271, 0.00015231632783718752, 0.0, 0.0016406437456599754, 0.0,
        1.8422455520539298, 11.441172603757666, 0.0, 0.0007989109436015163,
        0.000176816438078653, 0.0, 1.8787594979546387, 10.94906990605142, 0.0,
        0.0007289346991508072, 0.9677937080626833, 0.0, 0.00014003424285435884,
        0.9981766977854967, 0.0003194975593443505, 0.0004550992113792063, 0.0, 0.0,
        0.0013648766163243398, 0.0, 0.0, 0.0, 0.0, 0.0, 7.466890328078848, 0.0,
        17.445833984131262, 0.0006235601634041466, 0.0, 0.0, 6.683678146179332,
        0.0003772440797961129, 1.027889937768264, 225.20515300849274, 0.0, 0.0,
        19.213238186143016, 0.0011401524586618361, 0.001237755635509985, 176.39317598450694,
        0.0, 0.0, 24.43300999870476, 0.28520802612117757, 0.0004485436923833408, 0.0, 0.0, 0.0,
        34.77906344483772, 44.835625328877896, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        0.0008680556573291698, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0005313191874358747, 0.0,
        0.00016533814161379112, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0004179171803251336,
        0.0017290828234722833, 0.0, 0.0020827005846636437, 0.0, 0.0, 8.826982764996862,
        23.19243343998926, 0.0, 95.1080498811086, 0.9863978034400682, 0.9834382792465353,
        0.0012286405048278493, 171.2667255897307, 0.9807858872435379, 0.0, 0.0, 0.0,
        0.0005130064588990679, 0.0, 0.00010854057858411537,
    ]

    // MARK: - XYB

    private static let kB0: Float = 0.0037930732552754493
    private static let cbrtBias: Float = cbrtf(0.0037930732552754493)
    private static let C2 = 0.0009

    /// linear RGB planes → 3 positive-XYB planes (X, Y, B), each `count` long.
    private static func toPositiveXYB(_ r: [Float], _ g: [Float], _ b: [Float],
                                      count: Int) -> [[Float]] {
        var X = [Float](repeating: 0, count: count)
        var Y = [Float](repeating: 0, count: count)
        var B = [Float](repeating: 0, count: count)
        for p in 0..<count {
            let rr = r[p], gg = g[p], bb = b[p]
            var m0 = 0.30 * rr + 0.622 * gg + 0.078 * bb + kB0
            var m1 = 0.23 * rr + 0.692 * gg + 0.078 * bb + kB0
            var m2 = 0.24342268924547819 * rr + 0.20476744424496821 * gg
                   + 0.5518098657995536 * bb + kB0
            m0 = cbrtf(m0) - cbrtBias
            m1 = cbrtf(m1) - cbrtBias
            m2 = cbrtf(m2) - cbrtBias
            var x = 0.5 * (m0 - m1)
            var y = 0.5 * (m0 + m1)
            var z = m2
            // make_positive_xyb
            z = (z - y) + 0.55
            x = x * 14.0 + 0.42
            y = y + 0.01
            X[p] = x; Y[p] = y; B[p] = z
        }
        return [X, Y, B]
    }

    // MARK: - Pixel I/O

    /// Rasterize a CGImage to sRGB bytes, then to linear-RGB float planes.
    private static func linearRGB(from image: CGImage) throws -> ([Float], [Float], [Float]) {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ScoreError.rasterFailed
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var r = [Float](repeating: 0, count: w * h)
        var g = [Float](repeating: 0, count: w * h)
        var b = [Float](repeating: 0, count: w * h)
        for p in 0..<(w * h) {
            r[p] = srgbToLinear(Float(rgba[p * 4 + 0]) / 255.0)
            g[p] = srgbToLinear(Float(rgba[p * 4 + 1]) / 255.0)
            b[p] = srgbToLinear(Float(rgba[p * 4 + 2]) / 255.0)
        }
        return (r, g, b)
    }

    @inline(__always)
    private static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    // MARK: - Image ops

    private static func mul(_ a: [Float], _ b: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { out[i] = a[i] * b[i] }
        return out
    }

    /// 2×2 box average with edge clamp; output dims ceil(w/2) × ceil(h/2).
    private static func downscaleBy2(_ r: [Float], _ g: [Float], _ b: [Float], _ w: Int, _ h: Int)
        -> ([Float], [Float], [Float], Int, Int) {
        let ow = (w + 1) / 2, oh = (h + 1) / 2
        var or_ = [Float](repeating: 0, count: ow * oh)
        var og = [Float](repeating: 0, count: ow * oh)
        var ob = [Float](repeating: 0, count: ow * oh)
        for oy in 0..<oh {
            for ox in 0..<ow {
                var sr: Float = 0, sg: Float = 0, sb: Float = 0
                for iy in 0..<2 {
                    for ix in 0..<2 {
                        let x = min(ox * 2 + ix, w - 1)
                        let y = min(oy * 2 + iy, h - 1)
                        let s = y * w + x
                        sr += r[s]; sg += g[s]; sb += b[s]
                    }
                }
                let o = oy * ow + ox
                or_[o] = sr * 0.25; og[o] = sg * 0.25; ob[o] = sb * 0.25
            }
        }
        return (or_, og, ob, ow, oh)
    }

    // MARK: - Gaussian blur (FIR, σ=1.5, separable, edge-clamp)

    private static func gaussianKernel(sigma: Float) -> [Float] {
        let radius = Int(ceilf(sigma * 4))
        var k = [Float](); k.reserveCapacity(radius * 2 + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let v = expf(-Float(i * i) / (2 * sigma * sigma))
            k.append(v); sum += v
        }
        return k.map { $0 / sum }
    }

    private static func blur(_ src: [Float], _ w: Int, _ h: Int, _ kernel: [Float]) -> [Float] {
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
