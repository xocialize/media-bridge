import Accelerate
import Foundation
import AVFoundation
import CoreMedia
import MediaMetrics
import VideoToolbox

/// Video analog of `ImageQualityTarget`: re-encode a clip to the **lowest bitrate whose per-frame
/// SSIMULACRA2 (p10) still clears the floor** → smaller file, perceptually equivalent, same resolution.
/// The lever is target *bitrate* (not constant-quality, which inflates an already-compressed source).
/// The codec + delivery rule come from `EncodeProfile` — `.hevc` (native deliverable, the default) or
/// `.webH264` (universal web mp4: H.264 + AAC audio). Per-frame scoring is GPU-accelerated.
/// Durable VideoToolbox breadcrumbs, env-gated (`MEDIABRIDGE_VT_LOG=/path`). One fsync'd line
/// BEFORE each hardware encode starts and one on completion — after a machine-level wedge (the
/// 2026-08-09 HEVC-lookahead freezes took the whole UI down and left NO in-memory evidence), the
/// last START without a matching END names the operation that was in flight. Open-write-sync-close
/// per event: raceless, and the fsync survives a hard lock. Off (zero cost) unless the env var is
/// set — a library shouldn't write files as a silent side effect.
enum VTBreadcrumb {
    static let path: String? = ProcessInfo.processInfo.environment["MEDIABRIDGE_VT_LOG"]

    static func log(_ line: String) {
        guard let path else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) [\(ProcessInfo.processInfo.processIdentifier)] \(line)\n".utf8)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        defer { try? fh.close() }
        do {
            try fh.seekToEnd()
            try fh.write(contentsOf: data)
            try fh.synchronize()          // the durability guarantee — survive a hard lock
        } catch {}
    }
}

public enum VideoQualityTarget {

    /// How a clip's per-frame scores were reduced to the one number the floor was tested against.
    ///
    /// A video score is **not** a stills score, and a receipt that prints a bare number cannot say which
    /// it is. "Every frame cleared 80" and "the 10th percentile cleared 80 while the worst frame was 61"
    /// are both defensible guarantees and they are not the same guarantee — so the aggregation travels
    /// with the number instead of being computed and thrown away.
    public struct Aggregation: Sendable {
        /// The percentile the floor was gated on, as a whole number (10 = p10).
        public let percentile: Int
        /// The gating score — the value compared against the floor.
        public let percentileScore: Double
        /// Mean across scored frames. Context only; never the guarantee.
        public let mean: Double
        /// The single worst scored frame. This is what a mean would have hidden.
        public let minimum: Double
        /// How many frames were actually scored…
        public let framesScored: Int
        /// …out of how many the clip has. `framesScored < frameCount` means sampling.
        public let frameCount: Int

        /// One line fit for a receipt, stating the guarantee rather than implying a stronger one.
        public var summary: String {
            String(format: "p%d %.1f · min %.1f · mean %.1f · scored %d/%d frames",
                   percentile, percentileScore, minimum, mean, framesScored, frameCount)
        }
    }

    /// Live progress from inside the search — the structure a host needs to show more than a
    /// spinner during a multi-minute 4K run. The search is bounded and staged, so progress is
    /// *narratable*: a reference mezzanine (when downscaling / tone-mapping), then N candidate
    /// passes (each an encode + a scoring pass), then optional refinement (descent extension,
    /// corridor squeeze — `planned` grows when they engage), then the deliver/mux tail.
    ///
    /// `fraction` is the search's own 0…1 estimate (pass-granular, capped below 1.0 until the
    /// tail) so every consumer agrees on the bar. The callback fires on the search's task —
    /// hop to your actor/main thread before touching UI. Pass-level cadence (a handful of
    /// events per pass), never per-frame — no throttling needed.
    public struct SearchProgress: Sendable {
        public enum Stage: Sendable {
            /// Probe + sampling plan (fast).
            case preparing
            /// Rendering the near-lossless reference (downscale and/or HDR→SDR tone-map).
            case mezzanine(toneMapSDR: Bool, downscale: Bool)
            /// Candidate encode `index` of `planned` started at `bitrate` (bits/s).
            /// `label` names the phase ("iter 3", "descent 1", "squeeze", "ceiling").
            case pass(label: String, index: Int, planned: Int, bitrate: Int)
            /// Scoring the candidate that pass `index` just encoded.
            case scoring(label: String, index: Int, planned: Int)
            /// Pass verdict: the candidate's p10, whether it cleared the floor, and the best
            /// clearing candidate so far (nil until one clears) — the "best so far" UI line.
            case passResult(label: String, p10: Double, cleared: Bool,
                            bestBitrate: Int?, bestP10: Double?)
            /// Deliver/mux tail (atomic rename, audio handling).
            case finalizing
        }
        public let stage: Stage
        public let fraction: Double   // 0…1 overall estimate
    }

