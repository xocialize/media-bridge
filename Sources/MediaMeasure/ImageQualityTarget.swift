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
