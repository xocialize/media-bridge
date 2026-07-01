import XCTest
import AVFoundation
@testable import MediaBridge
@testable import MediaImport

/// Phase A: AC-3 / E-AC-3 / MPEG Layer II/III decode natively via AudioToolbox (no dependency). An
/// H.264+<audio> MKV normalizes to HEVC+AAC; the muxed audio track is verified with `asset.load(.tracks)`
/// (NOT ffprobe alone — ffprobe is too lenient and will name a track AVFoundation rejects). Skips
/// without ffmpeg.
final class AudioDecodeTests: XCTestCase {

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

    /// Build an H.264 + `audioCodec` MKV, normalize, and assert AVFoundation opens both tracks.
    private func normalizeWithAudio(_ audioCodec: String) async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).mkv")
        let dst = dir.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=0.5",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
                         "-c:v", "libx264", "-pix_fmt", "yuv420p",
                         "-c:a", audioCodec, "-shortest", src.path])

        let result = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
        XCTAssertEqual(result.width, 320)
        XCTAssertGreaterThan(result.frameCount, 0)

        // The robust check: AVFoundation opens BOTH tracks (ffprobe is too lenient — see rebuild notes).
        let types = try await AVURLAsset(url: dst).load(.tracks).map(\.mediaType)
        XCTAssertEqual(types.filter { $0 == .video }.count, 1, "\(audioCodec): one video track")
        XCTAssertEqual(types.filter { $0 == .audio }.count, 1,
                       "\(audioCodec): audio decoded + muxed (result.audioCodecID=\(result.audioCodecID ?? "nil"))")
    }

    func testAC3() async throws { try await normalizeWithAudio("ac3") }
    func testEAC3() async throws { try await normalizeWithAudio("eac3") }
    func testMP2() async throws { try await normalizeWithAudio("mp2") }
    func testMP3() async throws { try await normalizeWithAudio("libmp3lame") }

    /// Direct AudioConverter construction smoke-test: proves none of the new formats hit the FLAC-style
    /// 'bada' failure at AudioConverterNew (the risk flagged in the plan).
    func testAudioConverterConstructsForAllNewFormats() throws {
        for id in ["A_AC3", "A_EAC3", "A_MPEG/L1", "A_MPEG/L2", "A_MPEG/L3"] {
            XCTAssertTrue(AudioDecodeSession.isSupported(codecID: id), "\(id) supported")
            XCTAssertNoThrow(
                try AudioDecodeSession(codecID: id, codecPrivate: nil, sampleRate: 48_000, channels: 2),
                "\(id): AudioConverterNew must not fail (no 'bada')")
        }
    }
}
