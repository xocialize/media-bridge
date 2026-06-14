import XCTest
import AVFoundation
@testable import MediaBridge

/// The native-container fast path: AVFoundation-readable mp4/mov route through AVAssetExportSession
/// (passthrough when already HEVC, hardware transcode from H.264) instead of the demux→decode→encode
/// path. Skips without ffmpeg.
final class NativePassthroughTests: XCTestCase {

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

    private func makeAndNormalize(videoCodec: String, ext: String) async throws
        -> (result: MediaBridge.NormalizeResult, outCodec: String) {
        guard let ffmpeg = tool("ffmpeg"), let ffprobe = tool("ffprobe") else {
            throw XCTSkip("ffmpeg/ffprobe not installed")
        }
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        let dst = dir.appendingPathComponent("\(UUID().uuidString).mp4")
        // (deferred cleanup handled by caller via the returned paths is unnecessary — temp dir)
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=0.5",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
                         "-c:v", videoCodec, "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", src.path])

        let result = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
        let outCodec = try run(ffprobe, ["-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name,width,height", "-of", "csv=p=0", dst.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Output opens natively with both tracks.
        let types = try await AVURLAsset(url: dst).load(.tracks).map(\.mediaType)
        XCTAssertEqual(types.filter { $0 == .video }.count, 1)
        XCTAssertEqual(types.filter { $0 == .audio }.count, 1)
        return (result, outCodec)
    }

    func testNativeH264MP4Transcodes() async throws {
        let (result, outCodec) = try await makeAndNormalize(videoCodec: "libx264", ext: "mp4")
        XCTAssertEqual(result.sourceCodecID, "avc1", "source recognized as H.264 (native fast path)")
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(outCodec, "hevc,320,240", "transcoded to HEVC")
    }

    func testNativeHEVCMP4Passthrough() async throws {
        let (result, outCodec) = try await makeAndNormalize(videoCodec: "libx265", ext: "mp4")
        XCTAssertTrue(result.sourceCodecID == "hvc1" || result.sourceCodecID == "hev1",
                      "source recognized as HEVC; got \(result.sourceCodecID)")
        XCTAssertEqual(outCodec, "hevc,320,240", "passthrough kept HEVC")
    }
}
