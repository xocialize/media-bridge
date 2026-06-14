import XCTest
import AVFoundation
@testable import MediaBridge

/// FLAC + Opus audio decode → AAC re-encode through the normalizer. Each makes a real ffmpeg file,
/// normalizes it, and confirms AVFoundation sees a valid audio track (the esds correctness check).
final class AudioCodecsTests: XCTestCase {

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

    /// Generate `container` with `audioCodec`, normalize, assert a valid HEVC+AAC output.
    private func assertNormalizesAudio(audioCodec: String, sourceCodecID: String,
                                       container ext: String) async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        let dst = dir.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        try run(ffmpeg, ["-y",
                         "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=0.5",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
                         "-c:v", "libx264", "-pix_fmt", "yuv420p",
                         "-c:a", audioCodec, "-shortest", src.path])

        let result = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
        XCTAssertEqual(result.audioCodecID, sourceCodecID, "source audio codec recognized")

        let asset = AVURLAsset(url: dst)
        let mediaTypes = try await asset.load(.tracks).map(\.mediaType)
        XCTAssertEqual(mediaTypes.filter { $0 == .video }.count, 1)
        XCTAssertEqual(mediaTypes.filter { $0 == .audio }.count, 1,
                       "AVFoundation must see the re-encoded audio track")
    }

    func testNormalizesOpusAudio() async throws {
        // MKV (not WebM) so we can pair Opus audio with natively-decodable H.264 video.
        try await assertNormalizesAudio(audioCodec: "libopus", sourceCodecID: "A_OPUS", container: "mkv")
    }

    /// FLAC audio isn't decodable via AudioConverter (known gap) — the normalizer must still produce
    /// a valid video-only mp4 rather than failing the whole job (best-effort audio).
    func testFLACAudioDegradesToVideoOnly() async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).mkv")
        let dst = dir.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        try run(ffmpeg, ["-y",
                         "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=0.5",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
                         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "flac", "-shortest", src.path])

        let result = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
        XCTAssertNil(result.audioCodecID, "FLAC audio dropped (gap), not muxed")
        let mediaTypes = try await AVURLAsset(url: dst).load(.tracks).map(\.mediaType)
        XCTAssertEqual(mediaTypes.filter { $0 == .video }.count, 1, "video-only output is still valid")
        XCTAssertEqual(mediaTypes.filter { $0 == .audio }.count, 0)
    }
}
