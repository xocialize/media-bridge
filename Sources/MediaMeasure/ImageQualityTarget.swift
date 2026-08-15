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

    public enum EncodeError: Error { case encodeFailed, decodeFailed }

    /// Encode `image` as HEIC at the lowest quality whose decoded result scores ≥ `targetScore`.
    /// `channelScalars` injects SSIMULACRA2's per-channel hot path (e.g.
    /// `SSIMULACRA2Metal.shared?.channelScalarsFunction` = all-GPU) — the search calls SSIMULACRA2 up to
    /// `iterations` times, so a GPU backend cuts the encode time multiple-fold while keeping the achieved
    /// score within fp tolerance of the CPU path. `nil` = pure-Swift.
    public static func encodeHEIC(_ image: CGImage, targetScore: Double,
                                  iterations: Int = 8,
                                  channelScalars: SSIMULACRA2.ChannelScalars? = nil) throws -> Result {
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
                try gpuOrInjected(reference: image, distorted: decoded, channelScalars: channelScalars)
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
                                  channelScalars: SSIMULACRA2.ChannelScalars? = nil) async throws -> Result {
        try await ScoringExecutor.run {
            try encodeHEIC(image, targetScore: targetScore, iterations: iterations,
                           channelScalars: channelScalars)
        }
    }

    // MARK: - JPEG (lossy web still — the photo rung)

    /// Encode `image` as JPEG at the lowest quality whose decoded result scores ≥ `targetScore` —
    /// the same floor search as `encodeHEIC`, aimed at the one lossy still format every browser
    /// decodes. For photographic content this lands 5–10× under lossless PNG; for flat graphics
    /// JPEG rings and inflates, which is why the caller races it against PNG and ships the smaller
    /// deliverable that keeps its guarantee, rather than classifying up front. ⚠️ JPEG has no
    /// alpha — callers gate transparency to PNG before reaching for this.
    public static func encodeJPEG(_ image: CGImage, targetScore: Double,
                                  iterations: Int = 8,
                                  channelScalars: SSIMULACRA2.ChannelScalars? = nil) throws -> Result {
        let mm = MediaMetrics.begin("iqt.search", lane: "orchestrate",
                                    attrs: ["codec": "jpeg", "target": "\(targetScore)",
                                            "w": "\(image.width)", "h": "\(image.height)"])
        defer { MediaMetrics.end(mm) }
        let search = try QualityTargetSearch.search(target: targetScore, lo: 0.1, hi: 1.0,
                                                    iterations: iterations) { q in
            let data = try MediaMetrics.time("iqt.encode", lane: "encode", detail: 1,
                                             attrs: ["codec": "jpeg", "q": String(format: "%.3f", q)]) {
                try encode(image, quality: q, type: .jpeg)
            }
            let decoded = try MediaMetrics.time("iqt.decode", lane: "decode", detail: 1,
                                                attrs: ["codec": "jpeg"]) { try decode(data) }
            return try MediaMetrics.time("iqt.score", lane: "score", detail: 1) {
                try gpuOrInjected(reference: image, distorted: decoded, channelScalars: channelScalars)
            }
        }
        let data = try MediaMetrics.time("iqt.finalEncode", lane: "encode", detail: 1,
                                         attrs: ["codec": "jpeg"]) {
            try encode(image, quality: search.quality, type: .jpeg)
        }
        return Result(data: data, quality: search.quality, score: search.score,
                      metTarget: search.metTarget)
    }

    /// Async entry point — off the cooperative pool at `.utility` QoS (EMBED-004), like `encodeHEIC`.
    public static func encodeJPEG(_ image: CGImage, targetScore: Double,
                                  iterations: Int = 8,
                                  channelScalars: SSIMULACRA2.ChannelScalars? = nil) async throws -> Result {
        try await ScoringExecutor.run {
            try encodeJPEG(image, targetScore: targetScore, iterations: iterations,
                           channelScalars: channelScalars)
        }
    }

    // MARK: - PNG (lossless web still)

    /// Encode `image` as PNG — the lossless, universally web-decodable still format. There is no
    /// quality search (PNG has no lossy knob); the strongest native lever is adaptive row filtering,
    /// which is enabled. The score is **measured on the decode round-trip, never asserted** from
    /// "PNG is lossless": a 16-bit, CMYK, or exotic-colorspace source passes through an 8-bit RGB(A)
    /// conversion where losslessness is not a given, and the receipt should say what actually happened.
    public static func encodePNG(_ image: CGImage,
                                 channelScalars: SSIMULACRA2.ChannelScalars? = nil) throws -> PNGResult {
        let mm = MediaMetrics.begin("iqt.png", lane: "orchestrate",
                                    attrs: ["w": "\(image.width)", "h": "\(image.height)"])
        defer { MediaMetrics.end(mm) }
        let data = try MediaMetrics.time("iqt.encode", lane: "encode", detail: 1,
                                         attrs: ["codec": "png"]) { try encodePNGData(image) }
        let decoded = try MediaMetrics.time("iqt.decode", lane: "decode", detail: 1,
                                            attrs: ["codec": "png"]) { try decode(data) }
        let score: Double = try MediaMetrics.time("iqt.score", lane: "score", detail: 1) {
            try gpuOrInjected(reference: image, distorted: decoded, channelScalars: channelScalars)
        }
        return PNGResult(data: data, score: score)
    }

    /// Async entry point: runs the encode + round-trip score off the cooperative pool at `.utility`
    /// QoS (same EMBED-004 inversion guard as `encodeHEIC`). Prefer this from async contexts.
    public static func encodePNG(_ image: CGImage,
                                 channelScalars: SSIMULACRA2.ChannelScalars? = nil) async throws -> PNGResult {
        try await ScoringExecutor.run {
            try encodePNG(image, channelScalars: channelScalars)
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

    /// A non-nil `channelScalars` is the caller saying "use the GPU" — honor that intent with the
    /// resident whole-score path when it's available (one sync per score vs V1's 18); a nil stays
    /// pure-CPU (the explicit-backend and parity paths are untouched).
    private static func gpuOrInjected(reference: CGImage, distorted: CGImage,
                                      channelScalars: SSIMULACRA2.ChannelScalars?) throws -> Double {
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
