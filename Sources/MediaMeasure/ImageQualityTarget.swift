//
// ImageQualityTarget.swift — MediaMeasure
//
// Quality-targeted still encode: find the smallest HEIC that still meets a target SSIMULACRA2 score.
// Each search step encodes the image at a candidate quality, decodes it back, and scores it against
// the original — so the search optimizes the *real* perceptual result, not a proxy. Pure-Swift
// (ImageIO + the SSIMULACRA2 port); no external binaries.
//

import CoreGraphics
import Foundation
import ImageIO
import MediaMetrics
import UniformTypeIdentifiers

public enum ImageQualityTarget {

    public struct Result: Sendable {
        public let data: Data           // the encoded HEIC at the chosen quality
        public let quality: Double      // ImageIO lossy-compression-quality used
        public let score: Double        // achieved SSIMULACRA2 vs the original
        public let metTarget: Bool
    }

    /// The result of the lossless web-still encode. No `quality`/`metTarget`: PNG has no lossy knob,
    /// so there is no search and no floor to meet — only the measured round-trip score.
    public struct PNGResult: Sendable {
        public let data: Data           // the encoded PNG
        public let score: Double        // measured SSIMULACRA2 of the decode round-trip vs the input
    }

    /// The lossless result shape is the same whichever encoder produced it.
    public typealias LosslessResult = PNGResult

    public enum EncodeError: Error { case encodeFailed, decodeFailed }

    /// Which SSIMULACRA2 implementation scores the search — stated, rather than inferred from
    /// whether `channelScalars` happens to be non-nil.
    ///
    /// The legacy `channelScalars:` parameter conflates two different requests. Every in-tree
    /// caller passes `SSIMULACRA2Metal.shared?.channelScalarsFunction` purely to *mean* "use the
    /// GPU", and the resident whole-score path (one sync per score vs the per-channel path's 18)
    /// serves that intent far better than the closure they handed over — so the closure was
    /// discarded. That is right for them and wrong for anyone injecting a backend they actually
    /// need honored: a pinned `MTLDevice`, a CPU implementation for parity work, an A/B harness.
    /// Naming the choice separates the two.
    public enum ScoringBackend: Sendable {
        /// Pure-Swift `SSIMULACRA2.score`. Honored exactly — never silently upgraded to the GPU.
        case cpu
        /// `SSIMULACRA2Metal.shared`'s resident whole-score path, falling back to CPU when no
        /// Metal device is present or `MEDIAMEASURE_NO_RESIDENT` is set.
        case residentGPU
        /// The caller's own per-channel implementation. Honored **exactly** — this is the case the
        /// legacy parameter could not express.
        case injected(SSIMULACRA2.ChannelScalars)
    }

    /// Encode `image` as HEIC at the lowest quality whose decoded result scores ≥ `targetScore`.
    /// The search calls SSIMULACRA2 up to `iterations` times, so the scoring backend dominates.
    ///
    /// Pass `backend:` to say which one — `.residentGPU` for the fast path, `.cpu` for pure Swift,
    /// `.injected(fn)` to have your own implementation honored exactly. When `backend` is nil the
    /// deprecated `channelScalars:` is interpreted exactly as it always has been (non-nil ⇒ prefer
    /// the resident GPU path, discarding the closure; nil ⇒ CPU), so existing callers are
    /// bit-for-bit unchanged.
    public static func encodeHEIC(_ image: CGImage, targetScore: Double,
                                  iterations: Int = 8,
                                  channelScalars: SSIMULACRA2.ChannelScalars? = nil,
                                  backend: ScoringBackend? = nil) throws -> Result {
        let mm = MediaMetrics.begin("iqt.search", lane: "orchestrate",
                                    attrs: ["codec": "heic", "target": "\(targetScore)",
                                            "w": "\(image.width)", "h": "\(image.height)"])
        defer { MediaMetrics.end(mm) }
        var bestData: Data?
        let search = try QualityTargetSearch.search(target: targetScore, lo: 0.1, hi: 1.0,
                                                    iterations: iterations) { q in
            let data = try MediaMetrics.time("iqt.encode", lane: "encode", detail: 1,
                                             attrs: ["codec": "heic", "q": String(format: "%.3f", q)]) {
                try encode(image, quality: q)
            }
            let decoded = try MediaMetrics.time("iqt.decode", lane: "decode", detail: 1,
                                                attrs: ["codec": "heic"]) { try decode(data) }
            let score: Double = try MediaMetrics.time("iqt.score", lane: "score", detail: 1) {
                // `Self.` is load-bearing: the `let score` above is in scope inside its own
                // initializer, so a bare `score(...)` binds to that Double and fails to compile
                // on the stable toolchain (Xcode 26.6). Qualified, it resolves to the static func.
                try Self.score(reference: image, distorted: decoded,
                               channelScalars: channelScalars, backend: backend)
            }
            bestData = data        // last evaluated; the search ends on the chosen knob
            return score
        }
        // Re-encode at the chosen quality so `data` matches the returned `quality` exactly.
        let data = try MediaMetrics.time("iqt.finalEncode", lane: "encode", detail: 1,
                                         attrs: ["codec": "heic"]) {
            try encode(image, quality: search.quality)
        }
        _ = bestData
        return Result(data: data, quality: search.quality, score: search.score,
                      metTarget: search.metTarget)
    }

