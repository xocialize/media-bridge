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
    /// (0.1), score denoised frames against the decoded originals, return the mean. High (≥ ~96
    /// measured) = the filter no-ops = clean; low (~65 on real grain) = camera-noisy.
    ///
    /// ⚠️ Deliberately NO strength-0 baseline and NO per-frame strength changes. The first
    /// design alternated 0.0 ↔ 0.1 within one session to cancel round-trip deltas — and
    /// "strength change flushes the queue" (the documented behavior) became a 30-per-second
    /// flush storm that stalled the filter for ~240 s per run and then HARD-LOCKED the machine
    /// (2026-08-10, single core pegged, macOS 27 beta). Every clean run ever observed used one
    /// fixed strength per session; this probe now does too. The round-trip delta this accepts is
    /// negligible against the 99-vs-65 gate: the filter's pixel formats are the
    /// lossless-compressed family.
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

        // The window keeps the ORIGINAL BGRA alongside the compressed working buffer so the
        // denoised result can be scored against the true decoded frame — no strength-0 pass.
        var window: [(pts: CMTime, comp: CVPixelBuffer, original: CGImage)] = []
        func readNext() -> (pts: CMTime, comp: CVPixelBuffer, original: CGImage)? {
            guard let s = out.copyNextSampleBuffer(),
                  let bgra = CMSampleBufferGetImageBuffer(s),
                  let comp = session.compressed(from: bgra) else { return nil }
            var cg: CGImage?
            VTCreateCGImageFromCVPixelBuffer(bgra, options: nil, imageOut: &cg)
            guard let cg else { return nil }
            return (CMSampleBufferGetPresentationTimeStamp(s), comp, cg)
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
                var denPB: CVPixelBuffer?
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &denPB)
                if let denPB, session.bgra(from: denoised, into: denPB) {
                    var denCG: CGImage?
                    VTCreateCGImageFromCVPixelBuffer(denPB, options: nil, imageOut: &denCG)
                    if let denCG {
                        let s: Double?
                        if let gpu {
                            s = try? SSIMULACRA2.score(reference: current.original, distorted: denCG,
                                                       channelScalars: gpu.channelScalarsFunction)
                        } else {
                            s = try? SSIMULACRA2.score(reference: current.original, distorted: denCG)
                        }
                        if let s { scores.append(s) }
                    }
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