    /// What the search encodes toward. `.hevc` is the native Apple deliverable (the historical
    /// behavior and the default); `.webH264` is the universal web deliverable — H.264 + AAC in mp4,
    /// the one combination every browser decodes (HEVC-in-mp4 does not play in Chrome/Firefox).
    public struct EncodeProfile: Sendable {
        public let codec: AVVideoCodecType
        /// Transcode non-AAC audio (Opus/FLAC/ALAC/PCM) to AAC-LC; AAC (and no-audio) still
        /// passthrough-muxes — never a generation loss when the source is already web-safe.
        public let webSafeAudio: Bool
        /// Search-ceiling multiplier over the source bitrate. H.264 needs roughly 1.5–2× HEVC's
        /// bitrate for the same quality, so a web encode of an efficient HEVC master must be allowed
        /// to spend more bits than the source or the floor becomes unreachable by construction.
        public let ceilingScale: Double
        /// Deliver only when the output is smaller than the source. Off for a format *conversion*
        /// (a web deliverable from a non-web source is the point even when it is larger).
        public let requireSmaller: Bool
        /// Deliver the highest-quality candidate (the ceiling encode) even when no candidate cleared
        /// the floor. For a *conversion* the caller asked for a playable file, not a smaller one — a
        /// best-effort deliverable beats no deliverable. `metTarget` still tells the truth: the
        /// receipt shows the achieved score against the floor that was asked for.
        public let bestEffortOnFloorMiss: Bool
        /// Per-frame QP ceiling passed to VideoToolbox (`kVTCompressionPropertyKey_MaxAllowedFrameQP`).
        /// Under ABR the encoder's own rate model sways with content — hard scenes crater while easy
        /// scenes get polished — and a p10 gate is dominated by exactly those craters. Clamping max QP
        /// forces bits into the hard frames at (measured) negligible size cost, so the floor search
        /// converges to a lower bitrate. Sevilla 3240×1920 @ 6 Mbps H.264: min frame 71.9 → 81.2
        /// SSIMULACRA2 for +1.5% bytes (2026-08-09). nil = encoder default.
        public let maxAllowedQP: Int?
        /// Per-frame QP floor (`kVTCompressionPropertyKey_MinAllowedFrameQP`) — the other half of the
        /// corridor: stops ABR over-polishing easy scenes past what the perceptual floor asked for,
        /// freeing budget the max-QP clamp redirects into the hard band. Measured at Vimeo-matched
        /// size (33 MB) on Sevilla: corridor (20,34) beat plain maxQP at equal size (2026-08-09).
        /// ⚠️ A min QP CAPS achievable quality, and the floor↔QP mapping is content-dependent (a
        /// 320×240 synthetic-noise clip needs QP < 20 for floor *70*), so this is NEVER applied to
        /// the search itself — the search stays monotone and floor-safe on max QP alone, and the min
        /// rides only on the post-search **corridor squeeze**: one candidate below the winner's rate,
        /// adopted only if it still clears the floor and is strictly smaller. nil = no squeeze.
        public let minAllowedQP: Int?
        /// Deliver SDR BT.709 from HDR sources (HLG/PQ BT.2020 — every recent iPhone capture):
        /// the tone-map runs once in the mezzanine (VTPixelTransferSession, colour only — the
        /// measured-good vImage scaler still owns any resizing) and the search runs SDR-vs-SDR
        /// against it. Without this, web outputs carry HDR tags on 8-bit H.264 — inconsistent
        /// across browsers — and the search compares HDR-decoded reference frames against
        /// SDR-ish candidates (the img3140 cross-gamut failure, inside our own gate). False on
        /// the native profile: HDR HEVC is a legitimate Apple-native deliverable.
        public let deliverSDR: Bool
        /// Re-encode AAC audio whose per-channel rate EXCEEDS this (bits/s/channel) down to
        /// AAC-LC ~96k/ch — the audio half of the Vimeo parity rung (they normalize 317k stereo
        /// masters to ~189k; we passthrough-muxed them whole, ~8% of the file on small graphic
        /// clips). Threshold-gated so at-or-below-web-rate audio still passthroughs — a
        /// generation loss is taken only when the byte win is real. nil = passthrough always
        /// (the native/HEVC profile keeps the historical behavior).
        public let normalizeAudioAbovePerChannelBPS: Int?
        /// `kVTCompressionPropertyKey_SuggestedLookAheadFrameCount` (macOS 15+; skipped on 14 —
        /// the key predates our floor). The hw encoder's DEFAULT IS ZERO lookahead: no
        /// scene-adaptive keyframes, no statistics-driven allocation. 16 frames measured on Sevilla
        /// 3240×1920 @ 4.2 Mbps: mean 87.2 → 89.0, p10 80.2 → 81.8 at a slightly SMALLER file; on
        /// flat text it collapsed the size-at-quality gap ~3.5× (2026-08-09) — the biggest
        /// quality-per-byte knob after the 4:2:0 decode fix. Encode wall-time ~doubles; the right
        /// trade for an offline optimizer. Incompatible with VT multipass and Quality-mode CQP.
        public let lookAheadFrames: Int?

        public init(codec: AVVideoCodecType, webSafeAudio: Bool,
                    ceilingScale: Double, requireSmaller: Bool,
                    bestEffortOnFloorMiss: Bool = false,
                    maxAllowedQP: Int? = nil, minAllowedQP: Int? = nil,
                    lookAheadFrames: Int? = nil,
                    normalizeAudioAbovePerChannelBPS: Int? = nil,
                    deliverSDR: Bool = false) {
            self.codec = codec
            self.webSafeAudio = webSafeAudio
            self.ceilingScale = ceilingScale
            self.requireSmaller = requireSmaller
            self.bestEffortOnFloorMiss = bestEffortOnFloorMiss
            self.maxAllowedQP = maxAllowedQP
            self.minAllowedQP = minAllowedQP
            self.lookAheadFrames = lookAheadFrames
            self.normalizeAudioAbovePerChannelBPS = normalizeAudioAbovePerChannelBPS
            self.deliverSDR = deliverSDR
        }

        /// The native deliverable. Encoder knobs measured on their own HEVC probe (2026-08-09,
        /// Sevilla 3240×1920 @ 3 Mbps, per-frame p10 SSIMULACRA2): a 4 s keyframe cadence the
        /// HEVC path never set = **+1.8 p10 / +6.7 min-frame free** over the encoder default;
        /// max-QP 38 flat across 34–38 (+1.4 p10 tail insurance); squeeze min 18 (min 22
        /// measured HARMFUL on HEVC — its QP scale is not H.264's).
        ///
        /// ⚠️ **No `lookAheadFrames` on HEVC — deliberately.** It measured +1.6 p10, but the two
        /// suite runs gating it were the only two runs (of ~10 that day) that WEDGED the machine's
        /// media engine — VT XPC services in uninterruptible kernel sleep, then a system-wide UI
        /// hard lock (macOS 27.0 beta; this machine also has documented hw-VT stall prior art in
        /// NativeMP4Writer). HEVC+lookahead was never validated by the VT capability probes (they
        /// ran on the H.264 session). Re-admit only behind a stability probe on a machine someone
        /// is prepared to reboot; the H.264 profiles keep lookahead — no freeze was ever observed
        /// on the H.264 session.
        public static let hevc = EncodeProfile(codec: .hevc, webSafeAudio: false,
                                               ceilingScale: 1.0, requireSmaller: true,
                                               maxAllowedQP: 38, minAllowedQP: 18)
        /// The universal web deliverable for a source that is not already web-native: a conversion
        /// always delivers — larger is fine, and a floor miss falls back to the ceiling encode.
        /// QP clamp 34 + squeeze min 20 + lookahead 16 are H.264-tuned (Vimeo-parity work,
        /// 2026-08-09); HEVC's QP scale maps differently and keeps encoder defaults until measured
        /// on its own.
        public static let webH264 = EncodeProfile(codec: .h264, webSafeAudio: true,
                                                  ceilingScale: 2.0, requireSmaller: false,
                                                  bestEffortOnFloorMiss: true,
                                                  maxAllowedQP: 34, minAllowedQP: 20,
                                                  lookAheadFrames: 16,
                                                  normalizeAudioAbovePerChannelBPS: 112_000,
                                                  deliverSDR: true)
        /// `webH264`'s shrink-only sibling for sources that are ALREADY web-native (or have a
        /// lossless remux as the baseline deliverable): source-bitrate ceiling, strictly smaller,
        /// no best-effort — but the SAME encoder knobs. Hosts hand-rolling this profile is how the
        /// web-native path silently missed the corridor + lookahead (the Vimeo-parity wiring gap,
        /// 2026-08-09): the knobs live on the preset so they can't be forgotten at a call site.
        public static let webH264Shrink = EncodeProfile(codec: .h264, webSafeAudio: true,
                                                        ceilingScale: 1.0, requireSmaller: true,
                                                        maxAllowedQP: 34, minAllowedQP: 20,
                                                        lookAheadFrames: 16,
                                                        normalizeAudioAbovePerChannelBPS: 112_000,
                                                        deliverSDR: true)

        /// Receipt/log label for the codec ("HEVC" / "H.264"; falls back to the fourCC).
        public var codecLabel: String {
            switch codec {
            case .hevc: return "HEVC"
            case .h264: return "H.264"
            default: return codec.rawValue
            }
        }
    }