    /// Async entry point: identical to the sync `encodeHEIC` but runs the CPU-bound search **off the
    /// cooperative pool** at `.utility` QoS, so a `.userInitiated` caller doesn't invert against
    /// CoreGraphics's Default-QoS rasterization (EMBED-004). Prefer this from async contexts.
    public static func encodeHEIC(_ image: CGImage, targetScore: Double,
                                  iterations: Int = 8,
                                  channelScalars: SSIMULACRA2.ChannelScalars? = nil,
                                  backend: ScoringBackend? = nil) async throws -> Result {
        try await ScoringExecutor.run {
            try encodeHEIC(image, targetScore: targetScore, iterations: iterations,
                           channelScalars: channelScalars, backend: backend)
        }
    }

    // MARK: - Any encoder (the external still-encoder seam's search)

    /// The floor search over ANY lossy still encoder — `encodeHEIC` / `encodeJPEG` with the encode
    /// step injected. This is what an `ExternalStillEncoder` (the `MediaImport` seam; WebP via
    /// `webp-swift`) plugs into: hand over `encoder(image, knob)` and get back the same search law,
    /// the same decode-and-score-the-real-bytes rule and the same `MediaMetrics` spans the built-in
    /// formats get. `codec` names the lane in those spans.
    ///
    /// `knob` runs over [`lo`, `hi`] — the encoder's quality scale normalised to [0, 1] (libwebp's
    /// 0…100 becomes `knob × 100`), and it MUST stay lossy over the whole range: a top candidate that
    /// silently switched into a lossless mode would have the search comparing two encoders. Decode is
    /// ImageIO, so the bytes handed back must be something the platform reads — which is the point.
    ///
    /// Scoring backend: see `encodeHEIC`.
    public static func encode(_ image: CGImage, targetScore: Double,
                              iterations: Int = 8, lo: Double = 0.1, hi: Double = 1.0,
                              codec: String,
                              channelScalars: SSIMULACRA2.ChannelScalars? = nil,
                              backend: ScoringBackend? = nil,
                              encoder: (CGImage, Double) throws -> Data) throws -> Result {
        let mm = MediaMetrics.begin("iqt.search", lane: "orchestrate",
                                    attrs: ["codec": codec, "target": "\(targetScore)",
                                            "w": "\(image.width)", "h": "\(image.height)"])
        defer { MediaMetrics.end(mm) }
        let search = try QualityTargetSearch.search(target: targetScore, lo: lo, hi: hi,
                                                    iterations: iterations) { q in
            let data = try MediaMetrics.time("iqt.encode", lane: "encode", detail: 1,
                                             attrs: ["codec": codec, "q": String(format: "%.3f", q)]) {
                try encoder(image, q)
            }
            let decoded = try MediaMetrics.time("iqt.decode", lane: "decode", detail: 1,
                                                attrs: ["codec": codec]) { try decode(data) }
            return try MediaMetrics.time("iqt.score", lane: "score", detail: 1) {
                try Self.score(reference: image, distorted: decoded,
                               channelScalars: channelScalars, backend: backend)
            }
        }
        // Re-encode at the chosen knob so `data` matches the returned `quality` exactly.
        let data = try MediaMetrics.time("iqt.finalEncode", lane: "encode", detail: 1,
                                         attrs: ["codec": codec]) {
            try encoder(image, search.quality)
        }
        return Result(data: data, quality: search.quality, score: search.score,
                      metTarget: search.metTarget)
    }

    /// Async entry point — off the cooperative pool at `.utility` QoS (EMBED-004), like `encodeHEIC`.
    public static func encode(_ image: CGImage, targetScore: Double,
                              iterations: Int = 8, lo: Double = 0.1, hi: Double = 1.0,
                              codec: String,
                              channelScalars: SSIMULACRA2.ChannelScalars? = nil,
                              backend: ScoringBackend? = nil,
                              encoder: @escaping @Sendable (CGImage, Double) throws -> Data) async throws -> Result {
        try await ScoringExecutor.run {
            try encode(image, targetScore: targetScore, iterations: iterations, lo: lo, hi: hi,
                       codec: codec, channelScalars: channelScalars, backend: backend,
                       encoder: encoder)
        }
    }

