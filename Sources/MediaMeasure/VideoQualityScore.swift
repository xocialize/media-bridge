import Foundation
import AVFoundation
import VideoToolbox
import CoreGraphics
import MediaMetrics

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
        let mm = MediaMetrics.begin("videoScore", lane: "score",
                                    attrs: ["ref": reference.lastPathComponent,
                                            "dist": distorted.lastPathComponent,
                                            "stride": "\(sampleStride)", "cap": "\(maxFrames)"])
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
        defer {
            MediaMetrics.end(mm, extra: ["decoded": "\(decoded)", "scored": "\(scores.count)",
                                         "backend": gpu != nil ? "gpu" : "cpu"])
        }
        while scores.count < maxFrames {
            let tN = DispatchTime.now()
            let hD = MediaMetrics.begin("vs.decodePair", lane: "decode", detail: 1)
            guard let r0 = ref.next(), let d0 = dist.next() else { MediaMetrics.end(hD); break }
            MediaMetrics.end(hD)
            decodeMs += MediaProfile.ms(since: tN); decoded += 1
            if idx % max(1, sampleStride) == 0 {
                let r = MediaMetrics.time("vs.resample", lane: "cpu", detail: 2) { resample(r0, to: matchSize) }
                let d = MediaMetrics.time("vs.resample", lane: "cpu", detail: 2) { resample(d0, to: matchSize) }
                guard r.width == d.width, r.height == d.height else { throw ScoreError.dimensionMismatch }
                let tS = DispatchTime.now()
                scores.append(try MediaMetrics.time("vs.ssimu2", lane: "score", detail: 1,
                                                    attrs: ["frame": "\(idx)"]) { try score(r, d) })
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

    /// Per-frame SSIMULACRA2 with **presentation-time pairing** — for scoring across ENCODERS,
    /// where frame-index pairing silently lies: a VFR capture against its CFR transcode drifts
    /// progressively (an iPhone master vs its Vimeo output measured p10 −14 by index — absurd
    /// scores from comparing different moments — while the pair is visually fine). Each sampled
    /// reference frame pairs with the distorted frame whose PTS is nearest, single sequential
    /// pass over both streams; samples with no distorted frame within `tolerance` seconds are
    /// SKIPPED and counted, never scored against the wrong moment.
    ///
    /// Index pairing (`videoScore`) remains correct — and cheaper — for same-chain comparisons:
    /// our own encodes preserve the source's frame sequence 1:1. Use THIS only when the two
    /// files may disagree about time. `matchSize` as in `videoScore`.
    public static func videoScorePTS(reference: URL, distorted: URL, sampleStride: Int = 1,
                                     maxFrames: Int = 60, matchSize: CGSize? = nil,
                                     tolerance: Double = 0.021) throws -> VideoQualityScore {
        let ref = try FrameStream(reference)
        let dist = try FrameStream(distorted)
        let gpu = SSIMULACRA2Metal.shared
        func score(_ r: CGImage, _ d: CGImage) throws -> Double {
            if let gpu {
                return try SSIMULACRA2.score(reference: r, distorted: d,
                                             channelScalars: gpu.channelScalarsFunction)
            }
            return try SSIMULACRA2.score(reference: r, distorted: d)
        }

        var scores: [Double] = []
        var skipped = 0
        var idx = 0
        // The distorted side advances lazily: hold the current frame and peek the next, moving
        // forward while the next one is closer to the reference PTS (both PTS runs are monotone).
        var dCurrent = dist.nextTimed()
        var dNext = dist.nextTimed()
        while scores.count < maxFrames {
            guard let r = ref.nextTimed() else { break }
            defer { idx += 1 }
            guard idx % max(1, sampleStride) == 0 else { continue }
            while let nxt = dNext, let cur = dCurrent,
                  abs(nxt.pts - r.pts) <= abs(cur.pts - r.pts) {
                dCurrent = nxt
                dNext = dist.nextTimed()
            }
            guard let cur = dCurrent, abs(cur.pts - r.pts) <= tolerance else {
                skipped += 1
                continue
            }
            let ri = resample(r.image, to: matchSize)
            let di = resample(cur.image, to: matchSize)
            guard ri.width == di.width, ri.height == di.height else { throw ScoreError.dimensionMismatch }
            scores.append(try score(ri, di))
        }
        guard !scores.isEmpty else { throw ScoreError.noFramesScored }
        if skipped > 0 {
            MediaProfile.log("  videoScorePTS: \(skipped) sample(s) had no partner within \(tolerance)s — skipped")
        }
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

/// Decodes a video's frames one at a time (BGRA → CGImage), bounded memory. Internal — also drives the
/// video-matte pipeline.
final class FrameStream {
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

    /// `next()` plus the frame's presentation time — the PTS-pairing scorer's currency.
    func nextTimed() -> (image: CGImage, pts: Double)? {
        guard let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &cg)
        guard let cg else { return nil }
        return (cg, pts)
    }

    func next() -> CGImage? {
        guard let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &cg)
        return cg
    }
}
