import XCTest
import AVFoundation
import CoreVideo
@testable import MediaMeasure

/// The camera-noise self-gate's mechanism (macOS 26+): `noiseProbe` must separate temporal noise
/// from clean content decisively — corpus calibration measured clean at 95.9–99.5 and real grain
/// at ~65 (gate: < 90). These fixtures pin the separation synthetically: per-pixel LCG noise
/// (every frame independent — pure temporal noise) probes LOW; a smooth drifting gradient probes
/// HIGH. Skipped below macOS 26, where the probe honestly returns nil and callers stay on v1.
final class TemporalDenoiseTests: XCTestCase {

    private func makeClip(at url: URL, w: Int, h: Int, frames: Int, noise: Bool) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            // H.264, deliberately NOT HEVC: the fixture codec must be ORTHOGONAL to the subject
            // under test. Both 26A5388g "TNF stalls" and the 26A5406e one died right here — in an
            // HEVC fixture encode (EncodeFrame hang, FB114259303) — while TNF itself was clean at
            // every geometry probed. TNF decodes fixtures to BGRA; the codec is incidental.
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000]])
        vin.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vin,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(vin)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !vin.isReadyForMoreMediaData { usleep(1000) }
            var pb: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            } else {
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            }
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let rowBytes = CVPixelBufferGetBytesPerRow(pb)
                let p = base.assumingMemoryBound(to: UInt8.self)
                if noise {
                    var seed = UInt32(truncatingIfNeeded: i &* 2654435761 | 1)
                    for j in 0..<(rowBytes * h) {
                        seed = seed &* 1664525 &+ 1013904223
                        p[j] = UInt8(truncatingIfNeeded: seed >> 16)
                    }
                } else {
                    for y in 0..<h { for x in 0..<w {
                        let o = y * rowBytes + x * 4
                        p[o] = UInt8((x * 255 / w + i) % 256)
                        p[o + 1] = UInt8(y * 255 / h)
                        p[o + 2] = 128; p[o + 3] = 255
                    } }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        vin.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
    }

    /// TNF tests are OPT-IN (`MEDIABRIDGE_TNF_TESTS=1`): the first version of this suite entry
    /// stalled ~240 s per test and its retry HARD-LOCKED the machine (2026-08-10 — the per-frame
    /// strength-alternation storm, since removed). A bare `swift test` must never be able to
    /// wedge a machine; TNF coverage runs as a deliberately-armed probe with breadcrumbs
    /// (`MEDIABRIDGE_VT_LOG`) and an operator watching.
    ///
    /// The cost of opt-in is that a failure here is INVISIBLE to a bare `swift test` — the
    /// clean-vs-noisy separation below was broken and reported green until 2026-08-16. There is no
    /// CI in this repo to catch it, and there could not usefully be a hosted one: the filter needs
    /// macOS 26 on Apple silicon that VideoToolbox will actually give a TNF session to. So the
    /// backstop is a human running the line in the skip message before touching anything in
    /// `TemporalDenoise` — which is why that message carries the whole command.
    private func requireTNFOptIn() throws {
        guard ProcessInfo.processInfo.environment["MEDIABRIDGE_TNF_TESTS"] == "1" else {
            throw XCTSkip("""
                TNF coverage SKIPPED (opt-in — see the header for why). This suite is the only \
                check on the noise probe's gate; run it before landing any TemporalDenoise change:
                  MEDIABRIDGE_TNF_TESTS=1 swift test --filter TemporalDenoiseTests
                """)
        }
    }

    func testNoiseProbeSeparatesNoiseFromClean() async throws {
        try requireTNFOptIn()
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("VTTemporalNoiseFilter needs macOS 26+")
        }
        let tmp = FileManager.default.temporaryDirectory
        let noisy = tmp.appendingPathComponent("tnf-noisy-\(UUID().uuidString).mov")
        let clean = tmp.appendingPathComponent("tnf-clean-\(UUID().uuidString).mov")
        defer { [noisy, clean].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeClip(at: noisy, w: 320, h: 240, frames: 30, noise: true)
        try makeClip(at: clean, w: 320, h: 240, frames: 30, noise: false)

        let noisyRaw = await VideoQualityTarget.noiseProbe(input: noisy)
        let cleanRaw = await VideoQualityTarget.noiseProbe(input: clean)
        let noisyProbe = try XCTUnwrap(noisyRaw)
        let cleanProbe = try XCTUnwrap(cleanRaw)
        // 90 is the SHIPPING gate, not a fixture-fitted number — it stays put. A clean reading of
        // ~82 here means the probe has regressed to scoring against the raw BGRA decode, which
        // charges the BGRA↔4:2:0-video-range conversion to the noise budget; the conversion is
        // worth ~16 points on this full-range-RGB fixture and the filter itself only ~1.3. See
        // `TemporalDenoise.probe`'s ⚠️. Corrected, this fixture reads ~92 and the corpus 95–98.
        XCTAssertLessThan(noisyProbe, 90, "pure temporal noise must gate as camera-noisy (got \(noisyProbe))")
        XCTAssertGreaterThan(cleanProbe, 90, "clean content must stay above the gate (got \(cleanProbe))")
        XCTAssertGreaterThan(cleanProbe - noisyProbe, 10,
                             "the separation must be decisive, not marginal")
    }

    func testDenoisedMezzanineDeliversThroughTheSearch() async throws {
        try requireTNFOptIn()
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("VTTemporalNoiseFilter needs macOS 26+")
        }
        let tmp = FileManager.default.temporaryDirectory
        let src = tmp.appendingPathComponent("tnf-src-\(UUID().uuidString).mov")
        let out = tmp.appendingPathComponent("tnf-out-\(UUID().uuidString).mp4")
        defer { [src, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeClip(at: src, w: 320, h: 240, frames: 30, noise: true)

        // Floor 70 vs the DENOISED mezzanine: on pure-noise content the denoised reference is
        // nearly static, so the floor becomes reachable at a tiny bitrate — the entire point of
        // the camera path (vs-raw-source this floor forces near-lossless noise reproduction).
        let r = try await VideoQualityTarget.encode(input: src, output: out, targetScore: 70,
                                                    iterations: 3, profile: .webH264,
                                                    denoiseStrength: 0.1)
        XCTAssertTrue(r.delivered, "the denoised-reference search must deliver")
        XCTAssertTrue(r.metTarget, "floor 70 vs the denoised mezzanine must be reachable on noise")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }
}
