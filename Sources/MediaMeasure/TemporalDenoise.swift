//
// TemporalDenoise.swift — MediaMeasure
//
// VTTemporalNoiseFilter plumbing for the camera-class denoised-reference path (macOS 26+):
// the NOISE PROBE (how much would a conservative denoise change this clip?) and the per-frame
// filter used inside the mezzanine render. Strength is deliberately minimal (0.1): measured on
// real grain, the strength response is nearly flat (divergence ~65-67 across 0.1-0.5 — even the
// lightest setting removes essentially all temporal noise), so the least aggressive position is
// the whole over-smoothing guard. The filter accepts only Apple-compressed IOSurface formats →
// VTPixelTransferSession on both ends; frames need ≤1 previous + ≤2 next neighbors.
//
// Probed before integration per the new-VT-path discipline (Tools/vtprobe; the HEVC-lookahead
// machine-wedge lesson): 40 fps at 4K, VT services healthy across all probe runs.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

@available(macOS 26.0, *)
enum TemporalDenoise {

    /// The strength the whole camera path uses. See the header: minimal by measurement.
    static let strength: Float = 0.1

    /// A reusable filter session bound to one geometry, converting BGRA↔compressed at the edges.
    final class Session {
        private let processor = VTFrameProcessor()
        private let config: VTTemporalNoiseFilterConfiguration
        private let format: OSType
        private var xferIn: VTPixelTransferSession?
        private var xferOut: VTPixelTransferSession?
        private let w: Int, h: Int