    public struct Result: Sendable {
        public let bitrate: Int           // AVVideoAverageBitRateKey chosen (bits/s)
        public let score: Double          // achieved p10 per-frame SSIMULACRA2
        /// The full reduction behind `score`. Report this, not `score` alone (BRIDGE-061).
        public let aggregation: Aggregation
        public let inputBytes: Int
        public let outputBytes: Int
        public let sourceWidth: Int       // input resolution (= width/height unless downscaled)
        public let sourceHeight: Int
        public let width: Int             // output resolution
        public let height: Int
        public let metTarget: Bool
        /// Whether the deliverable was actually written to `output`: the floor was met AND — when the
        /// profile requires it — the output is smaller than the source. Read this, don't re-derive it
        /// from `metTarget` + sizes: the delivery rule is the profile's, not the caller's.
        public let delivered: Bool
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
    /// `maxHeight` steps the resolution down by CLASS (e.g. 1080 = 4K→HD): it caps the SHORT side —
    /// a 1080×1920 portrait IS 1080p-class and stays untouched; a 2160×3840 portrait becomes
    /// 1080×1920 (aspect preserved, even dims). The quality floor is measured *at the target
    /// resolution* (the reference mezzanine is downscaled to match — the encode quality of the HD
    /// version, not HD-vs-4K). nil = keep the source resolution (the same-res optimize path).
    /// `searchStride` overrides the sampling stride directly (legacy/explicit). Left nil (the default), the
    /// stride is **adaptive**: it targets `[minScoredFrames, maxScoredFrames]` frames spread across the clip,
    /// so a short clip can't collapse p10 to a noisy min-of-3. A fixed stride on a 49-frame clip scored ~3
    /// frames → p10 ≈ the single worst (noisy) frame → a non-monotonic, jittery bitrate search (worst on
    /// temporally-inconsistent AI video). Targeting ≥12 samples gives a stable 10th-percentile.
    public static func encode(input: URL, output: URL, targetScore: Double, maxHeight: Int? = nil,
                              iterations: Int = 6, searchStride: Int? = nil,
                              minScoredFrames: Int = 12, maxScoredFrames: Int = 16,
                              profile: EncodeProfile = .hevc,
                              denoiseStrength: Float? = nil,
                              onProgress: (@Sendable (SearchProgress) -> Void)? = nil)
        async throws -> Result {
        let mmEncode = MediaMetrics.begin("vqt.encode", lane: "orchestrate",
                                          attrs: ["input": input.lastPathComponent,
                                                  "profile": profile.codecLabel,
                                                  "target": String(format: "%.0f", targetScore)])
        defer { MediaMetrics.end(mmEncode) }
        let mmPrepare = MediaMetrics.begin("vqt.prepare", lane: "orchestrate")
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw EncodeError.noVideoTrack
        }
        let vsize = try await vtrack.load(.naturalSize)
        let vw = Int(abs(vsize.width).rounded()), vh = Int(abs(vsize.height).rounded())
        let inBytes = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sourceBitrate = duration > 0 ? Double(inBytes) * 8 / duration : 8_000_000
        func emit(_ stage: SearchProgress.Stage, _ fraction: Double) {
            onProgress?(SearchProgress(stage: stage, fraction: fraction))
        }
        emit(.preparing, 0.02)
        // HDR source (HLG/PQ) + an SDR-delivering profile → the mezzanine tone-maps once and the
        // whole search runs SDR-vs-SDR. Detection is by transfer tag; untagged sources are SDR.
        let sourceFormat = try await vtrack.load(.formatDescriptions).first
        let toneMapSDR = profile.deliverSDR && Self.isHDRTransfer(sourceFormat)

        // Resolve the output resolution; downscale only (never upscale here — that's the SR path).
        // `maxHeight` means the RESOLUTION CLASS — it caps the SHORT side. A 1080×1920 portrait
        // phone clip IS 1080p-class (untouched at maxHeight 1080); a 2160×3840 portrait downscales
        // to 1080×1920, not to a 608×1080 thumbnail (the literal-height reading, which no consumer
        // means). Landscape behaves exactly as before (height is the short side).
        var outW = vw, outH = vh
        if let maxHeight, min(vw, vh) > maxHeight {
            let cap = maxHeight - (maxHeight % 2)
            if vh <= vw {
                outH = cap
                outW = Int((Double(vw) * Double(outH) / Double(vh)).rounded()); outW -= outW % 2
            } else {
                outW = cap
                outH = Int((Double(vh) * Double(outW) / Double(vw)).rounded()); outH -= outH % 2
            }
        }
        let downscaled = (outW != vw || outH != vh)
        // Ceiling = source bitrate (file-size cap: same bitrate × same duration ⇒ ≤ source size, and at a
        // lower resolution the search converges to a much lower clearing bitrate anyway). NOT scaled by the
        // pixel ratio — an already-compressed master would then ceiling below the quality floor at HD.
        // The profile scales it (web H.264 needs headroom over an efficient HEVC source — see EncodeProfile).
        let ceiling = sourceBitrate * profile.ceilingScale

        // Adaptive sampling: pick a stride that scores ≥ minScoredFrames across the clip (capped at
        // maxScoredFrames), so p10 is a real 10th-percentile, not a noisy min-of-3 on short clips. An
        // explicit `searchStride` overrides. Frame count ≈ duration × nominal fps (no full decode needed).
        let fpsRaw = Double((try? await vtrack.load(.nominalFrameRate)) ?? 30)
        let fps = fpsRaw > 0 ? fpsRaw : 30                       // some tracks report 0
        let frameCount = max(1, Int((fps * duration).rounded()))
        let stride = searchStride.map { max(1, $0) }
            ?? max(1, frameCount / max(1, minScoredFrames))
        let frameCap = searchStride == nil ? maxScoredFrames : 60

        MediaProfile.log("video optimize → \(profile.codecLabel): \(vw)×\(vh)\(downscaled ? " → \(outW)×\(outH)" : "") · src "
            + String(format: "%.1f Mbps · %d iters · ~%d frames (stride %d of %d)",
                     sourceBitrate / 1e6, iterations, min(frameCap, (frameCount + stride - 1) / stride),
                     stride, frameCount))
        MediaProfile.log("SSIMULACRA2 backend → \(SSIMULACRA2Metal.diagnostics())")
        MediaMetrics.end(mmPrepare, extra: ["frames": "\(frameCount)", "stride": "\(stride)"])
        var profTranscodeMs = 0.0, profScoreMs = 0.0

        let tmpDir = FileManager.default.temporaryDirectory
        var temps: [URL] = []

