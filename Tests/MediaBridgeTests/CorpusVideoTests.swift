import XCTest
import AVFoundation
@testable import MediaMeasure

/// Env-gated corpus harness (README convention). Point **`FORGE_CORPUS`** at the `Corpus/` folder and it
/// characterizes a video set through Forge's real optimize path; unset → every case **skips** (never fails),
/// so the committed suite stays synthetic + self-contained.
///
///   FORGE_CORPUS=/Users/.../mlxengine-forge/Corpus FORGE_PROFILE=1 swift test --filter CorpusVideoTests
///
/// `GeneratedVideo/` is our OWN Wan-family output (AI-generated i2v/v2v/s2v) — the content Forge actually
/// targets. The run answers: does Forge win or skip on diffusion output, and is the per-frame SSIMU2 p10
/// search well-behaved or noisy on temporally-inconsistent AI video (the anomaly flagged in EMBED-006)?
final class CorpusVideoTests: XCTestCase {

    private var corpus: URL? {
        guard let p = ProcessInfo.processInfo.environment["FORGE_CORPUS"], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    func testCharacterizeGeneratedVideo() async throws {
        guard let corpus else { throw XCTSkip("FORGE_CORPUS unset — corpus harness skipped") }
        let dir = corpus.appendingPathComponent("GeneratedVideo", isDirectory: true)
        let clips = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "mp4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let clips, !clips.isEmpty else { throw XCTSkip("no clips under \(dir.path)") }

        // Floor override (default Balanced ≥80). `FORGE_VIDEO_FLOOR=70` runs the Aggressive tier.
        let floor = Double(ProcessInfo.processInfo.environment["FORGE_VIDEO_FLOOR"] ?? "") ?? 80
        // Sampling: default = ADAPTIVE (encode targets ≥12 frames). `FORGE_VIDEO_STRIDE=N` forces a fixed
        // stride to compare against the old min-of-3 behaviour.
        let stride = Int(ProcessInfo.processInfo.environment["FORGE_VIDEO_STRIDE"] ?? "")

        print(String(format: "\nCORPUS GeneratedVideo — floor ≥%.0f, per-frame SSIMU2, 6 iters, %@",
                     floor, (stride.map { "stride \($0)" } ?? "adaptive sampling") as NSString))
        print(String(format: "%-34@ %11@ %6@ %5@ %8@ %7@ %9@",
                     "clip" as NSString, "WxH" as NSString, "dur" as NSString, "aud" as NSString,
                     "srcMbps" as NSString, "result" as NSString, "p10/saved" as NSString))
        print(String(repeating: "─", count: 92))

        for clip in clips {
            let asset = AVURLAsset(url: clip)
            let vtrack = try await asset.loadTracks(withMediaType: .video).first
            let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
            let sz = vtrack != nil ? try await vtrack!.load(.naturalSize) : .zero
            let dur = try await asset.load(.duration).seconds
            let inBytes = (try? clip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let srcMbps = dur > 0 ? Double(inBytes) * 8 / dur / 1e6 : 0

            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("corpus-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: out) }

            var resultCol = "", scoreCol = ""
            do {
                let r = try await VideoQualityTarget.encode(input: clip, output: out,
                                                            targetScore: floor, searchStride: stride)
                if r.metTarget && r.outputBytes < r.inputBytes {
                    resultCol = "WIN"
                    scoreCol = String(format: "%.1f/%.0f%%", r.score, r.savedFraction * 100)
                } else {
                    resultCol = "skip"
                    scoreCol = String(format: "%.1f", r.score)   // best achievable p10 < floor
                }
            } catch {
                resultCol = "FAIL"; scoreCol = "\(error)"
            }
            print(String(format: "%-34@ %5d×%-5d %5.1fs %5@ %7.1fM %7@ %9@",
                         clip.lastPathComponent as NSString, Int(sz.width), Int(sz.height), dur,
                         (hasAudio ? "y" : "—") as NSString, srcMbps, resultCol as NSString,
                         scoreCol as NSString))
        }
        print("")
    }
}
