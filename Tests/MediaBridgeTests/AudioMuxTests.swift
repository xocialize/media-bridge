import XCTest
import AVFoundation
@testable import MediaBridge

/// Audio path: a Matroska with H.264 video + AAC audio normalizes to an mp4 with HEVC video and a
/// **passthrough-remuxed AAC** track (no audio re-encode). Verified with ffprobe. Skips w/o ffmpeg.
final class AudioMuxTests: XCTestCase {

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

    func testNormalizeMuxesAACAudio() async throws {
        guard let ffmpeg = tool("ffmpeg"), let ffprobe = tool("ffprobe") else {
            throw XCTSkip("ffmpeg/ffprobe not installed")
        }
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).mkv")
        let dst = dir.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        try run(ffmpeg, ["-y",
                         "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=0.5",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
                         "-c:v", "libx264", "-pix_fmt", "yuv420p",
                         "-c:a", "aac", "-shortest", src.path])

        let result = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
        XCTAssertEqual(result.audioCodecID, "A_AAC")

        // Output has two streams: HEVC video + AAC audio.
        let vCodec = try run(ffprobe, ["-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name", "-of", "csv=p=0", dst.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let aCodec = try run(ffprobe, ["-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name", "-of", "csv=p=0", dst.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(vCodec, "hevc")
        XCTAssertEqual(aCodec, "aac")

        // AVFoundation sees both tracks.
        let asset = AVURLAsset(url: dst)
        let allTracks = try await asset.load(.tracks)
        let mediaTypes = allTracks.map(\.mediaType)
        XCTAssertEqual(mediaTypes.filter { $0 == .video }.count, 1)
        XCTAssertEqual(mediaTypes.filter { $0 == .audio }.count, 1, "AVFoundation must see the audio track")
    }
}

// MARK: - Regression: interleaving deadlock (BRIDGE-048)

extension AudioMuxTests {

    /// A **realistically long** A/V Matroska must normalize. `testNormalizeMuxesAACAudio` above uses a
    /// 0.5 s / 12-frame fixture, which is small enough that `AVAssetWriter` never throttles — so it
    /// passed while any longer clip with audio deadlocked for 90 s and threw `encoderStalled`.
    ///
    /// The mechanism is not codec-specific: `AVAssetWriter` stops setting `isReadyForMoreMediaData` on
    /// an input whose media time has run far ahead of its siblings. Appending every video frame before
    /// the first audio sample makes video wait for audio while audio is queued behind video.
    ///
    /// Deliberately H.264 + AAC (the native decode path) rather than VP9 + Opus: the defect surfaced
    /// through the external-decoder path, and this proves it lives in the mux, not in vpx-swift.
    func testLongAudioVideoNormalizeDoesNotDeadlock() async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).mkv")
        let dst = dir.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        try run(ffmpeg, ["-y",
                         "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=3",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                         "-c:v", "libx264", "-pix_fmt", "yuv420p",
                         "-c:a", "aac", "-shortest", src.path])

        let result = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
        XCTAssertEqual(result.audioCodecID, "A_AAC")
        XCTAssertEqual(result.frameCount, 75, "all frames must reach the writer")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
    }
}