    /// The lossless counterpart for an external encoder (WebP's VP8L, say): one encode, and the score
    /// **measured on the decode round-trip, never asserted** from "lossless" — `encodePNG`'s rule.
    public static func encodeLossless(_ image: CGImage, codec: String,
                                      channelScalars: SSIMULACRA2.ChannelScalars? = nil,
                                      backend: ScoringBackend? = nil,
                                      encoder: (CGImage) throws -> Data) throws -> LosslessResult {
        let mm = MediaMetrics.begin("iqt.lossless", lane: "orchestrate",
                                    attrs: ["codec": codec, "w": "\(image.width)", "h": "\(image.height)"])
        defer { MediaMetrics.end(mm) }
        let data = try MediaMetrics.time("iqt.encode", lane: "encode", detail: 1,
                                         attrs: ["codec": codec]) { try encoder(image) }
        let decoded = try MediaMetrics.time("iqt.decode", lane: "decode", detail: 1,
                                            attrs: ["codec": codec]) { try decode(data) }
        let score: Double = try MediaMetrics.time("iqt.score", lane: "score", detail: 1) {
            try Self.score(reference: image, distorted: decoded,
                           channelScalars: channelScalars, backend: backend)
        }
        return LosslessResult(data: data, score: score)
    }

    /// Async entry point for `encodeLossless(_:codec:encoder:)`.
    public static func encodeLossless(_ image: CGImage, codec: String,
                                      channelScalars: SSIMULACRA2.ChannelScalars? = nil,
                                      backend: ScoringBackend? = nil,
                                      encoder: @escaping @Sendable (CGImage) throws -> Data) async throws -> LosslessResult {
        try await ScoringExecutor.run {
            try encodeLossless(image, codec: codec, channelScalars: channelScalars,
                               backend: backend, encoder: encoder)
        }
    }

    // MARK: - JPEG (lossy web still — the photo rung)

    /// Encode `image` as JPEG at the lowest quality whose decoded result scores ≥ `targetScore` —
    /// the same floor search as `encodeHEIC`, aimed at the one lossy still format every browser
    /// decodes. For photographic content this lands 5–10× under lossless PNG; for flat graphics
    /// JPEG rings and inflates, which is why the caller races it against PNG and ships the smaller
    /// deliverable that keeps its guarantee, rather than classifying up front. ⚠️ JPEG has no
    /// alpha — callers gate transparency to PNG before reaching for this.
    ///
    /// Scoring backend: see `encodeHEIC`. Prefer `backend:`; `channelScalars:` is the legacy
    /// spelling, kept for source compatibility and interpreted exactly as it always was.
    public static func encodeJPEG(_ image: CGImage, targetScore: Double,
                                  iterations: Int = 8,
                                  channelScalars: SSIMULACRA2.ChannelScalars? = nil,
                                  backend: ScoringBackend? = nil) throws -> Result {
        // The generic search with ImageIO's JPEG as the encode step — byte-identical to the
        // hand-written search it replaced: same knob range, same spans, same final re-encode.
        try encode(image, targetScore: targetScore, iterations: iterations, lo: 0.1, hi: 1.0,
                   codec: "jpeg", channelScalars: channelScalars, backend: backend) { img, q in
            try encode(img, quality: q, type: .jpeg)
        }
    }

    /// Async entry point — off the cooperative pool at `.utility` QoS (EMBED-004), like `encodeHEIC`.
    public static func encodeJPEG(_ image: CGImage, targetScore: Double,
                                  iterations: Int = 8,
                                  channelScalars: SSIMULACRA2.ChannelScalars? = nil,
                                  backend: ScoringBackend? = nil) async throws -> Result {
        try await ScoringExecutor.run {
            try encodeJPEG(image, targetScore: targetScore, iterations: iterations,
                           channelScalars: channelScalars, backend: backend)
        }
    }

    // MARK: - PNG (lossless web still)

    /// Encode `image` as PNG — the lossless, universally web-decodable still format. There is no
    /// quality search (PNG has no lossy knob); the strongest native lever is adaptive row filtering,
    /// which is enabled. The score is **measured on the decode round-trip, never asserted** from
    /// "PNG is lossless": a 16-bit, CMYK, or exotic-colorspace source passes through an 8-bit RGB(A)
    /// conversion where losslessness is not a given, and the receipt should say what actually happened.
    ///
    /// Scoring backend: see `encodeHEIC`. Prefer `backend:`; `channelScalars:` is the legacy
    /// spelling, kept for source compatibility and interpreted exactly as it always was.
    public static func encodePNG(_ image: CGImage,
                                 channelScalars: SSIMULACRA2.ChannelScalars? = nil,
                                 backend: ScoringBackend? = nil) throws -> PNGResult {
        let mm = MediaMetrics.begin("iqt.png", lane: "orchestrate",
                                    attrs: ["w": "\(image.width)", "h": "\(image.height)"])
        defer { MediaMetrics.end(mm) }
        let data = try MediaMetrics.time("iqt.encode", lane: "encode", detail: 1,
                                         attrs: ["codec": "png"]) { try encodePNGData(image) }
        let decoded = try MediaMetrics.time("iqt.decode", lane: "decode", detail: 1,
                                            attrs: ["codec": "png"]) { try decode(data) }
        let score: Double = try MediaMetrics.time("iqt.score", lane: "score", detail: 1) {
            // `Self.` is load-bearing — see the note in `encodeHEIC`.
            try Self.score(reference: image, distorted: decoded,
                           channelScalars: channelScalars, backend: backend)
        }
        return PNGResult(data: data, score: score)
    }

