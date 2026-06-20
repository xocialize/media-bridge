import Foundation
import AVFoundation
import CoreMedia

/// Video analog of `ImageQualityTarget`: re-encode a clip to the **lowest HEVC bitrate whose per-frame
/// SSIMULACRA2 (p10) still clears the floor** → smaller file, perceptually equivalent, same resolution.
/// The lever is target *bitrate* (not constant-quality, which inflates an already-compressed source).
/// Video-only (audio passthrough/mux is the V3 wiring step); per-frame scoring is GPU-accelerated.
public enum VideoQualityTarget {

    public struct Result: Sendable {
        public let bitrate: Int           // AVVideoAverageBitRateKey chosen (bits/s)
        public let score: Double          // achieved p10 per-frame SSIMULACRA2
        public let inputBytes: Int
        public let outputBytes: Int
        public let sourceWidth: Int       // input resolution (= width/height unless downscaled)
        public let sourceHeight: Int
        public let width: Int             // output resolution
        public let height: Int
        public let metTarget: Bool
        public var savedFraction: Double {
            inputBytes > 0 ? Double(max(0, inputBytes - outputBytes)) / Double(inputBytes) : 0
        }
    }

    public enum EncodeError: Error, CustomStringConvertible {
        case noVideoTrack, encodeFailed, readFailed
        /// The source decoded partway then the reader/writer aborted (truncated/garbled container,
        /// `FigExport`-class failures). Carries the underlying AVFoundation error when available.
        case sourceAborted(Error?)
        public var description: String {
            switch self {
            case .noVideoTrack:        return "no video track"
            case .encodeFailed:        return "video encode failed"
            case .readFailed:          return "source could not be read"
            case .sourceAborted(let e): return "source aborted mid-encode: \(e.map(String.init(describing:)) ?? "unknown")"
            }
        }
    }

    /// Binary-search the target bitrate (down from the source bitrate); gate on the p10 frame so one bad
    /// frame can't pass. Smallest output whose p10 ≥ `targetScore` wins.
    ///
    /// `maxHeight` steps the resolution down (e.g. 1080 = 4K→HD): the output is resampled to ≤ that height
    /// (aspect preserved, even dims) and the quality floor is measured *at the target resolution* (the
    /// reference is downscaled to match — the encode quality of the HD version, not HD-vs-4K). nil = keep
    /// the source resolution (the same-res optimize path).
    /// `searchStride` overrides the sampling stride directly (legacy/explicit). Left nil (the default), the
    /// stride is **adaptive**: it targets `[minScoredFrames, maxScoredFrames]` frames spread across the clip,
    /// so a short clip can't collapse p10 to a noisy min-of-3. A fixed stride on a 49-frame clip scored ~3
    /// frames → p10 ≈ the single worst (noisy) frame → a non-monotonic, jittery bitrate search (worst on
    /// temporally-inconsistent AI video). Targeting ≥12 samples gives a stable 10th-percentile.
    public static func encode(input: URL, output: URL, targetScore: Double, maxHeight: Int? = nil,
                              iterations: Int = 6, searchStride: Int? = nil,
                              minScoredFrames: Int = 12, maxScoredFrames: Int = 16) async throws -> Result {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw EncodeError.noVideoTrack
        }
        let vsize = try await vtrack.load(.naturalSize)
        let vw = Int(abs(vsize.width).rounded()), vh = Int(abs(vsize.height).rounded())
        let inBytes = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sourceBitrate = duration > 0 ? Double(inBytes) * 8 / duration : 8_000_000

        // Resolve the output resolution; downscale only (never upscale here — that's the SR path).
        var outW = vw, outH = vh
        if let maxHeight, vh > maxHeight {
            outH = maxHeight - (maxHeight % 2)
            outW = Int((Double(vw) * Double(outH) / Double(vh)).rounded()); outW -= outW % 2
        }
        let downscaled = (outW != vw || outH != vh)
        // Ceiling = source bitrate (file-size cap: same bitrate × same duration ⇒ ≤ source size, and at a
        // lower resolution the search converges to a much lower clearing bitrate anyway). NOT scaled by the
        // pixel ratio — an already-compressed master would then ceiling below the quality floor at HD.
        let ceiling = sourceBitrate

        // Adaptive sampling: pick a stride that scores ≥ minScoredFrames across the clip (capped at
        // maxScoredFrames), so p10 is a real 10th-percentile, not a noisy min-of-3 on short clips. An
        // explicit `searchStride` overrides. Frame count ≈ duration × nominal fps (no full decode needed).
        let fpsRaw = Double((try? await vtrack.load(.nominalFrameRate)) ?? 30)
        let fps = fpsRaw > 0 ? fpsRaw : 30                       // some tracks report 0
        let frameCount = max(1, Int((fps * duration).rounded()))
        let stride = searchStride.map { max(1, $0) }
            ?? max(1, frameCount / max(1, minScoredFrames))
        let frameCap = searchStride == nil ? maxScoredFrames : 60

