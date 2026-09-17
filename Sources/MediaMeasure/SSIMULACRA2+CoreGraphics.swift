//
// SSIMULACRA2+CoreGraphics.swift — MediaMeasure
//
// The Apple half of the metric, split out of `SSIMULACRA2.swift` when the pure estimator moved to
// `MediaMeasureCore` (which builds for `wasm32-unknown-wasip1`). This file holds the two things the
// core cannot have: the CoreGraphics rasterization, and the `MediaMetrics` instrumentation.
//
// **Nothing about the numbers changed.** The rasterization below is the code that used to live in
// `SSIMULACRA2.linearRGB(from: CGImage)`, unmoved: same sRGB colour space, same `noneSkipLast`
// bitmap info, same `bytesPerRow == width * 4`. The bytes it produces are handed straight to the
// core, which applies the identical sRGB→linear conversion it always did. Every existing call site
// (`MediaMeasure.score`, `ImageQualityTarget`, `VideoQualityScore`, `TemporalDenoise`,
// `SSIMULACRA2Metal`) still calls `SSIMULACRA2.score(reference: CGImage, …)` and gets the same
// answer from the same arithmetic.
//
// The spans are preserved too: the `ssimu2` span still covers rasterize + score (it always did,
// because `linearRGB` ran inside `multiScale`), and the detail-2 `ssimu2.ingest` / `ssimu2.channel`
// spans are re-injected into the core through its `SpanHook`.
//

import CoreGraphics
import Foundation
import MediaMetrics

public extension RGBA8Image {

    /// Rasterize a `CGImage` into tightly-packed sRGB RGBA bytes — the exact rasterization the
    /// metric has always done internally. Returns nil when `CGContext` creation fails (the old
    /// `ScoreError.rasterFailed` path).
    init?(cgImage image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let made: Bool = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard made else { return nil }
        self.init(width: w, height: h, pixels: rgba)
    }
}

public extension SSIMULACRA2 {

    /// The MediaMetrics-backed span hook handed to the core, so the detail-2 timeline is unbroken.
    static var metricsSpanHook: SpanHook {
        { name, lane, detail, attrs in
            let h = MediaMetrics.begin(name, lane: lane, detail: detail, attrs: attrs)
            return { MediaMetrics.end(h) }
        }
    }

    /// SSIMULACRA2 score for `distorted` vs `reference` (same dimensions, ≥ 8×8). 100 = identical.
    static func score(reference: CGImage, distorted: CGImage) throws -> Double {
        try score(reference: reference, distorted: distorted,
                  channelScalars: defaultChannelScalars)
    }

    /// Score with an injected **blur** backend (GPU blur, CPU maps).
    static func score(reference: CGImage, distorted: CGImage,
                      blur: @escaping BlurFunction) throws -> Double {
        try score(reference: reference, distorted: distorted,
                  channelScalars: cpuChannelScalars(blur: blur))
    }

    /// Score with a fully-injected **per-channel** backend (e.g. all-GPU).
    static func score(reference: CGImage, distorted: CGImage,
                      channelScalars: ChannelScalars) throws -> Double {
        guard reference.width == distorted.width, reference.height == distorted.height else {
            throw ScoreError.dimensionMismatch
        }
        guard reference.width >= 8, reference.height >= 8 else { throw ScoreError.tooSmall }
        return try MediaMetrics.time("ssimu2", lane: "score", detail: 1,
                                     attrs: ["w": "\(reference.width)", "h": "\(reference.height)"]) {
            guard let r = RGBA8Image(cgImage: reference),
                  let d = RGBA8Image(cgImage: distorted) else { throw ScoreError.rasterFailed }
            return try score(reference: r, distorted: d, channelScalars: channelScalars,
                             span: metricsSpanHook)
        }
    }
}
