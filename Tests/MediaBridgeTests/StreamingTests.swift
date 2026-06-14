import XCTest
import AVFoundation
@testable import MediaBridge

/// Exercises the streaming decode→encode reorder window with a clip longer than the window (32),
/// with B-frames. This is also a correctness proof: AVAssetWriter rejects out-of-order PTS, so a
/// passing run means the bounded-window reorder emits frames in strict display order.
final class StreamingTests: XCTestCase {

    private func tool(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] {
            let p = dir + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func testStreamingLongClipPreservesCountAndOrder() async throws {
        guard let ffmpeg = tool("ffmpeg"), let ffprobe = tool("ffprobe") else {
            throw XCTSkip("ffmpeg/ffprobe not installed")
        }
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).mkv")
        let dst = dir.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        // 60 frames (> 32-frame reorder window), H.264 with B-frames (forces decode-order ≠ display).
        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=2.5",
                         "-c:v", "libx264", "-bf", "3", "-pix_fmt", "yuv420p", src.path])

        let result = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
        XCTAssertEqual(result.frameCount, 60, "every frame streamed through, none dropped/duplicated")

        let outFrames = Int(try run(ffprobe, ["-v", "error", "-select_streams", "v:0",
            "-count_packets", "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", dst.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        XCTAssertEqual(outFrames, 60)

        let vt = try await AVURLAsset(url: dst).load(.tracks).filter { $0.mediaType == .video }
        XCTAssertEqual(vt.count, 1)
    }
}