        // Scoring reference AND (for a downscale) the search input. Same-res: the source itself.
        // Downscale: a near-lossless Lanczos MEZZANINE at the target resolution — candidates encode
        // it 1:1 and are scored against it, gating the *added compression*. The mezzanine exists
        // because the writer's own scaler is not usable for quality work: at a NEAR-LOSSLESS
        // 30 Mbps, writer-scaled 4K→1080 scored p10 38.6 SSIMULACRA2 on the upscale-to-source leg
        // where a Lanczos downscale of the same frames scored 61.7 (+23 — texture frames alias
        // and no bitrate buys them back; Vimeo's COMPRESSED 1080 rung scores 63.9 on that leg).
        // Scaling once here also removes per-candidate scaling from the search entirely.
        let needsMezzanine = downscaled || toneMapSDR || denoiseStrength != nil
        let scoreRef: URL
        if needsMezzanine {
            let ref = tmpDir.appendingPathComponent("vqt-mezz-\(UUID().uuidString).mp4")
            temps.append(ref)
            let tRef = DispatchTime.now()
            emit(.mezzanine(toneMapSDR: toneMapSDR, downscale: downscaled), 0.05)
            try await MediaMetrics.time("vqt.mezzanine", lane: "encode",
                                        attrs: ["out": "\(outW)x\(outH)",
                                                "toneMapSDR": "\(toneMapSDR)",
                                                "denoise": "\(denoiseStrength != nil)"]) {
                try await renderDownscaleMezzanine(input: input, output: ref, bitrate: Int(ceiling),
                                                   outWidth: outW, outHeight: outH,
                                                   codec: profile.codec,
                                                   lookAhead: profile.lookAheadFrames,
                                                   toneMapSDR: toneMapSDR,
                                                   denoiseStrength: denoiseStrength)
            }
            let ms = MediaProfile.ms(since: tRef)
            profTranscodeMs += ms
            MediaProfile.log(String(format: "mezzanine: %d×%d → %d×%d%@%@ · %.0f ms",
                                    vw, vh, outW, outH, toneMapSDR ? " · HDR→SDR tone-map" : "",
                                    denoiseStrength != nil ? " · temporal denoise" : "", ms))
            scoreRef = ref
        } else {
            scoreRef = input
        }
        // Candidates re-encode the mezzanine at its own resolution — never the writer's scaler.
        let searchInput = needsMezzanine ? scoreRef : input
        let candW: Int? = needsMezzanine ? nil : outW
        let candH: Int? = needsMezzanine ? nil : outH

        var lo = ceiling * 0.04, hi = ceiling
        let initialLo = lo
        var best: (bitrate: Int, score: VideoQualityScore, url: URL)?

        // Pass accounting for `SearchProgress.fraction`: the base plan is the binary-search
        // iterations; descent/squeeze/ceiling passes grow `plannedPasses` as they engage, so the
        // bar re-paces instead of pinning at the cap. Passes span 0.10…0.92 of the fraction.
        var passesDone = 0
        var plannedPasses = iterations
        func passFraction(_ sub: Double) -> Double {
            let denom = Double(max(plannedPasses, passesDone + 1))
            return min(0.92, 0.10 + 0.82 * (Double(passesDone) + sub) / denom)
        }

        // Score off the cooperative pool at .utility QoS (EMBED-004): the host drives encode from a
        // .userInitiated Task, so scoring inline would block a high-QoS thread on CoreGraphics's
        // Default-QoS rasterization → a priority inversion. Awaiting the hop suspends instead of blocking.
        func scoreOf(_ url: URL, refined: Bool = false) async throws -> VideoQualityScore {
            let s = refined ? max(1, stride / 2) : stride
            let cap = refined ? frameCap * 2 : frameCap
            return try await ScoringExecutor.run {
                try VideoQuality.videoScore(reference: scoreRef, distorted: url,
                                            sampleStride: s, maxFrames: cap)
            }
        }
        // A p10 over ~13 sampled frames jitters ±1 near the gate — enough to pin the binary
        // search's lower bound above the true clearing point (Ferrari: landed 15.8 Mbps where
        // ~11.5 clears, +15% bytes) and to stall the squeeze walk-down. Candidates landing within
        // this band of the floor get re-scored at 2× sampling before the verdict; only borderline
        // iterations pay (one extra scoring pass, no extra encode). Skipped when the stride is
        // already 1 — every frame is scored and there is nothing to refine.
        let nearGateBand = 1.5

        // Max QP rides on every search candidate (it only ever lifts the tail — floor-safe, keeps
        // the search monotone). Min QP NEVER does: it caps achievable quality with a content-
        // dependent mapping, which can make a floor unreachable by construction (the BGRA-ceiling
        // failure mode, reintroduced by policy). It applies only in the corridor squeeze below.
        func searchStep(_ b: Double, _ label: String, minQP: Int? = nil) async throws -> Bool {
            let tmp = tmpDir.appendingPathComponent("vqt-\(UUID().uuidString).mp4")
            temps.append(tmp)
            let passIndex = passesDone + 1
            if passIndex > plannedPasses { plannedPasses = passIndex }
            emit(.pass(label: label, index: passIndex, planned: plannedPasses, bitrate: Int(b)),
                 passFraction(0.05))
            let tEnc = DispatchTime.now()
            try await MediaMetrics.time("vqt.pass.encode", lane: "encode",
                                        attrs: ["label": label,
                                                "mbps": String(format: "%.2f", b / 1e6),
                                                "minQP": minQP.map(String.init) ?? ""]) {
                try await reencodeVideo(input: searchInput, output: tmp, bitrate: Int(b),
                                        outWidth: candW, outHeight: candH,
                                        codec: profile.codec, webSafeAudio: profile.webSafeAudio,
                                        maxQP: profile.maxAllowedQP, minQP: minQP,
                                        lookAhead: profile.lookAheadFrames,
                                        normalizeAudioAboveBPS: profile.normalizeAudioAbovePerChannelBPS)
            }
            let encMs = MediaProfile.ms(since: tEnc); profTranscodeMs += encMs
            emit(.scoring(label: label, index: passIndex, planned: plannedPasses),
                 passFraction(0.6))
            let tSc = DispatchTime.now()
            var scored = try await MediaMetrics.time("vqt.pass.score", lane: "score",
                                                     attrs: ["label": label]) {
                try await scoreOf(tmp)
            }
            if abs(scored.p10 - targetScore) < nearGateBand, stride > 1 {
                let refined = try await MediaMetrics.time("vqt.pass.rescore", lane: "score",
                                                          attrs: ["label": label]) {
                    try await scoreOf(tmp, refined: true)
                }
                MediaProfile.log(String(format: "%@: near-gate %.1f → re-scored %.1f (%d frames)",
                                        label, scored.p10, refined.p10, refined.framesScored))
                scored = refined
            }
            let scMs = MediaProfile.ms(since: tSc); profScoreMs += scMs
            MediaProfile.log(String(format: "%@: %.2f Mbps · transcode %.0f ms · score %.0f ms · p10 %.1f",
                                    label, b / 1e6, encMs, scMs, scored.p10))
            let cleared = scored.p10 >= targetScore
            MediaMetrics.event("vqt.passResult",
                               attrs: ["label": label, "p10": String(format: "%.2f", scored.p10),
                                       "cleared": "\(cleared)",
                                       "mbps": String(format: "%.2f", b / 1e6)])
            if cleared { best = (Int(b), scored, tmp) }
            emit(.passResult(label: label, p10: scored.p10, cleared: cleared,
                             bestBitrate: best?.bitrate, bestP10: best?.score.p10),
                 passFraction(1.0))
            passesDone += 1
            return cleared
        }

        for i in 0..<iterations {
            let b = (lo + hi) / 2
            if try await searchStep(b, "iter \(i + 1)") {
                hi = b                                    // clears → try smaller (lower bitrate)
            } else {
                lo = b                                    // below floor → need more bitrate
            }
        }

