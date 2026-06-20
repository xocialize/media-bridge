import Foundation
import AVFoundation
import VideoToolbox
import CoreGraphics

/// Aggregated per-frame SSIMULACRA2 of a video pair. For "perceptually equivalent" the **worst frames**
/// matter most (a single bad frame is visible), so `minimum`/`p10` gate the quality target, not just the
/// mean. The per-frame cost is exactly what gated this — now tractable with the GPU SSIMULACRA2 backend.
public struct VideoQualityScore: Sendable {
    public let mean: Double
    public let minimum: Double
    public let p10: Double          // 10th-percentile frame (worst-ish)
    public let framesScored: Int
}

public enum VideoQuality {
    public enum ScoreError: Error { case noVideoTrack, dimensionMismatch, noFramesScored }

    /// Per-frame SSIMULACRA2 of `distorted` vs `reference` (same frame order assumed), aggregated.
    /// GPU-scored when a Metal device is present. `sampleStride` scores every Nth decoded frame;
    /// `maxFrames` caps total scored frames to bound cost on long clips.
    ///
    /// `matchSize` handles the **downscale** case (4K→HD): when set, both frames are resampled to it
    /// before scoring, so the HD encode is gated against an HD-resampled reference (encode quality at the
    /// *target* resolution — the Vimeo "1080p is a downscale" semantic). Left nil, the pair must already
    /// share a resolution (the same-res optimize path). NB: the reference is resampled here with
    /// CoreGraphics while the encoder downscales with VideoToolbox — a small resampler delta makes the
    /// score slightly conservative vs a same-pipeline reference (fine for a floor; calibrate on real content).
    public static func videoScore(reference: URL, distorted: URL, sampleStride: Int = 1,
                                  maxFrames: Int = 60, matchSize: CGSize? = nil) throws -> VideoQualityScore {
        let ref = try FrameStream(reference)
        let dist = try FrameStream(distorted)
        // Use the **full-GPU per-channel path** (products + blur + map/reduce on device), the same one the
        // image optimize uses — NOT `gpu.score()`, which only offloads the blur and leaves the rest of the
        // SSIM math on the CPU (the dominant cost on large frames; ~565 ms/4K-frame → mostly CPU).
        let gpu = SSIMULACRA2Metal.shared
        func score(_ r: CGImage, _ d: CGImage) throws -> Double {
            if let gpu {
                return try SSIMULACRA2.score(reference: r, distorted: d,
                                             channelScalars: gpu.channelScalarsFunction)
            }
            return try SSIMULACRA2.score(reference: r, distorted: d)
        }

        var scores: [Double] = []
        var idx = 0, decoded = 0
        var decodeMs = 0.0, ssimMs = 0.0      // frame plumbing (decode+CGImage convert) vs the SSIMULACRA2 math
        while scores.count < maxFrames {
            let tN = DispatchTime.now()
            guard let r0 = ref.next(), let d0 = dist.next() else { break }
            decodeMs += MediaProfile.ms(since: tN); decoded += 1
            if idx % max(1, sampleStride) == 0 {
                let r = resample(r0, to: matchSize)
                let d = resample(d0, to: matchSize)
                guard r.width == d.width, r.height == d.height else { throw ScoreError.dimensionMismatch }
                let tS = DispatchTime.now()
                scores.append(try score(r, d))
                ssimMs += MediaProfile.ms(since: tS)
            }
            idx += 1
        }
        guard !scores.isEmpty else { throw ScoreError.noFramesScored }
        MediaProfile.log(String(format: "  videoScore: decoded %d (decode+convert %.0f ms) · scored %d "
            + "(ssimu2 %.0f ms, %@)", decoded, decodeMs, scores.count, ssimMs, gpu != nil ? "GPU" : "CPU"))

        let sorted = scores.sorted()
        let mean = scores.reduce(0, +) / Double(scores.count)
        let p10 = sorted[Int(Double(sorted.count - 1) * 0.1)]
        return VideoQualityScore(mean: mean, minimum: sorted[0], p10: p10, framesScored: scores.count)
    }

    /// High-quality CoreGraphics resample to `size` (no-op if `size` is nil or already matches).
    static func resample(_ image: CGImage, to size: CGSize?) -> CGImage {
        guard let size else { return image }
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0, w != image.width || h != image.height else { return image }
        let cs = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}

/// Decodes a video's frames one at a time (BGRA → CGImage), bounded memory.
private final class FrameStream {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    init(_ url: URL) throws {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw VideoQuality.ScoreError.noVideoTrack
        }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
    }

    func next() -> CGImage? {
        guard let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &cg)
        return cg
    }
}
