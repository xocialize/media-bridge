import XCTest
import AVFoundation
import CryptoKit
@testable import MediaMeasure

/// Env-gated determinism probe for the VideoToolbox encode path.
///
/// Exists because a claim in `VideoQualityTarget` — "identical `reencodeVideo` inputs produce
/// identical bytes" — was found false on the 4K signage master (a ~48 B spread over 5 runs of one
/// unmodified binary, ~7 ppm of a 6.56 MB deliverable) while the 1080p clips were byte-identical.
/// This probe isolates the ENCODER from the search: it calls `reencodeVideo` directly at a fixed
/// bitrate N times, so a spread here cannot be a search-trajectory difference.
///
///   FORGE_CORPUS=/…/Corpus swift test --filter EncodeDeterminismTests
///
/// Knobs: `FORGE_DET_REPS` (default 3) · `FORGE_DET_BITRATE` (bps, pins one rate across sources) ·
/// `FORGE_DET_SOURCES` (`:`-separated paths, overrides the default set) · `FORGE_DET_HEVC=1` — see
/// the safety interlock on `testHEVCEncodeRepeatability` before setting that one.
///
/// It reports, per source, the byte spread AND a compressed-sample census — frame count, per-frame
/// sizes, and sync-sample (GOP) layout, all read back PASSTHROUGH with no decode. Those three
/// separate the outcomes that look alike in a byte diff:
///   · same frames, same GOP, a few sizes moved → QP dithering (tens of bytes)
///   · same frames, GOP MOVED                   → adaptive keyframe re-decision (megabytes)
///   · frame count differs                      → a silent drop, i.e. a real bug (asserted against)
///
/// WHAT IT FOUND (2026-08-16, M5 Max / 26A5406e — full write-up in PERFORMANCE-BASELINE §4.5,
/// AB-L-0049). Byte-stability is a property of the CLIP AND THE LOAD, not of resolution: the 4K
/// master is stream-identical 12/12 in isolation (its bench variance is load-induced), while
/// `aisc_sevilla_players` varies 5.3% alone at the same 3240×1920 as the byte-stable
/// `aisc_ferrari_speed` — and 19.2% at double the bitrate, via a GOP that moved (27 keyframes one
/// run, 22 the next). No source ever dropped a frame.
final class EncodeDeterminismTests: XCTestCase {

    private var corpus: URL? {
        guard let p = ProcessInfo.processInfo.environment["FORGE_CORPUS"], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    /// One encoded output, described well enough to localize a difference.
    private struct Census {
        var bytes: Int          // file size on disk
        var sha: String         // whole-file digest
        var frames: Int         // compressed video samples
        var frameSizes: [Int]   // per-sample byte lengths, in decode order
        var syncFrames: [Int]   // indices of IDR/sync samples — the GOP boundaries
        var videoBytes: Int     // sum of frameSizes
        var audioSamples: Int
    }

    /// Read back the compressed samples WITHOUT decoding (nil outputSettings = passthrough), so the
    /// census is cheap even at 4K and reflects exactly what the encoder emitted.
    private func census(of url: URL) async throws -> Census {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sha = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()

        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "det", code: 1)
        }
        let vout = AVAssetReaderTrackOutput(track: vtrack, outputSettings: nil)
        vout.alwaysCopiesSampleData = false
        reader.add(vout)
        var aout: AVAssetReaderTrackOutput?
        if let atrack = try await asset.loadTracks(withMediaType: .audio).first {
            let ao = AVAssetReaderTrackOutput(track: atrack, outputSettings: nil)
            ao.alwaysCopiesSampleData = false
            if reader.canAdd(ao) { reader.add(ao); aout = ao }
        }
        guard reader.startReading() else { throw NSError(domain: "det", code: 2) }

        var sizes: [Int] = []
        var syncs: [Int] = []
        while let s = vout.copyNextSampleBuffer() {
            // A sample with no attachments, or without `NotSync`, IS a sync sample (the attachment
            // is only present to mark NON-sync frames). That is the GOP boundary the 4 s cadence
            // key places — the thing to check when whole runs diverge by megabytes.
            let attach = (CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false)
                as? [[CFString: Any]])?.first
            let notSync = (attach?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            if !notSync { syncs.append(sizes.count) }
            sizes.append(CMSampleBufferGetTotalSampleSize(s))
        }
        var audio = 0
        if let aout { while let s = aout.copyNextSampleBuffer() { audio += CMSampleBufferGetNumSamples(s) } }
        reader.cancelReading()