    /// Async entry point: runs the encode + round-trip score off the cooperative pool at `.utility`
    /// QoS (same EMBED-004 inversion guard as `encodeHEIC`). Prefer this from async contexts.
    public static func encodePNG(_ image: CGImage,
                                 channelScalars: SSIMULACRA2.ChannelScalars? = nil,
                                 backend: ScoringBackend? = nil) async throws -> PNGResult {
        try await ScoringExecutor.run {
            try encodePNG(image, channelScalars: channelScalars, backend: backend)
        }
    }

    static func encodePNGData(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { throw EncodeError.encodeFailed }
        // Adaptive (all-filters) row filtering, stated explicitly. Measured 2026-08-08 (macOS 27):
        // ImageIO's DEFAULT already produces byte-identical output — the hint is belt-and-braces
        // for older encoders, not a size lever. ImageIO exposes no deflate-level knob; the
        // vendored-oxipng recompression pass was dropped in the media-bridge salvage (net-clean),
        // and the accepted gap vs an oxipng-class pass is roughly 5–15%. If that ever matters, the
        // net-clean headroom is a pure-Swift IDAT recompression against the SYSTEM zlib (libz ships
        // with macOS — linking it is not vendoring) with per-scanline filter search.
        // The IMAGEIO_PNG_ALL_FILTERS compound macro doesn't import into Swift; OR the primitives.
        let allFilters = IMAGEIO_PNG_FILTER_NONE | IMAGEIO_PNG_FILTER_SUB | IMAGEIO_PNG_FILTER_UP
            | IMAGEIO_PNG_FILTER_AVG | IMAGEIO_PNG_FILTER_PAETH
        CGImageDestinationAddImage(dest, image, [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGCompressionFilter: allFilters,
            ],
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EncodeError.encodeFailed }
        return out as Data
    }

    /// Resolve the scoring backend for one comparison.
    ///
    /// An explicit `backend` always wins and is honored exactly — in particular `.injected(fn)`
    /// calls `fn`, and `.cpu` stays on the pure-Swift path even when a GPU is sitting right there.
    /// With no explicit backend we fall through to the legacy `channelScalars` reading, preserved
    /// verbatim so every existing caller is bit-for-bit unchanged: non-nil means "the caller wants
    /// the GPU", which the resident whole-score path serves better than the closure it handed over
    /// (one sync per score vs the per-channel path's 18), and nil means CPU.
    private static func score(reference: CGImage, distorted: CGImage,
                              channelScalars: SSIMULACRA2.ChannelScalars?,
                              backend: ScoringBackend?) throws -> Double {
        switch backend {
        case .cpu:
            return try SSIMULACRA2.score(reference: reference, distorted: distorted)
        case .residentGPU:
            if let gpu = SSIMULACRA2Metal.shared, gpu.residentAvailable {
                return try gpu.scoreResident(reference: reference, distorted: distorted)
            }
            return try SSIMULACRA2.score(reference: reference, distorted: distorted)
        case .injected(let fn):
            return try SSIMULACRA2.score(reference: reference, distorted: distorted,
                                         channelScalars: fn)
        case nil:
            break                                   // legacy reading, below
        }
        if channelScalars != nil, let gpu = SSIMULACRA2Metal.shared, gpu.residentAvailable {
            return try gpu.scoreResident(reference: reference, distorted: distorted)
        }
        if let channelScalars {
            return try SSIMULACRA2.score(reference: reference, distorted: distorted,
                                         channelScalars: channelScalars)
        }
        return try SSIMULACRA2.score(reference: reference, distorted: distorted)
    }

    // MARK: - ImageIO HEIC

    static func encode(_ image: CGImage, quality: Double, type: UTType = .heic) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, type.identifier as CFString, 1, nil) else { throw EncodeError.encodeFailed }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EncodeError.encodeFailed }
        return out as Data
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw EncodeError.decodeFailed
        }
        return img
    }
}
