import XCTest
import AVFoundation
import CoreMedia
import VideoToolbox
@testable import MediaBridge

/// AV1 video decode (manual av1C format description) → HEVC normalize. AV1 HW decode is M3+, so the
/// test branches: where supported it must transcode; elsewhere it must report `.deferredCodec`.
final class AV1Tests: XCTestCase {

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

    func testNormalizeAV1MKV() async throws {
        guard let ffmpeg = tool("ffmpeg"), let ffprobe = tool("ffprobe") else {
            throw XCTSkip("ffmpeg/ffprobe not installed")
        }
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).mkv")
        let dst = dir.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=0.5",
                         "-c:v", "libsvtav1", "-preset", "12", "-crf", "50",
                         "-pix_fmt", "yuv420p", src.path])
        // Confirm ffmpeg actually produced AV1 (libsvtav1 must be available in this build).
        let srcCodec = try run(ffprobe, ["-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name", "-of", "csv=p=0", src.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(srcCodec == "av1", "ffmpeg has no AV1 encoder")

        if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) {
            let result = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
            XCTAssertEqual(result.sourceCodecID, "V_AV1")
            XCTAssertEqual(result.width, 320)
            XCTAssertEqual(result.height, 240)
            XCTAssertGreaterThan(result.frameCount, 0)

            let outCodec = try run(ffprobe, ["-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=codec_name,width,height", "-of", "csv=p=0", dst.path])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(outCodec, "hevc,320,240")
            let vt = try await AVURLAsset(url: dst).load(.tracks).filter { $0.mediaType == .video }
            XCTAssertEqual(vt.count, 1)
        } else {
            do {
                _ = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
                XCTFail("AV1 should be deferred without HW decode")
            } catch MediaBridge.NormalizeError.deferredCodec(let id) {
                XCTAssertEqual(id, "V_AV1")
            }
        }
    }
}
