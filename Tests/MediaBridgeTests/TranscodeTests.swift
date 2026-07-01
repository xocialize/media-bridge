import XCTest
import AVFoundation
@testable import MediaBridge

/// The headline Phase-2 milestone: a real MKV → native HEVC mp4 normalizer, end to end
/// (demux → native decode → native HEVC encode), verified with ffprobe. Skips without ffmpeg.
final class TranscodeTests: XCTestCase {

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

    func testNormalizeMKVtoHEVC() async throws {
        guard let ffmpeg = tool("ffmpeg"), let ffprobe = tool("ffprobe") else {
            throw XCTSkip("ffmpeg/ffprobe not installed")
        }
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).mkv")
        let dst = dir.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=0.5",
                         "-c:v", "libx264", "-pix_fmt", "yuv420p", src.path])

        let result = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
        XCTAssertEqual(result.sourceCodecID, "V_MPEG4/ISO/AVC")
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.height, 240)
        XCTAssertEqual(result.frameCount, 12)

        // Output is a real, native HEVC mp4.
        let codec = try run(ffprobe, ["-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name,width,height", "-of", "csv=p=0", dst.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(codec, "hevc,320,240")

        let outFrames = Int(try run(ffprobe, ["-v", "error", "-select_streams", "v:0",
            "-count_packets", "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", dst.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        XCTAssertEqual(outFrames, 12)

        // And AVFoundation (Apple-native) opens it.
        let asset = AVURLAsset(url: dst)
        let vtracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(vtracks.count, 1)
    }

    /// VP9 and VP8 both stay deferred — no native VideoToolbox decoder on Apple Silicon (VP9 verified:
    /// VTDecompressionSessionCreate → kVTCouldNotFindVideoDecoderErr). The demux succeeds; decode is
    /// surfaced as `.deferredCodec`, never silently failed. Permissive libvpx (BSD) is the future path.
    func testNonNativeVideoCodecsDefer() async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        for (encoder, expectedID) in [("libvpx-vp9", "V_VP9"), ("libvpx", "V_VP8")] {
            let dir = FileManager.default.temporaryDirectory
            let src = dir.appendingPathComponent("\(UUID().uuidString).webm")
            let dst = dir.appendingPathComponent("\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

            try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=24:duration=0.2",
                             "-c:v", encoder, "-deadline", "realtime", "-cpu-used", "8", src.path])
            do {
                _ = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
                XCTFail("\(expectedID) should be deferred, not normalized")
            } catch MediaBridge.NormalizeError.deferredCodec(let id) {
                XCTAssertEqual(id, expectedID)
            }
        }
    }
}
