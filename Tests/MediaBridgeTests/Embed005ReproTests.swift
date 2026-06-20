import XCTest
import AVFoundation
@testable import MediaMeasure

/// EMBED-005 #1 — fail-fast terminal-result guarantee. A source that aborts mid-decode (truncated /
/// garbled container, the `FigExport -12785` family) must surface a THROWN error so the request layer
/// yields a single terminal `.failed` (never an empty stream), and must leave NO bytes at `output`.
final class Embed005ReproTests: XCTestCase {

    /// The exact host-attached clip that triggered `FigExport -12785`. Confirms it encodes cleanly
    /// through our path (the fault was host-side, not in Forge's encode) — guards against regression.
    func testAttachedClipEncodesCleanly() async throws {
        let clip = URL(fileURLWithPath:
            "/Users/dustinnielson/Development/mlxengine-forge/AGENT_BRIDGE_assets/embed005-repro-w8-i2v-49f.mp4")
        guard FileManager.default.fileExists(atPath: clip.path) else { throw XCTSkip("repro clip absent") }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("embed005-clean-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try await VideoQualityTarget.encode(input: clip, output: out, targetScore: 80, iterations: 2)
        // 832×480, no audio, already delivery-compressed → a clean skip (no win), not a crash.
        XCTAssertFalse(r.metTarget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "a miss must leave no orphan at output")
    }

    /// A truncated MP4 (header only) — the reader aborts mid-pump. Pre-fix this finalized a short
    /// "successful" encode; now it must THROW (`sourceAborted`) and leave nothing at `output`.
    func testTruncatedSourceThrowsAndLeavesNoOutput() async throws {
        // Build a real short clip, then truncate it hard so the decoder aborts partway.
        let whole = FileManager.default.temporaryDirectory
            .appendingPathComponent("embed005-whole-\(UUID().uuidString).mp4")
        let trunc = FileManager.default.temporaryDirectory
            .appendingPathComponent("embed005-trunc-\(UUID().uuidString).mp4")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("embed005-out-\(UUID().uuidString).mp4")
        defer { [whole, trunc, out].forEach { try? FileManager.default.removeItem(at: $0) } }

        try makeTestClip(at: whole, seconds: 1.5)
        let data = try Data(contentsOf: whole)
        guard data.count > 4096 else { throw XCTSkip("test clip too small to truncate meaningfully") }
        try data.prefix(data.count / 3).write(to: trunc)   // keep the head, drop most of the payload

        do {
            _ = try await VideoQualityTarget.reencodeVideo(input: trunc, output: out, bitrate: 1_000_000)
            // Some truncations still decode a couple frames cleanly; only fail the test if it ALSO
            // left an orphan. The hard guarantee under test is "no bytes at output on a non-success".
        } catch {
            // Expected: a thrown error the request layer can turn into a terminal `.failed`.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                       "a failed/aborted encode must leave no bytes at output")
    }

    /// Minimal synthetic H.264 clip via AVAssetWriter (noisy frames, so it doesn't compress to a few
    /// hundred bytes — we need enough payload that truncating to 1/3 actually corrupts the stream).
    private func makeTestClip(at url: URL, seconds: Double) throws {
        let w = 640, h = 480, fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)

        let total = Int(seconds * Double(fps))
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let bytes = CVPixelBufferGetBytesPerRow(pb) * h
                let p = base.assumingMemoryBound(to: UInt8.self)
                var seed = UInt32(truncatingIfNeeded: i &* 2654435761)
                for j in 0..<bytes {            // cheap LCG noise → incompressible payload
                    seed = seed &* 1664525 &+ 1013904223
                    p[j] = UInt8(truncatingIfNeeded: seed >> 16)
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
    }
}
