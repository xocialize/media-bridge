import XCTest
@testable import MediaBridge

/// `normalizeVideoToHEVC` cannot preserve alpha — HEVC-in-mp4 has nowhere to put it, and
/// `AVVideoCodecType.hevcWithAlpha` writes only `.mov`. That is a real constraint, not a defect.
///
/// The defect was doing it **silently**: VP9-in-WebM keeps alpha as a second encoded stream inside
/// `BlockAdditional`, so decoding the base block yields a complete, plausible, fully opaque image and
/// nothing downstream could tell transparency had been thrown away. `sourceHasAlpha` is what makes it
/// detectable.
final class AlphaReportingTests: XCTestCase {

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

    /// Uses H.264, not VP9: the flag comes from the container's `AlphaMode`, so this asserts the
    /// reporting works without needing an external decoder registered.
    func testAlphaBearingSourceIsReported() async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).mkv")
        let dst = dir.appendingPathComponent("\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst)
        }
        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc2=s=160x120:r=10:d=1",
                         "-c:v", "libx264", "-pix_fmt", "yuv420p", src.path])

        let result = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
        XCTAssertEqual(result.sourceHasAlpha, false, "an opaque source must report false, not nil")
    }

    /// The native-container path does not probe for alpha, so it must report `nil` — an honest
    /// "unknown". Reporting `false` there would be a claim the code cannot substantiate.
    func testNativeContainerPathReportsUnknownAlpha() async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).mp4")
        let dst = dir.appendingPathComponent("\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst)
        }
        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc2=s=160x120:r=10:d=1",
                         "-c:v", "libx264", "-pix_fmt", "yuv420p", src.path])

        let result = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
        XCTAssertNil(result.sourceHasAlpha, "native path does not probe alpha — must be nil")
    }
}