        // Descent extension: `lo` never moved — no candidate ever failed the floor, so the true
        // clearing point sits somewhere BELOW everything tested (very compressible content, or an
        // over-provisioned master), and stopping here would ship bits the perceptual floor never
        // asked for. One extension pass reaches 50× further down; it only runs when the floor never
        // pushed back, so typical content pays nothing.
        if lo == initialLo, let current = best {
            MediaProfile.log("descent: no candidate failed the floor — extending the search down")
            plannedPasses += iterations   // re-pace the progress bar for the extension
            var lo2 = Double(current.bitrate) * 0.02
            var hi2 = Double(current.bitrate)
            for i in 0..<iterations {
                let b = (lo2 + hi2) / 2
                if try await searchStep(b, "descent \(i + 1)") {
                    hi2 = b
                } else {
                    lo2 = b
                }
            }
        }

        // Corridor squeeze: one post-search candidate below the winner's *emitted* rate with the
        // min-QP corridor engaged. The corridor redistributes easy-frame overspend into the hard
        // band, clearing the same floor at a lower rate on real content (Sevilla: −10–15% bytes at
        // equal p10) — but its floor↔QP mapping is content-dependent, so it must never gate the
        // search itself. Adopt only a candidate that still clears the floor AND is strictly smaller;
        // any other outcome keeps the incumbent. (Nominal targets overshoot what ABR actually
        // emits, so the probe anchors on emitted bytes, not the nominal search bitrate.)
        // Up to 3 steps: the binary search's landing is jittery (p10 over ~13 sampled frames flips
        // near the gate, pinning `lo` above the true clearing point — Ferrari landed 15.8 Mbps
        // where ~11.5 clears), and each adopted step re-anchors on the new winner's emitted rate,
        // so the walk-down follows actual bytes, not nominal fiction. Stops the first time a
        // candidate fails the floor or fails to shrink.
        if let squeezeMinQP = profile.minAllowedQP {
            for _ in 0..<3 {
                guard let current = best else { break }
                let curBytes = (try? current.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let actualRate = duration > 0 ? Double(curBytes) * 8 / duration : 0
                guard actualRate > 0 else { break }
                MediaProfile.log(String(format: "corridor squeeze: winner emitted %.2f Mbps — probing %.2f with QP ≥ %d",
                                        actualRate / 1e6, actualRate * 0.92 / 1e6, squeezeMinQP))
                guard try await searchStep(actualRate * 0.92, "squeeze", minQP: squeezeMinQP),
                      let nb = best, nb.url != current.url else { break }
                let nbBytes = (try? nb.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if nbBytes >= curBytes { best = current; break }   // not smaller → keep the incumbent
            }
        }

        let chosen: (bitrate: Int, score: VideoQualityScore, url: URL)
        if let best {
            chosen = best
        } else {
            let tmp = tmpDir.appendingPathComponent("vqt-final-\(UUID().uuidString).mp4")
            temps.append(tmp)
            plannedPasses += 1
            emit(.pass(label: "ceiling", index: passesDone + 1, planned: plannedPasses,
                       bitrate: Int(hi)), passFraction(0.05))
            try await MediaMetrics.time("vqt.pass.encode", lane: "encode",
                                        attrs: ["label": "ceiling",
                                                "mbps": String(format: "%.2f", hi / 1e6)]) {
                try await reencodeVideo(input: searchInput, output: tmp, bitrate: Int(hi),
                                        outWidth: candW, outHeight: candH,
                                        codec: profile.codec, webSafeAudio: profile.webSafeAudio,
                                        maxQP: profile.maxAllowedQP,
                                        lookAhead: profile.lookAheadFrames,
                                        normalizeAudioAboveBPS: profile.normalizeAudioAbovePerChannelBPS)
            }
            chosen = (Int(hi),
                      try await MediaMetrics.time("vqt.pass.score", lane: "score",
                                                  attrs: ["label": "ceiling"]) { try await scoreOf(tmp) },
                      tmp)
        }

        // Deliverable lands at the host's `output` ONLY on a genuine win (cleared the floor AND smaller),
        // and ATOMICALLY (same-dir staging + rename — rename(2) is atomic, so `output` appears whole or not
        // at all; a non-atomic copy could leave a partial file if the source invalidates mid-copy). On a
        // miss, leave NO file at `output` — never orphan a best-effort encode. (Fixes EMBED-003 skip-orphan
        // + EMBED-005 partial-write-on-failure.)
        emit(.finalizing, 0.95)
        let mmFinalize = MediaMetrics.begin("vqt.finalize", lane: "io")
        let outBytes = (try? chosen.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // A format *conversion* (web profile) delivers even when larger — the size gate is the
        // profile's call. A floor miss delivers the ceiling encode when the profile says best-effort
        // (`chosen` IS that encode on a miss); `metTarget` reports the miss either way.
        let didWin = (best != nil || profile.bestEffortOnFloorMiss)
            && (!profile.requireSmaller || outBytes < inBytes)
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
        MediaMetrics.end(mmFinalize, extra: ["delivered": "\(didWin)"])

        let profTotal = profTranscodeMs + profScoreMs
        if profTotal > 0 {
            MediaProfile.log(String(format: "TOTAL: transcode %.0f ms (%.0f%%) · score %.0f ms (%.0f%%)",
                                    profTranscodeMs, 100 * profTranscodeMs / profTotal,
                                    profScoreMs, 100 * profScoreMs / profTotal))
        }

        // Publish the whole reduction, not just the gating number (BRIDGE-061). `frameCount` is the
        // clip's own length, so `framesScored / frameCount` states plainly that this was a sample.
        let aggregation = Aggregation(
            percentile: 10, percentileScore: chosen.score.p10,
            mean: chosen.score.mean, minimum: chosen.score.minimum,
            framesScored: chosen.score.framesScored, frameCount: frameCount)

        return Result(bitrate: chosen.bitrate, score: chosen.score.p10, aggregation: aggregation,
                      inputBytes: inBytes,
                      outputBytes: outBytes, sourceWidth: vw, sourceHeight: vh,
                      width: outW, height: outH, metTarget: best != nil, delivered: didWin)
    }

    /// Map a video format description's colour attachments to an `AVVideoColorPropertiesKey` dict,
    /// defaulting missing axes by the SOURCE's geometry. Preserves HDR/BT.2020 tags when present.
    ///
    /// The untagged default must describe the VALUES the 4:2:0-passthrough decode hands the writer
    /// untouched — and AVFoundation's implicit matrix is dimension-based: SD → 601/SMPTE-C, HD+ →
    /// BT.709. A fixed 709 default therefore MISLABELS untagged SD content (measured: an untagged
    /// 320×240 fixture through the passthrough path scored mean 46 SSIMULACRA2 vs 81 via the old
    /// BGRA path — saturated drift with white intact, the signage playbook's matrix trap, this time
    /// self-inflicted). Untagged HD+ still lands 709 — the brand-colour gate the playbook demands.
    /// `width`/`height` are the SOURCE dims: a downscale doesn't change the matrix of the values.
    static func colorProperties(from format: CMFormatDescription?,
                                width: Int, height: Int) -> [String: Any] {
        func ext(_ key: CFString, _ fallback: String) -> String {
            guard let format,
                  let v = CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
            else { return fallback }
            return v
        }
        let sd = height < 720 && width < 1280
        return [
            AVVideoColorPrimariesKey: ext(kCMFormatDescriptionExtension_ColorPrimaries,
                                          sd ? AVVideoColorPrimaries_SMPTE_C
                                             : AVVideoColorPrimaries_ITU_R_709_2),
            AVVideoTransferFunctionKey: ext(kCMFormatDescriptionExtension_TransferFunction,
                                            AVVideoTransferFunction_ITU_R_709_2),
            AVVideoYCbCrMatrixKey: ext(kCMFormatDescriptionExtension_YCbCrMatrix,
                                       sd ? AVVideoYCbCrMatrix_ITU_R_601_4
                                          : AVVideoYCbCrMatrix_ITU_R_709_2),
        ]
    }

    /// Render the near-lossless downscale MEZZANINE: per-frame Lanczos (CoreImage) to the target
    /// resolution, encoded at the (generous) ceiling bitrate, audio passthrough-muxed. This is the
    /// scoring reference AND the search input for a downscale — the writer's own scaler aliases
    /// texture (measured p10 38.6 vs 61.7 on the upscale-to-source leg at equal near-lossless
    /// bitrate; see `encode`) and must never touch quality-gated pixels.
    /// Measure how much a conservative temporal denoise (VTTemporalNoiseFilter @ 0.1) would change
    /// this clip: the NOISE PROBE behind the camera-class self-gate. Returns the mean per-frame
    /// SSIMULACRA2 of denoised-vs-undenoised over a small sample (both sides run through the
    /// filter's compressed-format round trip, so conversion deltas cancel), or nil when the filter
    /// is unavailable (pre-macOS-26) or the clip can't be read. Calibration (2026-08-10, corpus):
    /// clean production footage measures 95.9–99.5 (the filter no-ops); genuine handheld grain
    /// measures ~65 — a ~30-point chasm. Callers gate at < 90 → camera-noisy.
    public static func noiseProbe(input: URL, sampleFrames: Int = 30) async -> Double? {
        guard #available(macOS 26.0, *) else { return nil }
        return await TemporalDenoise.probe(input: input, sampleFrames: sampleFrames)
    }

    /// True when the format's transfer function is HDR (HLG or PQ) — the tone-map trigger.
    static func isHDRTransfer(_ format: CMFormatDescription?) -> Bool {
        guard let format,
              let v = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        else { return false }
        return v == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
            || v == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
    }

    public static func renderDownscaleMezzanine(input: URL, output: URL, bitrate: Int,
                                                outWidth: Int, outHeight: Int,
                                                codec: AVVideoCodecType,
                                                lookAhead: Int? = nil,
                                                toneMapSDR: Bool = false,
                                                denoiseStrength: Float? = nil) async throws {
        let asset = AVURLAsset(url: input)
        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw EncodeError.noVideoTrack
        }
        let size = try await vtrack.load(.naturalSize)
        let transform = try await vtrack.load(.preferredTransform)
        let atrack = try await asset.loadTracks(withMediaType: .audio).first
        let audioFormat = try await atrack?.load(.formatDescriptions).first
        let videoFormat = try await vtrack.load(.formatDescriptions).first
        // Tone-mapped output IS BT.709 — forcing the tags is the point; preserving the source's
        // HDR tags onto tone-mapped pixels would be the mislabel trap in reverse.
        let colorProperties: [String: Any] = toneMapSDR
            ? [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
               AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
               AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
            : Self.colorProperties(from: videoFormat,
                                   width: Int(abs(size.width).rounded()),
                                   height: Int(abs(size.height).rounded()))

        VTBreadcrumb.log("MEZZ-START codec=\(codec == .hevc ? "hevc" : "h264") \(outWidth)×\(outHeight) "
            + "br=\(bitrate) la=\(lookAhead.map(String.init) ?? "-") sdr=\(toneMapSDR) "
            + "denoise=\(denoiseStrength.map { String(format: "%.2f", $0) } ?? "-") src=\(input.lastPathComponent)")
        defer { VTBreadcrumb.log("MEZZ-END src=\(input.lastPathComponent)") }

        let reader = try AVAssetReader(asset: asset)
        // BGRA decode for SDR sources (the mezzanine renders ONCE at near-lossless bitrate, so the
        // RGB trip's encoder-facing cost is negligible). HDR sources decode 10-bit biplanar so the
        // VTPixelTransferSession tone-map gets full depth + the HDR attachments.
        let decodeFormat: OSType = toneMapSDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA
        let videoOut = AVAssetReaderTrackOutput(
            track: vtrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: decodeFormat])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let atrack {
            let ao = AVAssetReaderTrackOutput(track: atrack, outputSettings: nil)   // passthrough
            ao.alwaysCopiesSampleData = false
            if reader.canAdd(ao) { reader.add(ao); audioOut = ao }
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        // 4 s keyframe cadence for BOTH codecs. H.264 measured 2026-08-08 (+4.5 p10, −3.2% bytes
        // vs default); HEVC measured 2026-08-09 (+1.8 p10, +6.7 min-frame — the key had simply
        // never been set on the HEVC path, an accidental gap the probe converted into a free win).
        compression[AVVideoMaxKeyFrameIntervalDurationKey] = 4
        if let lookAhead, #available(macOS 15.0, *) {
            compression[kVTCompressionPropertyKey_SuggestedLookAheadFrameCount as String] = lookAhead
        }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: outWidth, AVVideoHeightKey: outHeight,
            AVVideoColorPropertiesKey: colorProperties,
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        // The adaptor must be created before startWriting.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outWidth,
                kCVPixelBufferHeightKey as String: outHeight,
            ])
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                        sourceFormatHint: audioFormat)
            ai.expectsMediaDataInRealTime = false
            if writer.canAdd(ai) { writer.add(ai); audioIn = ai }
        }

        guard reader.startReading() else { throw EncodeError.readFailed }
        guard writer.startWriting() else { throw EncodeError.encodeFailed }
        writer.startSession(atSourceTime: .zero)

        // vImage Lanczos (default kernel) per frame, gamma-space, straight on the BGRA buffers.
        // Measured on the upscale-to-source leg at near-lossless bitrate (Sevilla 4K→1080):
        // writer's own scaler p10 38.6 (texture aliases; no bitrate buys it back) · CG .high 61.7 ·
        // CoreImage-Lanczos variants 56-58 (linear-light + colourspace hand-offs each cost points)
        // · **vImage default 67.8 — and ~6× faster than CG** (Lanczos5 flag measured equal-minus,
        // slower, ringier: 67.6). Vimeo's own COMPRESSED 1080 rung scores 63.9 on this leg — the
        // mezzanine now out-resolves the reference ladder it was chasing.
        func scaleFrame(_ src: CVPixelBuffer, into dst: CVPixelBuffer) {
            CVPixelBufferLockBaseAddress(src, .readOnly)
            CVPixelBufferLockBaseAddress(dst, [])
            defer {
                CVPixelBufferUnlockBaseAddress(src, .readOnly)
                CVPixelBufferUnlockBaseAddress(dst, [])
            }
            guard let sBase = CVPixelBufferGetBaseAddress(src),
                  let dBase = CVPixelBufferGetBaseAddress(dst) else { return }
            var sBuf = vImage_Buffer(data: sBase,
                                     height: vImagePixelCount(CVPixelBufferGetHeight(src)),
                                     width: vImagePixelCount(CVPixelBufferGetWidth(src)),
                                     rowBytes: CVPixelBufferGetBytesPerRow(src))
            var dBuf = vImage_Buffer(data: dBase,
                                     height: vImagePixelCount(CVPixelBufferGetHeight(dst)),
                                     width: vImagePixelCount(CVPixelBufferGetWidth(dst)),
                                     rowBytes: CVPixelBufferGetBytesPerRow(dst))
            _ = vImageScale_ARGB8888(&sBuf, &dBuf, nil, vImage_Flags(kvImageNoFlags))
        }

        // HDR → SDR: VTPixelTransferSession does the COLOUR work only (tone-map + matrix + depth
        // → BGRA 709 at SOURCE resolution — validated visually against Vimeo's own tone-map);
        // the measured-good vImage scaler still owns any resizing. Never let the transfer
        // session scale — its scaler is the writer-scale class that aliased texture.
        var transferSession: VTPixelTransferSession?
        var hdrScratch: CVPixelBuffer?
        if toneMapSDR {
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transferSession)
            if let session = transferSession {
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                                     value: kCVImageBufferColorPrimaries_ITU_R_709_2)
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
                                     value: kCVImageBufferTransferFunction_ITU_R_709_2)
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                                     value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            }
            let sw = Int(abs(size.width).rounded()), sh = Int(abs(size.height).rounded())
            if sw != outWidth || sh != outHeight {
                CVPixelBufferCreate(nil, sw, sh, kCVPixelFormatType_32BGRA, nil, &hdrScratch)
            }
        }

        // Denoise variant: an async manual pump (the callback pump cannot await the filter).
        // Stage order per frame: decode/tone-map → BGRA → compressed → TNF(window) → BGRA →
        // vImage scale (if downscaling) → append. The window carries ≤1 previous + ≤2 next.
        if let denoiseStrength, #available(macOS 26.0, *) {
            guard let dn = TemporalDenoise.Session(width: Int(abs(size.width).rounded()),
                                                   height: Int(abs(size.height).rounded()))
            else { throw EncodeError.encodeFailed }
            let srcW = Int(abs(size.width).rounded()), srcH = Int(abs(size.height).rounded())
            let scalingNeeded = srcW != outWidth || srcH != outHeight
            var scratch: CVPixelBuffer?
            if scalingNeeded {
                CVPixelBufferCreate(nil, srcW, srcH, kCVPixelFormatType_32BGRA, nil, &scratch)
            }
            // The HDR tone-map needs a source-res BGRA landing zone regardless of scaling.
            var hdrIntermediate: CVPixelBuffer?
            if transferSession != nil {
                CVPixelBufferCreate(nil, srcW, srcH, kCVPixelFormatType_32BGRA, nil, &hdrIntermediate)
            }

            func readCompressed() -> (pts: CMTime, buf: CVPixelBuffer)? {
                guard let s = videoOut.copyNextSampleBuffer(),
                      let raw = CMSampleBufferGetImageBuffer(s) else { return nil }
                let pts = CMSampleBufferGetPresentationTimeStamp(s)
                if let session = transferSession {
                    // HDR: tone-map to BGRA first, then into the filter's format.
                    guard let landing = hdrIntermediate,
                          VTPixelTransferSessionTransferImage(session, from: raw, to: landing) == noErr,
                          let comp = dn.compressed(from: landing) else { return nil }
                    return (pts, comp)
                }
                guard let comp = dn.compressed(from: raw) else { return nil }
                return (pts, comp)
            }

            var window: [(pts: CMTime, buf: CVPixelBuffer)] = []
            for _ in 0..<4 { if let f = readCompressed() { window.append(f) } }
            var cursor = 0
            while cursor < window.count {
                let current = window[cursor]
                let prev = cursor > 0 ? [window[cursor - 1]] : []
                let next = Array(window.suffix(from: min(cursor + 1, window.count)).prefix(2))
                guard let filtered = await dn.filter(current: current, previous: prev, next: next,
                                                     strength: denoiseStrength)
                else { throw EncodeError.encodeFailed }
                var pb: CVPixelBuffer?
                if let pool = adaptor.pixelBufferPool {
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                } else {
                    CVPixelBufferCreate(nil, outWidth, outHeight, kCVPixelFormatType_32BGRA, nil, &pb)
                }
                guard let pb else { throw EncodeError.encodeFailed }
                if scalingNeeded, let scratch {
                    guard dn.bgra(from: filtered, into: scratch) else { throw EncodeError.encodeFailed }
                    scaleFrame(scratch, into: pb)
                } else {
                    guard dn.bgra(from: filtered, into: pb) else { throw EncodeError.encodeFailed }
                }
                while !videoIn.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                adaptor.append(pb, withPresentationTime: current.pts)
                if cursor >= 1 { window.removeFirst() } else { cursor += 1 }
                if let f = readCompressed() { window.append(f) }
            }
            videoIn.markAsFinished()
            // Audio still pumps below via the callback path; fall through to the shared wait.
        }

        let group = DispatchGroup()
        if denoiseStrength == nil {
        group.enter()
        videoIn.requestMediaDataWhenReady(on: DispatchQueue(label: "vqt.mezz.video")) {
            while videoIn.isReadyForMoreMediaData {
                guard let s = videoOut.copyNextSampleBuffer() else {
                    videoIn.markAsFinished(); group.leave(); return
                }
                guard let src = CMSampleBufferGetImageBuffer(s) else { continue }
                var pb: CVPixelBuffer?
                if let pool = adaptor.pixelBufferPool {
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                } else {
                    CVPixelBufferCreate(nil, outWidth, outHeight, kCVPixelFormatType_32BGRA, nil, &pb)
                }
                guard let pb else { continue }
                if let session = transferSession {
                    if let scratch = hdrScratch {
                        // tone-map at source res, then vImage-scale to target
                        guard VTPixelTransferSessionTransferImage(session, from: src, to: scratch) == noErr
                        else { continue }
                        scaleFrame(scratch, into: pb)
                    } else {
                        // same-res: tone-map straight into the output buffer
                        guard VTPixelTransferSessionTransferImage(session, from: src, to: pb) == noErr
                        else { continue }
                    }
                } else {
                    scaleFrame(src, into: pb)
                }
                if !adaptor.append(pb, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(s)) {
                    FileHandle.standardError.write(Data("vqt: mezzanine append failed: \(String(describing: writer.error))\n".utf8))
                    videoIn.markAsFinished(); group.leave(); return
                }
            }
        }
        }   // end denoiseStrength == nil (callback video pump)
        if let audioIn, let audioOut {
            group.enter()
            audioIn.requestMediaDataWhenReady(on: DispatchQueue(label: "vqt.mezz.audio")) {
                while audioIn.isReadyForMoreMediaData {
                    if let s = audioOut.copyNextSampleBuffer() {
                        if !audioIn.append(s) { audioIn.markAsFinished(); group.leave(); return }
                    } else { audioIn.markAsFinished(); group.leave(); return }
                }
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.notify(queue: DispatchQueue(label: "vqt.mezz.done")) { cont.resume() }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw EncodeError.sourceAborted(reader.error)
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if writer.status == .failed { throw EncodeError.sourceAborted(writer.error) }
    }

    /// Transcode the video track to `codec` (HEVC default) at a target average bitrate;
    /// **passthrough-mux the audio** if present (no re-encode → no audio quality loss). No-audio
    /// sources produce a video-only output. `webSafeAudio` re-encodes non-AAC audio (Opus/FLAC/
    /// ALAC/PCM) to AAC-LC so the mp4 plays in every browser — AAC sources still passthrough.
    /// Colour primaries/transfer/matrix are preserved from the source (BT.709 default) for brand fidelity.
    /// `outWidth`/`outHeight` (when given) scale the video via VideoToolbox — the 4K→HD downscale lever.
    /// `maxQP`/`minQP` clamp the encoder's per-frame QP (see `EncodeProfile.maxAllowedQP`);
    /// `lookAhead` requests encoder lookahead frames (macOS 15+, skipped on 14).
    static func reencodeVideo(input: URL, output: URL, bitrate: Int,
                              outWidth: Int? = nil, outHeight: Int? = nil,
                              codec: AVVideoCodecType = .hevc,
                              webSafeAudio: Bool = false,
                              maxQP: Int? = nil, minQP: Int? = nil,
                              lookAhead: Int? = nil,
                              normalizeAudioAboveBPS: Int? = nil) async throws {
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
        // AAC (and no audio) is already web-safe → passthrough under `webSafeAudio`; anything else
        // is decoded to PCM by the reader and AAC-encoded by the writer. `normalizeAudioAboveBPS`
        // adds the Vimeo-parity audio rung: AAC whose measured rate exceeds the per-channel
        // threshold is re-encoded down to ~96k/ch too — a deliberate generation loss taken only
        // when the byte win is real (a 317k master → ~190k; at-or-below-web-rate AAC still
        // passthroughs untouched).
        let audioSubtype = audioFormat.map { CMFormatDescriptionGetMediaSubType($0) }
        var normalizeAAC = false
        if let normalizeAudioAboveBPS, webSafeAudio, let atrack,
           audioSubtype == kAudioFormatMPEG4AAC {
            let rate = Double((try? await atrack.load(.estimatedDataRate)) ?? 0)
            let asbd = audioFormat.flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            let channels = max(1, Int(asbd?.mChannelsPerFrame ?? 2))
            normalizeAAC = rate > Double(normalizeAudioAboveBPS * channels)
        }
        let transcodeAudioToAAC = webSafeAudio && atrack != nil
            && (audioSubtype != kAudioFormatMPEG4AAC || normalizeAAC)
        // Preserve the source's colour tags; default to BT.709 when untagged. Decoding to BGRA drops
        // the matrix, so an untagged re-encode can get misread as 601 → saturated brand colours drift
        // while white stays put (the signage-playbook colour-fidelity gate). Pin primaries/transfer/matrix.
        let videoFormat = try await vtrack.load(.formatDescriptions).first
        let colorProperties = Self.colorProperties(from: videoFormat,
                                                   width: Int(abs(size.width).rounded()),
                                                   height: Int(abs(size.height).rounded()))

        VTBreadcrumb.log("ENCODE-START codec=\(codec == .hevc ? "hevc" : "h264") \(w)×\(h) "
            + "br=\(bitrate) maxQP=\(maxQP.map(String.init) ?? "-") minQP=\(minQP.map(String.init) ?? "-") "
            + "la=\(lookAhead.map(String.init) ?? "-") src=\(input.lastPathComponent)")
        defer { VTBreadcrumb.log("ENCODE-END codec=\(codec == .hevc ? "hevc" : "h264") src=\(input.lastPathComponent)") }

        let reader = try AVAssetReader(asset: asset)
        // Decode to 4:2:0 biplanar VIDEO-RANGE, NOT BGRA. The BGRA round trip — 4:2:0 → RGB chroma
        // upsample → re-encode chroma downsample — measurably caps encode quality: Sevilla
        // 3240×1920 H.264 @ 17.8 Mbps scored p10 76.6 SSIMULACRA2 via BGRA vs 88.2 via biplanar,
        // and the ceiling is bitrate-independent (the search saturated at 76.8 at *source* bitrate,
        // honest-skipping floors the encoder could actually clear — 2026-08-09, the Vimeo-parity
        // investigation). Video-range unconditionally: the writer emits standard video-range
        // streams, and the reader range-converts a full-range source correctly during decode —
        // requesting the source's own full-range variant would instead hand the writer buffers
        // whose range handling is its (unverified) problem. 10-bit sources truncate to 8 here
        // exactly as BGRA did.
        let videoOut = AVAssetReaderTrackOutput(
            track: vtrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let atrack {
            // Passthrough reads the stored format (nil settings); an AAC transcode decodes to PCM here.
            let ao = AVAssetReaderTrackOutput(
                track: atrack,
                outputSettings: transcodeAudioToAAC ? [AVFormatIDKey: kAudioFormatLinearPCM] : nil)
            ao.alwaysCopiesSampleData = false
            if reader.canAdd(ao) { reader.add(ao); audioOut = ao }
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        // H.264 pins High profile / auto level — the universally-decodable web tier (Baseline is for
        // ancient devices and costs efficiency; VideoToolbox picks the level from the geometry) —
        // and a 4-second keyframe cadence, the web-streaming standard. Measured 2026-08-08 at a
        // fixed 900 kbps: GOP4s = +4.5 p10 SSIMULACRA2 AND −3.2% bytes vs the default cadence (the
        // default spends bits on needlessly frequent I-frames), so the floor search lands smaller
        // files at the same floor. CABAC was probed the same day: byte-identical — VideoToolbox
        // already uses it for High profile; don't add the key expecting a win.
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        // 4 s keyframe cadence for BOTH codecs. H.264 measured 2026-08-08 (+4.5 p10, −3.2% bytes
        // vs default); HEVC measured 2026-08-09 (+1.8 p10, +6.7 min-frame — the key had simply
        // never been set on the HEVC path, an accidental gap the probe converted into a free win).
        compression[AVVideoMaxKeyFrameIntervalDurationKey] = 4
        // QP corridor (see EncodeProfile.maxAllowedQP/minAllowedQP). AVVideoCompressionPropertiesKey
        // contents pass through to the VTCompressionSession, so the VT keys ride alongside the AV ones.
        if let maxQP {
            compression[kVTCompressionPropertyKey_MaxAllowedFrameQP as String] = maxQP
        }
        if let minQP {
            compression[kVTCompressionPropertyKey_MinAllowedFrameQP as String] = minQP
        }
        if let lookAhead, #available(macOS 15.0, *) {
            compression[kVTCompressionPropertyKey_SuggestedLookAheadFrameCount as String] = lookAhead
        }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: colorProperties,
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let ai: AVAssetWriterInput
            if transcodeAudioToAAC {
                // AAC-LC at the source's rate (capped at 48 kHz) and channel count. No
                // `sourceFormatHint` — the input receives decoded PCM, not the stored format.
                let asbd = audioFormat.flatMap {
                    CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
                }
                let srcRate = (asbd?.mSampleRate ?? 0) > 0 ? asbd!.mSampleRate : 48_000
                let channels = min(8, max(1, Int(asbd?.mChannelsPerFrame ?? 2)))
                ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: min(48_000, srcRate),
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: min(96_000 * channels, 384_000),
                ])
            } else {
                ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,     // passthrough mux
                                        sourceFormatHint: audioFormat)
            }
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