        return Census(bytes: bytes, sha: String(sha.prefix(16)), frames: sizes.count,
                      frameSizes: sizes, syncFrames: syncs,
                      videoBytes: sizes.reduce(0, +), audioSamples: audio)
    }

    /// Encode `source` `reps` times at one fixed bitrate and report whether the bytes repeat.
    private func probe(_ source: URL, codec: AVVideoCodecType, reps: Int) async throws {
        let asset = AVURLAsset(url: source)
        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw XCTSkip("no video track in \(source.lastPathComponent)")
        }
        let sz = try await vtrack.load(.naturalSize)
        let w = Int(abs(sz.width).rounded()), h = Int(abs(sz.height).rounded())
        // Half the source rate: firmly inside the search's working range, so the encoder is doing
        // real rate-control work rather than sitting pinned at a QP rail.
        let srcRate = Double((try? await vtrack.load(.estimatedDataRate)) ?? 0)
        // `FORGE_DET_BITRATE` (bps) pins one rate across sources — the lever for testing whether
        // instability tracks rate-control PRESSURE rather than resolution.
        let bitrate = Int(ProcessInfo.processInfo.environment["FORGE_DET_BITRATE"] ?? "")
            ?? max(1_000_000, Int(srcRate / 2))
        let codecName = codec == .hevc ? "hevc" : "h264"

        var runs: [Census] = []
        for i in 0..<reps {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("det-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: out) }
            try await VideoQualityTarget.reencodeVideo(input: source, output: out, bitrate: bitrate,
                                                       codec: codec, webSafeAudio: true)
            runs.append(try await census(of: out))
            _ = i
        }

        let sizes = runs.map(\.bytes)
        let spread = (sizes.max() ?? 0) - (sizes.min() ?? 0)
        let frameCounts = Set(runs.map(\.frames))
        // ⚠️ NOT the whole-file sha: an mp4 embeds a creation timestamp, so AVAssetWriter products
        // never hash-repeat even when the ELEMENTARY STREAM is identical (AB-L-0013 #1 — measured
        // again here: every byte-identical source below still showed 3 distinct file digests).
        // The verdict is the encoder's own output: per-frame compressed sample sizes.
        let identical = Set(runs.map(\.frameSizes)).count == 1

        print("\n── \(source.lastPathComponent) · \(w)×\(h) · \(codecName) @ \(bitrate / 1000) kbps · \(reps) reps")
        print("   bytes:  \(sizes.map(String.init).joined(separator: ", "))")
        print(String(format: "   spread: %d B (%.1f ppm)  ·  file digests distinct: %d (expected — mp4 timestamps)  ·  %@",
                     spread, sizes.first.map { Double(spread) / Double($0) * 1e6 } ?? 0,
                     Set(runs.map(\.sha)).count,
                     (identical ? "STREAM-IDENTICAL" : "NONDETERMINISTIC") as NSString))
        print("   frames: \(runs.map { String($0.frames) }.joined(separator: ", "))"
              + "  ·  audio samples: \(Set(runs.map(\.audioSamples)).sorted().map(String.init).joined(separator: ","))")

        if frameCounts.count > 1 {
            // The one outcome that would mean a real bug rather than encoder jitter.
            print("   ⚠️ FRAME COUNT DIFFERS — silent drop, not rate-control jitter")
        } else if !identical, let base = runs.first {
            // Localize: which frames moved, and by how much.
            var differing: [(Int, [Int])] = []
            for idx in 0..<base.frames {
                let vals = runs.map { $0.frameSizes[idx] }
                if Set(vals).count > 1 { differing.append((idx, vals)) }
            }
            print("   video-sample bytes: \(runs.map { String($0.videoBytes) }.joined(separator: ", "))")
            print("   \(differing.count)/\(base.frames) frames differ in size"
                  + (differing.isEmpty ? " (container/metadata only)" : ""))
            // GOP census. A moved keyframe boundary re-predicts everything downstream, which is how
            // a run diverges by MEGABYTES rather than the tens of bytes pure rate-control jitter
            // costs — so this line distinguishes the two regimes.
            let gopSets = Set(runs.map(\.syncFrames))
            print("   keyframes/run: \(runs.map { String($0.syncFrames.count) }.joined(separator: ", "))"
                  + "  ·  GOP layouts distinct: \(gopSets.count)"
                  + (gopSets.count == 1 ? " (IDENTICAL — pure rate-control jitter)"
                                        : " ⚠️ KEYFRAME PLACEMENT MOVED"))
            if gopSets.count > 1, let b = runs.first?.syncFrames {
                for (n, r) in runs.enumerated() where r.syncFrames != b {
                    let firstDiff = (0..<min(b.count, r.syncFrames.count))
                        .first { b[$0] != r.syncFrames[$0] }
                    print("      run \(n): \(r.syncFrames.count) keyframes, first divergence at GOP #"
                          + (firstDiff.map { "\($0) (\(b[$0]) vs \(r.syncFrames[$0]))" } ?? "— (length only)"))
                }
            }
            for (idx, vals) in differing.prefix(12) {
                print("      frame \(idx): \(vals.map(String.init).joined(separator: ", "))")
            }
            if differing.count > 12 { print("      … \(differing.count - 12) more") }
        }

        // The probe CHARACTERIZES; it does not assert byte equality — that is the premise under
        // test. The only hard failure is a frame-count difference, which no amount of encoder
        // nondeterminism explains.
        XCTAssertEqual(frameCounts.count, 1,
                       "\(source.lastPathComponent) \(codecName): frame count varied across runs — frames are being dropped")
    }

    private func sources() throws -> [URL] {
        if let override = ProcessInfo.processInfo.environment["FORGE_DET_SOURCES"], !override.isEmpty {
            return override.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        guard let corpus else { throw XCTSkip("FORGE_CORPUS unset — determinism probe skipped") }
        let signage = corpus.appendingPathComponent("video/signage", isDirectory: true)
        let pairs = corpus.appendingPathComponent("video/IBM_Pairs", isDirectory: true)
        // The comparison that answers "4K or this clip?": the offender, the SAME CONTENT at 1080p,
        // a known-identical 1080p clip, and two unrelated 4K sources.
        let picks = [
            signage.appendingPathComponent("ibmplaycharacters_master.mp4"),
            signage.appendingPathComponent("ibmplaycharacters_1080p.mp4"),
            signage.appendingPathComponent("tp_layersb_1080p.mp4"),
            pairs.appendingPathComponent("aisc_ferrari_speed_v02_v1 (2160p).mp4"),
            pairs.appendingPathComponent("aisc_sevilla_players_v02_v1 (2160p).mp4"),
        ]
        return picks.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func testH264EncodeRepeatability() async throws {
        let srcs = try sources()
        guard !srcs.isEmpty else { throw XCTSkip("no probe sources found") }
        let reps = Int(ProcessInfo.processInfo.environment["FORGE_DET_REPS"] ?? "") ?? 3
        for s in srcs { try await probe(s, codec: .h264, reps: reps) }
    }

    /// ⚠️ OPT-IN, AND NOT MERELY SLOW. On macOS 26A5406e a VideoToolbox HEVC encode session hangs
    /// (`VTCompressionSessionEncodeFrame → FigSemaphoreWaitRelative`) and tearing the hung session
    /// down **kernel-panics dart-ave0**, 2-for-2 (FB114259303; LESSONS "The HEVC through-line").
    /// This arm therefore reboots the machine as its likely outcome on that build — the skip below
    /// is a safety interlock, not a convenience. Run it when a fixed beta lands, not before, and
    /// check `sw_vers -buildVersion` first.
    func testHEVCEncodeRepeatability() async throws {
        guard ProcessInfo.processInfo.environment["FORGE_DET_HEVC"] == "1" else {
            throw XCTSkip("FORGE_DET_HEVC unset — HEVC encode is quarantined: it hangs on 26A5406e and "
                          + "the hung-session teardown kernel-panics dart-ave0 (FB114259303)")
        }
        let srcs = try sources()
        guard !srcs.isEmpty else { throw XCTSkip("no probe sources found") }
        let reps = Int(ProcessInfo.processInfo.environment["FORGE_DET_REPS"] ?? "") ?? 3
        for s in srcs { try await probe(s, codec: .hevc, reps: reps) }
    }
}
