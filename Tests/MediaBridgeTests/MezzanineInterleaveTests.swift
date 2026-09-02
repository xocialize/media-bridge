import AVFoundation
import CoreVideo
import XCTest
@testable import MediaBridge
@testable import MediaImport
@testable import MediaMeasure

/// The denoise mezzanine's two-track interleave (AB-A-0055).
///
/// `renderDownscaleMezzanine(denoiseStrength:)` pumps VIDEO inline on the calling task because the
/// callback pump cannot `await` the temporal filter. It used to register the AUDIO pump only after
/// that loop finished — and `AVAssetWriter` throttles an input whose media time runs ahead of its
/// siblings, so on a clip WITH audio the video input went not-ready and waited on an audio input
/// that had never started. Permanent park at ~0% CPU: nothing checked `writer.status`, and the
/// 2 ms sleep is only a cancellation point if somebody cancels.
///
/// These tests are deadline-bounded on purpose. The regression they guard is a HANG, and a test
/// that reproduces a hang by hanging is not a test — it takes the suite down with it.
final class MezzanineInterleaveTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        super.tearDown()
    }

    private func scratchURL(_ ext: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("mezz-\(UUID().uuidString).\(ext)")
        scratch.append(u)
        return u
    }

    private struct DeadlineExceeded: Error, CustomStringConvertible {
        let seconds: Double
        var description: String { "did not return within \(seconds)s — the pump is wedged" }
    }

    /// Run `body`, failing with `DeadlineExceeded` rather than hanging the suite.
    private func withDeadline<T: Sendable>(
        _ seconds: Double, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DeadlineExceeded(seconds: seconds)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func tonePCM(rate: Double, seconds: Double) -> AudioDecodeSession.PCM {
        let frames = Int(rate * seconds)
        var data = Data(count: frames * 2)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { p[i] = Int16(16_000 * sin(2 * .pi * 440 * Double(i) / rate)) }
        }
        return AudioDecodeSession.PCM(data: data, sampleRate: rate, channels: 1)
    }

    /// A moving-gradient clip, optionally with an AAC track. Real pixel motion matters: a constant
    /// frame gives the temporal filter nothing to do and can change how fast the encoder drains.
    private func makeClip(seconds: Double, withAudio: Bool,
                          width: Int = 320, height: Int = 240) async throws -> URL {
        let url = scratchURL("mp4")
        let rate = 48_000.0
        let writer = try NativeMP4Writer(output: url, width: width, height: height,
                                         audioPCM: withAudio ? (sampleRate: rate, channels: 1) : nil)
        // Audio first, then `finishAudio()`, then video — the shape `NormalizeAudioTests.makeAVMP4`
        // uses, and the one `NativeMP4Writer.finishAudio()` documents. It works because
        // `AVAssetWriter` will buffer a bounded amount of media time on an input that runs ahead
        // of its siblings; past that bound it throttles. Measured here: audio-up-front is fine at
        // 6 s and stalls the fixture writer at 10 s. Keep these fixtures SHORT — the condition
        // under test lives in `renderDownscaleMezzanine` reading the file, not in writing it, so
        // there is nothing to gain from a long one.
        if withAudio {
            for chunk in try tonePCM(rate: rate, seconds: seconds).makeSampleBuffers() {
                try await writer.appendAudio(chunk)
            }
            writer.finishAudio()
        }
        let frames = max(1, Int((seconds * 25).rounded()))
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            let buffer = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let o = y * rowBytes + x * 4
                        p[o + 0] = UInt8((x &+ i &* 3) & 0xFF)          // B
                        p[o + 1] = UInt8((y &+ i &* 2) & 0xFF)          // G
                        p[o + 2] = UInt8(((x ^ y) &+ i) & 0xFF)         // R
                        p[o + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try await writer.appendVideo(buffer, ptsNanos: Int64(i) * 40_000_000)
        }
        try await writer.finish()
        return url
    }

    private func trackCount(_ url: URL, _ type: AVMediaType) async throws -> Int {
        try await AVURLAsset(url: url).loadTracks(withMediaType: type).count
    }

    // MARK: - The regression

    /// **The bug.** A clip WITH audio, rendered through the denoise branch, must return.
    /// Before the fix this never completed; the deadline turns that into a failure in seconds
    /// instead of a hung suite.
    func testDenoiseMezzanineWithAudioCompletes() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("temporal denoise needs macOS 26+") }
        let input = try await makeClip(seconds: 5, withAudio: true)
        let output = scratchURL("mp4")

        try await withDeadline(120) {
            try await VideoQualityTarget.renderDownscaleMezzanine(
                input: input, output: output, bitrate: 8_000_000,
                outWidth: 320, outHeight: 240, codec: .h264, denoiseStrength: 0.1)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let video = try await trackCount(output, .video)
        let audio = try await trackCount(output, .audio)
        XCTAssertEqual(video, 1, "the mezzanine lost its video track")
        XCTAssertEqual(audio, 1, "audio must be muxed through, not dropped to dodge the interleave")
    }

    /// The audio-less shape that always worked — the hoisted registration must not break it.
    func testDenoiseMezzanineWithoutAudioCompletes() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("temporal denoise needs macOS 26+") }
        let input = try await makeClip(seconds: 4, withAudio: false)
        let output = scratchURL("mp4")

        try await withDeadline(120) {
            try await VideoQualityTarget.renderDownscaleMezzanine(
                input: input, output: output, bitrate: 8_000_000,
                outWidth: 320, outHeight: 240, codec: .h264, denoiseStrength: 0.1)
        }
        let video = try await trackCount(output, .video)
        let audio = try await trackCount(output, .audio)
        XCTAssertEqual(video, 1)
        XCTAssertEqual(audio, 0)
    }

    /// The non-denoise callback path with audio — the hoist moved this registration too.
    func testPlainDownscaleMezzanineWithAudioCompletes() async throws {
        let input = try await makeClip(seconds: 4, withAudio: true)
        let output = scratchURL("mp4")

        try await withDeadline(120) {
            try await VideoQualityTarget.renderDownscaleMezzanine(
                input: input, output: output, bitrate: 8_000_000,
                outWidth: 160, outHeight: 120, codec: .h264)
        }
        let video = try await trackCount(output, .video)
        let audio = try await trackCount(output, .audio)
        XCTAssertEqual(video, 1)
        XCTAssertEqual(audio, 1)
    }

    /// Cancellation must unwind the inline pump promptly — the wedge's only escape before the fix
    /// was killing the process, so the cancellation path is part of the guarantee.
    func testDenoiseMezzanineHonoursCancellation() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("temporal denoise needs macOS 26+") }
        // 720p, not the 320×240 the other cases use: at that size the whole render finishes in a
        // couple of hundred milliseconds and there is nothing left to cancel. The bigger frame buys
        // seconds of in-flight work, so a cancel a quarter-second in reliably lands mid-pump.
        let input = try await makeClip(seconds: 5, withAudio: true, width: 1280, height: 720)
        let output = scratchURL("mp4")

        let started = Date()
        let task = Task {
            try await VideoQualityTarget.renderDownscaleMezzanine(
                input: input, output: output, bitrate: 20_000_000,
                outWidth: 1280, outHeight: 720, codec: .h264, denoiseStrength: 0.1)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()
        let cancelled = try await withDeadline(30) { () -> Bool in
            do { try await task.value; return false } catch { return true }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20,
                          "cancellation must unwind promptly, not run to completion")
        XCTAssertTrue(cancelled, "cancelling the search must unwind the inline pump")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "a cancelled mezzanine must not leave a partial file behind")
    }
}
