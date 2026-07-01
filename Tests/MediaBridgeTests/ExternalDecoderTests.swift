import XCTest
import AVFoundation
import CoreVideo
@testable import MediaBridge
@testable import MediaImport

/// The external-decoder seam: media-bridge hands a deferred codec off to a registered `ExternalVideoDecoder`
/// (which, in production, lives in a SEPARATE package carrying the binary — e.g. libvpx for VP9). This
/// test proves the hand-off + shared encode path end-to-end with a PURE-SWIFT fake decoder that emits
/// synthetic frames — no binary, no libvpx. Registered → VP9 normalizes; unregistered → VP9 defers.
final class ExternalDecoderTests: XCTestCase {

    /// A stand-in for the real (libvpx-backed) decoder: ignores the VP9 bitstream and emits one gray
    /// BGRA frame per packet, preserving PTS. Enough to exercise the seam without any decoder binary.
    struct FakeVP9Decoder: ExternalVideoDecoder {
        let width = 320, height = 240
        func canDecode(codecID: String) -> Bool { codecID == "V_VP9" }
        func decodeStreaming(codecID: String, codecPrivate: Data?,
                             packets: [(data: Data, ptsNanos: Int64)],
                             onFrame: (DecodedVideoFrame) async throws -> Void) async throws {
            for (i, pkt) in packets.enumerated() {
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &pb)
                let buf = pb!
                CVPixelBufferLockBaseAddress(buf, [])
                if let base = CVPixelBufferGetBaseAddress(buf) {
                    memset(base, Int32(20 + (i * 8) % 200), CVPixelBufferGetBytesPerRow(buf) * height)
                }
                CVPixelBufferUnlockBaseAddress(buf, [])
                try await onFrame(DecodedVideoFrame(image: buf, ptsNanos: pkt.ptsNanos))
            }
        }
    }

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

    func testRegisteredDecoderRescuesDeferredVP9() async throws {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).webm")
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst)
            MediaBridge.unregisterAllExternalDecoders()   // never leak global state into other tests
        }
        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=0.5",
                         "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8",
                         "-pix_fmt", "yuv420p", src.path])

        // 1) With nothing registered, VP9 defers (unchanged behavior).
        do {
            _ = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
            XCTFail("VP9 should defer before any decoder is registered")
        } catch MediaBridge.NormalizeError.deferredCodec(let id) {
            XCTAssertEqual(id, "V_VP9")
        }

        // 2) Register the (fake) external decoder → VP9 now normalizes through the full pipeline.
        MediaBridge.register(externalDecoder: FakeVP9Decoder())
        let result = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
        XCTAssertEqual(result.sourceCodecID, "V_VP9")
        XCTAssertGreaterThan(result.frameCount, 0, "external decoder produced frames")
        let types = try await AVURLAsset(url: dst).load(.tracks).map(\.mediaType)
        XCTAssertEqual(types.filter { $0 == .video }.count, 1, "handed-off frames → native HEVC track")

        // 3) After unregister, VP9 defers again — the seam is fully removable.
        MediaBridge.unregisterAllExternalDecoders()
        do {
            _ = try await MediaBridge.normalizeVideoToHEVC(input: src, output: dst)
            XCTFail("VP9 should defer again after unregister")
        } catch MediaBridge.NormalizeError.deferredCodec(let id) {
            XCTAssertEqual(id, "V_VP9")
        }
    }
}