        init?(width: Int, height: Int) {
            guard VTTemporalNoiseFilterConfiguration.isSupported,
                  let fmt = VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats.first,
                  let cfg = VTTemporalNoiseFilterConfiguration(frameWidth: width, frameHeight: height,
                                                               sourcePixelFormat: fmt)
            else { return nil }
            config = cfg
            format = fmt
            w = width
            h = height
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xferIn)
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xferOut)
            guard xferIn != nil, xferOut != nil else { return nil }
            do { try processor.startSession(configuration: cfg) } catch { return nil }
        }

        deinit { processor.endSession() }

        func compressed(from bgra: CVPixelBuffer) -> CVPixelBuffer? {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, format,
                                config.sourcePixelBufferAttributes as CFDictionary, &pb)
            guard let pb, let xferIn,
                  VTPixelTransferSessionTransferImage(xferIn, from: bgra, to: pb) == noErr
            else { return nil }
            return pb
        }

        func bgra(from compressed: CVPixelBuffer, into dst: CVPixelBuffer) -> Bool {
            guard let xferOut else { return false }
            return VTPixelTransferSessionTransferImage(xferOut, from: compressed, to: dst) == noErr
        }

        /// Filter one frame (compressed-format in/out) with its neighbors.
        func filter(current: (pts: CMTime, buf: CVPixelBuffer),
                    previous: [(pts: CMTime, buf: CVPixelBuffer)],
                    next: [(pts: CMTime, buf: CVPixelBuffer)],
                    strength: Float) async -> CVPixelBuffer? {
            var dst: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, format,
                                config.sourcePixelBufferAttributes as CFDictionary, &dst)
            guard let dst,
                  let srcFrame = VTFrameProcessorFrame(buffer: current.buf,
                                                       presentationTimeStamp: current.pts),
                  let dstFrame = VTFrameProcessorFrame(buffer: dst,
                                                       presentationTimeStamp: current.pts)
            else { return nil }
            let nextFrames = next.compactMap {
                VTFrameProcessorFrame(buffer: $0.buf, presentationTimeStamp: $0.pts)
            }
            let prevFrames = previous.compactMap {
                VTFrameProcessorFrame(buffer: $0.buf, presentationTimeStamp: $0.pts)
            }
            guard let params = VTTemporalNoiseFilterParameters(
                sourceFrame: srcFrame, nextFrames: nextFrames, previousFrames: prevFrames,
                destinationFrame: dstFrame, filterStrength: strength, hasDiscontinuity: false)
            else { return nil }
            do { try await processor.process(parameters: params) } catch { return nil }
            return dst
        }
    }

    /// The noise probe: decode `sampleFrames` consecutive frames, filter at ONE FIXED strength
    /// (0.1), score each denoised frame against the SAME frame round-tripped without the filter,
    /// return the mean. High (≥ ~96 measured) = the filter no-ops = clean; low (~65 on real
    /// grain) = camera-noisy.
    ///
    /// ⚠️ Deliberately NO strength-0 baseline and NO per-frame strength changes. The first
    /// design alternated 0.0 ↔ 0.1 within one session to cancel round-trip deltas — and
    /// "strength change flushes the queue" (the documented behavior) became a 30-per-second
    /// flush storm that stalled the filter for ~240 s per run and then HARD-LOCKED the machine
    /// (2026-08-10, single core pegged, macOS 27 beta). Every clean run ever observed used one
    /// fixed strength per session; this probe still does.
    ///
    /// The reference is round-tripped **by the pixel transfer sessions alone** — `compressed(from:)`
    /// then `bgra(from:into:)`, no `VTFrameProcessor` call, no strength change, nothing that can
    /// flush the filter queue. That is what cancels the conversion delta while fully respecting the
    /// wedge lesson above: cancelling the round trip never required a second *filter* pass, only a
    /// second *transfer*, and conflating those two is what produced the bug below.
    ///
    /// ⚠️ Scoring against the raw BGRA decode (as this did until 2026-08-16) measures
    /// `conversion loss + denoise effect`, not the denoise effect. The filter's source formats are
    /// the lossless-compressed **4:2:0 8-bit video-range** family (`.first` = `'&8v0'` =
    /// `kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange`) — "lossless" describes the
    /// surface's memory compression, NOT the colour conversion, which subsamples chroma and clamps
    /// full-range RGB into 16–235. On corpus footage that term is ~0 (the source is already 4:2:0
    /// video-range, so the trip is near-idempotent) which is exactly why the calibration looked
    /// right and the bug hid; on full-range RGB-authored content it dominates. Measured on the
    /// `TemporalDenoiseTests` clean fixture: raw-decode reference 82.0 (would falsely gate as
    /// camera-noisy), round-trip reference 92.0, with the filter itself accounting for only ~1.3
    /// of the 18-point gap.
    ///
    /// Both sides now traverse the identical conversion, so the score is the filter's effect alone.
    static func probe(input: URL, sampleFrames: Int) async -> Double? {
        let asset = AVURLAsset(url: input)
        guard let vtrack = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        guard let size = try? await vtrack.load(.naturalSize) else { return nil }
        let w = Int(abs(size.width).rounded()), h = Int(abs(size.height).rounded())
        guard let session = Session(width: w, height: h),
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(
            track: vtrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { return nil }

        VTBreadcrumb.log("TNF-PROBE-START \(w)×\(h) frames=\(sampleFrames) strength=\(strength) src=\(input.lastPathComponent)")
        defer { VTBreadcrumb.log("TNF-PROBE-END src=\(input.lastPathComponent)") }

        // The window carries only the compressed working buffer: BOTH scoring sides are produced
        // from it by `asScorable(_:)` below, so the reference costs one extra transfer on the
        // ~1-in-5 frames actually scored rather than a CGImage per decoded frame.
        var window: [(pts: CMTime, comp: CVPixelBuffer)] = []
        func readNext() -> (pts: CMTime, comp: CVPixelBuffer)? {
            guard let s = out.copyNextSampleBuffer(),
                  let bgra = CMSampleBufferGetImageBuffer(s),
                  let comp = session.compressed(from: bgra) else { return nil }
            return (CMSampleBufferGetPresentationTimeStamp(s), comp)
        }
        /// Bring a working buffer back to BGRA as a `CGImage` — the form SSIMULACRA2 scores. Run on
        /// the denoised frame AND on its unfiltered source, which is what cancels the conversion.
        func asScorable(_ compressed: CVPixelBuffer) -> CGImage? {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb, session.bgra(from: compressed, into: pb) else { return nil }
            var cg: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
            return cg
        }
        for _ in 0..<4 { if let f = readNext() { window.append(f) } }

        let gpu = SSIMULACRA2Metal.shared
        var scores: [Double] = []
        var cursor = 0
        var processed = 0
        while processed < sampleFrames, cursor < window.count {
            let current = window[cursor]
            let prev = cursor > 0 ? [window[cursor - 1]] : []
            let next = Array(window.suffix(from: min(cursor + 1, window.count)).prefix(2))
            // The filter runs on EVERY frame (temporal state needs the stream); scoring every 5th
            // is plenty at probe precision.
            if let denoised = await session.filter(
                current: (current.pts, current.comp),
                previous: prev.map { ($0.pts, $0.comp) },
                next: next.map { ($0.pts, $0.comp) },
                strength: strength),
               processed % 5 == 0 {
                if let refCG = asScorable(current.comp), let denCG = asScorable(denoised) {
                    let s: Double?
                    if let gpu {
                        s = try? SSIMULACRA2.score(reference: refCG, distorted: denCG,
                                                   channelScalars: gpu.channelScalarsFunction)
                    } else {
                        s = try? SSIMULACRA2.score(reference: refCG, distorted: denCG)
                    }
                    if let s { scores.append(s) }
                }
            }
            processed += 1
            if cursor >= 1 { window.removeFirst() } else { cursor += 1 }
            if let f = readNext() { window.append(f) }
        }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }
}