        MediaProfile.log("video optimize: \(vw)×\(vh)\(downscaled ? " → \(outW)×\(outH)" : "") · src "
            + String(format: "%.1f Mbps · %d iters · ~%d frames (stride %d of %d)",
                     sourceBitrate / 1e6, iterations, min(frameCap, (frameCount + stride - 1) / stride),
                     stride, frameCount))
        MediaProfile.log("SSIMULACRA2 backend → \(SSIMULACRA2Metal.diagnostics())")
        var profTranscodeMs = 0.0, profScoreMs = 0.0

        let tmpDir = FileManager.default.temporaryDirectory
        var temps: [URL] = []

        // Scoring reference. Same-res: the source itself. Downscale: a HIGH-quality HD render via OUR OWN
        // pipeline — so candidates are scored at the target resolution against the same downscaler, gating
        // the *added compression* (not HD-vs-4K, and free of the CG↔VideoToolbox resampler-delta artifact
        // that otherwise caps the achievable score a couple points below the floor).
        let scoreRef: URL
        if downscaled {
            let ref = tmpDir.appendingPathComponent("vqt-ref-\(UUID().uuidString).mp4")
            temps.append(ref)
            let tRef = DispatchTime.now()
            try await reencodeVideo(input: input, output: ref, bitrate: Int(ceiling),
                                    outWidth: outW, outHeight: outH)
            profTranscodeMs += MediaProfile.ms(since: tRef)
            scoreRef = ref
        } else {
            scoreRef = input
        }

        var lo = ceiling * 0.04, hi = ceiling
        var best: (bitrate: Int, score: Double, url: URL)?

        func scoreOf(_ url: URL) throws -> Double {
            try VideoQuality.videoScore(reference: scoreRef, distorted: url,
                                        sampleStride: stride, maxFrames: frameCap).p10
        }

        for i in 0..<iterations {
            let b = (lo + hi) / 2
            let tmp = tmpDir.appendingPathComponent("vqt-\(UUID().uuidString).mp4")
            temps.append(tmp)
            let tEnc = DispatchTime.now()
            try await reencodeVideo(input: input, output: tmp, bitrate: Int(b),
                                    outWidth: outW, outHeight: outH)
            let encMs = MediaProfile.ms(since: tEnc); profTranscodeMs += encMs
            let tSc = DispatchTime.now()
            let p10 = try scoreOf(tmp)
            let scMs = MediaProfile.ms(since: tSc); profScoreMs += scMs
            MediaProfile.log(String(format: "iter %d: %.2f Mbps · transcode %.0f ms · score %.0f ms · p10 %.1f",
                                    i + 1, b / 1e6, encMs, scMs, p10))
            if p10 >= targetScore {
                best = (Int(b), p10, tmp); hi = b        // clears → try smaller (lower bitrate)
            } else {
                lo = b                                    // below floor → need more bitrate
            }
        }

        let chosen: (bitrate: Int, score: Double, url: URL)
        if let best {
            chosen = best
        } else {
            let tmp = tmpDir.appendingPathComponent("vqt-final-\(UUID().uuidString).mp4")
            temps.append(tmp)
            try await reencodeVideo(input: input, output: tmp, bitrate: Int(hi),
                                    outWidth: outW, outHeight: outH)
            chosen = (Int(hi), try scoreOf(tmp), tmp)
        }

        // Deliverable lands at the host's `output` ONLY on a genuine win (cleared the floor AND smaller),
        // and ATOMICALLY (same-dir staging + rename — rename(2) is atomic, so `output` appears whole or not
        // at all; a non-atomic copy could leave a partial file if the source invalidates mid-copy). On a
        // miss, leave NO file at `output` — never orphan a best-effort encode. (Fixes EMBED-003 skip-orphan
        // + EMBED-005 partial-write-on-failure.)
        let outBytes = (try? chosen.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let didWin = best != nil && outBytes < inBytes
        if didWin {
            let staging = output.deletingLastPathComponent()
                .appendingPathComponent(".forge-\(UUID().uuidString).tmp")
            try FileManager.default.copyItem(at: chosen.url, to: staging)
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: staging, to: output)
        } else {
            try? FileManager.default.removeItem(at: output)
        }
        for t in temps { try? FileManager.default.removeItem(at: t) }

        let profTotal = profTranscodeMs + profScoreMs
        if profTotal > 0 {
            MediaProfile.log(String(format: "TOTAL: transcode %.0f ms (%.0f%%) · score %.0f ms (%.0f%%)",
                                    profTranscodeMs, 100 * profTranscodeMs / profTotal,
                                    profScoreMs, 100 * profScoreMs / profTotal))
        }

