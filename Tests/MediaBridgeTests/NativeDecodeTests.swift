import XCTest
import CoreMedia
import CoreVideo
@testable import MediaImport
import MatroskaDemux

/// End-to-end Phase-2 proof: demux a real ffmpeg MKV (matroska-swift) → build a CMFormatDescription
/// from its codecPrivate (FormatDescriptionFactory) → decode every packet through VideoToolbox
/// (VideoDecodeSession) → BGRA pixel buffers. Skips when ffmpeg/ffprobe aren't installed.
final class NativeDecodeTests: XCTestCase {

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

    func testDecodeRealH264MKV() throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=0.5",
                         "-c:v", "libx264", "-pix_fmt", "yuv420p", tmp.path])

        // Demux.
        let demuxer = MatroskaDemuxer(data: try Data(contentsOf: tmp))
        try demuxer.parseHeaders()
        let track = try XCTUnwrap(demuxer.tracks.first { $0.type == .video })
        let packets = try demuxer.readAllPackets()
            .filter { $0.trackNumber == track.number }
            .map { (data: $0.data, ptsNanos: $0.ptsNanos) }
        XCTAssertEqual(packets.count, 12)

        // Format description from codecPrivate.
        let fmt = try FormatDescriptionFactory.makeVideo(codecID: track.codecID,
                                                         codecPrivate: track.codecPrivate)
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        XCTAssertEqual(dims.width, 320)
        XCTAssertEqual(dims.height, 240)

        // Decode through VideoToolbox.
        let session = try VideoDecodeSession(formatDescription: fmt)
        let frames = try session.decode(packets)
        XCTAssertEqual(frames.count, 12, "every packet should decode to a frame")

        let first = try XCTUnwrap(frames.first)
        XCTAssertEqual(CVPixelBufferGetWidth(first.image), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(first.image), 240)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(first.image), kCVPixelFormatType_32BGRA)

        // PTS strictly non-decreasing after the reorder sort.
        let pts = frames.map(\.ptsNanos)
        XCTAssertEqual(pts, pts.sorted())
    }

    func testFormatDescriptionRejectsDeferredCodec() {
        XCTAssertThrowsError(try FormatDescriptionFactory.makeVideo(codecID: "V_VP9", codecPrivate: Data()))
    }
}
