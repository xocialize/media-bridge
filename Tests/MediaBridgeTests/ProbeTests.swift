import XCTest
@testable import MediaBridge

/// MediaBridge.probe vs ffprobe ground truth, for a native mp4 (AVAsset path) and an MKV (demuxer
/// path). Confirms the unified codec vocabulary + dims + native-decodability routing. Skips w/o ffmpeg.
final class ProbeTests: XCTestCase {

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

    func testProbeNativeMP4() async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: src) }
        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30:duration=0.5",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
                         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", src.path])

        let info = try await MediaBridge.probe(url: src)
        XCTAssertEqual(info.container, .mp4)
        XCTAssertEqual(info.durationSeconds, 0.5, accuracy: 0.1)
        let v = try XCTUnwrap(info.videoStreams.first)
        XCTAssertEqual(v.codecID, "V_MPEG4/ISO/AVC")    // avc1 → unified vocabulary
        XCTAssertEqual(v.width, 640); XCTAssertEqual(v.height, 360)
        XCTAssertEqual(v.frameRate, 30, accuracy: 0.5)
        XCTAssertTrue(v.nativelyDecodable)
        let a = try XCTUnwrap(info.audioStreams.first)
        XCTAssertEqual(a.codecID, "A_AAC")
        XCTAssertTrue(a.nativelyDecodable)
    }

    func testProbeMKVWithDeferredVideo() async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).webm")
        defer { try? FileManager.default.removeItem(at: src) }
        // VP9 in WebM: demuxer path, video is decode-deferred, audio Opus is native.
        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=0.25",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=0.25",
                         "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8",
                         "-c:a", "libopus", "-shortest", src.path])

        let info = try await MediaBridge.probe(url: src)
        XCTAssertEqual(info.container, .webm)
        let v = try XCTUnwrap(info.videoStreams.first)
        XCTAssertEqual(v.codecID, "V_VP9")
        XCTAssertEqual(v.width, 320)
        XCTAssertFalse(v.nativelyDecodable, "VP9 is decode-deferred")
        let a = try XCTUnwrap(info.audioStreams.first)
        XCTAssertEqual(a.codecID, "A_OPUS")
        XCTAssertTrue(a.nativelyDecodable, "Opus is native")
    }
}
