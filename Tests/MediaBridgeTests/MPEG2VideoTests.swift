import XCTest
import AVFoundation
@testable import MediaBridge

/// Phase D: MPEG-2 and MPEG-1 video decode natively via VideoToolbox's legacy decoder (verified present
/// on Apple Silicon / macOS 27, 2026-07-01 — unlike VP9). An MPEG-1/2 MKV normalizes to native HEVC.
/// Availability is machine-dependent, so a host without the decoder degrades to a clean `.deferredCodec`
/// (via the normalizer's session-create probe), never a crash. Skips without ffmpeg.
final class MPEG2VideoTests: XCTestCase {
    private func tool(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] {
            let p = dir + name; if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
    @discardableResult private func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func normalize(encoder: String, expectedID: String) async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mkv")
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=0.5",
                         "-c:v", encoder, "-pix_fmt", "yuv420p", src.path])
        do {
            let r = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
            XCTAssertEqual(r.sourceCodecID, expectedID)
            XCTAssertEqual(r.width, 320); XCTAssertEqual(r.height, 240)
            XCTAssertGreaterThan(r.frameCount, 0)
            let types = try await AVURLAsset(url: dst).load(.tracks).map(\.mediaType)
            XCTAssertEqual(types.filter { $0 == .video }.count, 1, "\(expectedID) → native HEVC")
        } catch MediaBridge.NormalizeError.deferredCodec(let id) {
            // Acceptable on a host lacking the legacy decoder — must be a clean deferral, not a crash.
            XCTAssertEqual(id, expectedID)
            throw XCTSkip("\(expectedID) decoder not present on this host (deferred cleanly)")
        }
    }

    func testMPEG2() async throws { try await normalize(encoder: "mpeg2video", expectedID: "V_MPEG2") }
    func testMPEG1() async throws { try await normalize(encoder: "mpeg1video", expectedID: "V_MPEG1") }
}
