import XCTest
import AVFoundation
import CoreVideo
@testable import MediaMeasure

/// `videoScorePTS` — presentation-time frame pairing for cross-encoder scoring. Frame-INDEX
/// pairing silently lies when two files disagree about time (a VFR capture vs its CFR transcode
/// drifts progressively; the IMG_3140 Vimeo pair measured p10 −14 by index while its frames were
/// visually fine). The fixtures here make the two pairings genuinely diverge: the same drifting
/// content written at 30 fps and, second file, every OTHER frame at 15 fps — index pairing
/// compares different moments, PTS pairing recovers the matching ones.
final class PTSScoringTests: XCTestCase {

    /// Draw frame content purely from the frame's TIME index so two writers can agree on content.
    private func frame(_ t: Int, w: Int, h: Int, into pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let o = y * rowBytes + x * 4
            p[o] = UInt8((x * 255 / w + t * 11) % 256)          // drifts fast with t
            p[o + 1] = UInt8((y * 255 / h + t * 7) % 256)
            p[o + 2] = UInt8(((x + y) * 255 / (w + h) + t * 13) % 256)
            p[o + 3] = 255
        } }
    }

    /// Write `timeIndices` as frames at the given per-frame duration (1/fps), HEVC near-lossless.
    private func writeClip(at url: URL, w: Int, h: Int, timeIndices: [Int], fps: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000]])
        vin.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vin,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(vin)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for (i, t) in timeIndices.enumerated() {
            while !vin.isReadyForMoreMediaData { usleep(1000) }
            var pb: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            } else {
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            }
            guard let pb else { continue }
            frame(t, w: w, h: h, into: pb)
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        vin.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
    }

    func testPTSPairingRecoversWhatIndexPairingLoses() throws {
        let tmp = FileManager.default.temporaryDirectory
        let full = tmp.appendingPathComponent("pts-full-\(UUID().uuidString).mov")
        let half = tmp.appendingPathComponent("pts-half-\(UUID().uuidString).mov")
        defer { [full, half].forEach { try? FileManager.default.removeItem(at: $0) } }
        // Same content timeline: full = t 0...59 at 30 fps; half = t 0,2,4,...58 at 15 fps.
        // PTS of half[i] = 2i/30 = PTS of full[2i], and content(t) matches by construction.
        try writeClip(at: full, w: 160, h: 120, timeIndices: Array(0..<60), fps: 30)
        try writeClip(at: half, w: 160, h: 120, timeIndices: Array(stride(from: 0, to: 60, by: 2)), fps: 15)

        let byIndex = try VideoQuality.videoScore(reference: full, distorted: half, sampleStride: 1)
        let byPTS = try VideoQuality.videoScorePTS(reference: full, distorted: half, sampleStride: 1)

        // Index pairing compares full[i] (content t=i) against half[i] (content t=2i) — different
        // moments almost everywhere; the fast-drifting pattern makes that a large penalty. PTS
        // pairing recovers the matched moments and must score dramatically higher.
        XCTAssertGreaterThan(byPTS.p10, byIndex.p10 + 20,
                             "PTS \(byPTS.p10) must beat index \(byIndex.p10) decisively")
        XCTAssertGreaterThan(byPTS.p10, 80, "matched moments are near-lossless encodes of the same pixels")
    }

    func testPTSAndIndexAgreeOnAlignedFiles() throws {
        let tmp = FileManager.default.temporaryDirectory
        let a = tmp.appendingPathComponent("pts-a-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: a) }
        try writeClip(at: a, w: 160, h: 120, timeIndices: Array(0..<30), fps: 30)
        let byIndex = try VideoQuality.videoScore(reference: a, distorted: a, sampleStride: 1)
        let byPTS = try VideoQuality.videoScorePTS(reference: a, distorted: a, sampleStride: 1)
        XCTAssertEqual(byIndex.p10, byPTS.p10, accuracy: 0.01,
                       "aligned files must score identically under either pairing")
    }
}
