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
        var bestData: Data?
        let search = try QualityTargetSearch.search(target: targetScore, lo: 0.1, hi: 1.0,
                                                    iterations: iterations) { q in
            let data = try encode(image, quality: q)
            let decoded = try decode(data)
            let score: Double
            if let channelScalars {
                score = try SSIMULACRA2.score(reference: image, distorted: decoded, channelScalars: channelScalars)
            } else {
                score = try SSIMULACRA2.score(reference: image, distorted: decoded)
            }
            bestData = data        // last evaluated; the search ends on the chosen knob
            return score
        }
        // Re-encode at the chosen quality so `data` matches the returned `quality` exactly.
        let data = try encode(image, quality: search.quality)
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

    // MARK: - PNG (lossless web still)

    /// Encode `image` as PNG — the lossless, universally web-decodable still format. There is no
    /// quality search (PNG has no lossy knob); the strongest native lever is adaptive row filtering,
    /// which is enabled. The score is **measured on the decode round-trip, never asserted** from
    /// "PNG is lossless": a 16-bit, CMYK, or exotic-colorspace source passes through an 8-bit RGB(A)
    /// conversion where losslessness is not a given, and the receipt should say what actually happened.
    public static func encodePNG(_ image: CGImage,
                                 channelScalars: SSIMULACRA2.ChannelScalars? = nil) throws -> PNGResult {
        let data = try encodePNGData(image)
        let decoded = try decode(data)
        let score: Double
        if let channelScalars {
            score = try SSIMULACRA2.score(reference: image, distorted: decoded, channelScalars: channelScalars)
        } else {
            score = try SSIMULACRA2.score(reference: image, distorted: decoded)
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
        // Adaptive (all-filters) row filtering — the one meaningful size lever ImageIO exposes for
        // PNG (the vendored-oxipng recompression pass was dropped in the media-bridge salvage).
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

    // MARK: - ImageIO HEIC

    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.heic.identifier as CFString, 1, nil) else { throw EncodeError.encodeFailed }
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