        return Result(bitrate: chosen.bitrate, score: chosen.score, inputBytes: inBytes,
                      outputBytes: outBytes, sourceWidth: vw, sourceHeight: vh,
                      width: outW, height: outH, metTarget: best != nil)
    }

    /// Map a video format description's colour attachments to an `AVVideoColorPropertiesKey` dict,
    /// defaulting each missing axis to BT.709 — the safe signage default (an untagged stream otherwise
    /// gets misread as 601, drifting saturated brand colours). Preserves HDR/BT.2020 tags when present.
    static func colorProperties(from format: CMFormatDescription?) -> [String: Any] {
        func ext(_ key: CFString, _ fallback: String) -> String {
            guard let format,
                  let v = CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
            else { return fallback }
            return v
        }
        return [
            AVVideoColorPrimariesKey: ext(kCMFormatDescriptionExtension_ColorPrimaries,
                                          AVVideoColorPrimaries_ITU_R_709_2),
            AVVideoTransferFunctionKey: ext(kCMFormatDescriptionExtension_TransferFunction,
                                            AVVideoTransferFunction_ITU_R_709_2),
            AVVideoYCbCrMatrixKey: ext(kCMFormatDescriptionExtension_YCbCrMatrix,
                                       AVVideoYCbCrMatrix_ITU_R_709_2),
        ]
    }

    /// Transcode the video track to HEVC at a target average bitrate; **passthrough-mux the audio** if
    /// present (no re-encode → no audio quality loss). No-audio sources produce a video-only output.
    /// Colour primaries/transfer/matrix are preserved from the source (BT.709 default) for brand fidelity.
    /// `outWidth`/`outHeight` (when given) scale the video via VideoToolbox — the 4K→HD downscale lever.
    static func reencodeVideo(input: URL, output: URL, bitrate: Int,
                              outWidth: Int? = nil, outHeight: Int? = nil) async throws {
        let asset = AVURLAsset(url: input)
        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw EncodeError.noVideoTrack
        }
        let size = try await vtrack.load(.naturalSize)
        let transform = try await vtrack.load(.preferredTransform)
        let w = outWidth ?? Int(abs(size.width).rounded())
        let h = outHeight ?? Int(abs(size.height).rounded())
        let atrack = try await asset.loadTracks(withMediaType: .audio).first
        // Passthrough audio needs the source format up front, else the writer can't add the input.
        let audioFormat = try await atrack?.load(.formatDescriptions).first
        // Preserve the source's colour tags; default to BT.709 when untagged. Decoding to BGRA drops
        // the matrix, so an untagged re-encode can get misread as 601 → saturated brand colours drift
        // while white stays put (the signage-playbook colour-fidelity gate). Pin primaries/transfer/matrix.
        let videoFormat = try await vtrack.load(.formatDescriptions).first
        let colorProperties = Self.colorProperties(from: videoFormat)

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(
            track: vtrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let atrack {
            let ao = AVAssetReaderTrackOutput(track: atrack, outputSettings: nil)   // stored format → passthrough
            ao.alwaysCopiesSampleData = false
            if reader.canAdd(ao) { reader.add(ao); audioOut = ao }
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: colorProperties,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ])
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,     // passthrough mux
                                       sourceFormatHint: audioFormat)
            ai.expectsMediaDataInRealTime = false
            if writer.canAdd(ai) { writer.add(ai); audioIn = ai }
        }

        guard reader.startReading() else { throw EncodeError.readFailed }
        guard writer.startWriting() else { throw EncodeError.encodeFailed }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        func pump(_ input: AVAssetWriterInput, _ out: AVAssetReaderTrackOutput, _ label: String) {
            group.enter()
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "vqt.\(label)")) {
                while input.isReadyForMoreMediaData {
                    if let s = out.copyNextSampleBuffer() {
                        if !input.append(s) {
                            FileHandle.standardError.write(Data("vqt: \(label) append failed: \(String(describing: writer.error))\n".utf8))
                            input.markAsFinished(); group.leave(); return
                        }
                    } else { input.markAsFinished(); group.leave(); return }
                }
            }
        }
        pump(videoIn, videoOut, "video")
        if let audioIn, let audioOut { pump(audioIn, audioOut, "audio") }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.notify(queue: DispatchQueue(label: "vqt.done")) { cont.resume() }
        }
        // A reader failure mid-pump surfaces as `copyNextSampleBuffer() == nil` — indistinguishable from
        // a clean EOF — so a truncated/garbled source (FigExport-class faults) would otherwise finalize a
        // SHORT "successful" encode and silently pass. Check the terminal status explicitly and THROW, so
        // the request layer's catch yields a single terminal `.failed` (never an empty stream / orphan).
        // (EMBED-005 #1 — fail-fast terminal-result guarantee.)
        if reader.status == .failed {
            writer.cancelWriting()
            throw EncodeError.sourceAborted(reader.error)
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if writer.status == .failed { throw EncodeError.sourceAborted(writer.error) }
    }
}
