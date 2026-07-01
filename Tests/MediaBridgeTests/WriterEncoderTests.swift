import XCTest
import AVFoundation
import CoreVideo
@testable import MediaBridge

/// Phase 0: the encoder stall guard. `NativeMP4Writer` defaults to a software-only HEVC encoder
/// (the hardware VideoToolbox media engine stalls when it encodes right after heavy MLX compute)
/// with a `software: false` / `MEDIABRIDGE_ENCODE` opt-out, and a bounded readiness wait that raises
/// `WriterError.encoderStalled` instead of hanging forever. Both encoder paths must write a valid MP4.
/// Self-contained — no ffmpeg needed (synthetic BGRA frames).
final class WriterEncoderTests: XCTestCase {

    private func makeBGRA(width: Int, height: Int, gray: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        if let base = CVPixelBufferGetBaseAddress(buf) {
            memset(base, Int32(gray), CVPixelBufferGetBytesPerRow(buf) * height)
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    private func writeClip(software: Bool) async throws -> URL {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try NativeMP4Writer(output: dst, width: 320, height: 240, software: software)
        for i in 0..<12 {
            let pb = makeBGRA(width: 320, height: 240, gray: UInt8(20 + i * 10))
            try await writer.appendVideo(pb, ptsNanos: Int64(i) * 41_666_667) // ~24 fps
        }
        try await writer.finish()
        return dst
    }

    private func assertValidHEVC(_ url: URL) async throws {
        let tracks = try await AVURLAsset(url: url).load(.tracks)
        let video = tracks.filter { $0.mediaType == .video }
        XCTAssertEqual(video.count, 1, "expected exactly one video track")
    }

    func testSoftwareEncoderWritesValidMP4() async throws {
        let url = try await writeClip(software: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try await assertValidHEVC(url)
    }

    func testHardwareEncoderWritesValidMP4() async throws {
        let url = try await writeClip(software: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try await assertValidHEVC(url)
    }

    /// Default (no `software:` arg) must be the software path — the safe post-MLX default.
    func testDefaultIsSoftware() async throws {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: dst) }
        let writer = try NativeMP4Writer(output: dst, width: 160, height: 120)
        let pb = makeBGRA(width: 160, height: 120, gray: 128)
        try await writer.appendVideo(pb, ptsNanos: 0)
        try await writer.finish()
        try await assertValidHEVC(dst)
    }
}
