//
// VideoSecondaryFloorTests.swift — MediaBridgeTests
//
// The secondary-floor HARVEST (AB-A-0059): a second rendition at a weaker floor, taken from the
// candidate ladder the primary search already encoded and scored, instead of from a second search.
//
// Three properties carry the whole feature, and each is a place it could go quietly wrong:
//
//  1. **It is a real deliverable.** The candidate is a complete file — right dimensions, and the
//     source's AUDIO muxed in. A silent "WiFi rendition" would look correct in every byte count on
//     the receipt and be useless on the wall, which is exactly the failure a size assertion misses.
//  2. **It is only ever an ADDITION.** It must not perturb the primary: same delivery decision,
//     same score, same trajectory as the identical call without a secondary floor.
//  3. **It refuses rather than lies.** No candidate cleared it, or the harvest is not smaller than
//     what ships → nothing at `secondaryOutput`, including no survivor from a previous run.
//

import AVFoundation
import CoreVideo
import XCTest
@testable import MediaMeasure

final class VideoSecondaryFloorTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        super.tearDown()
    }

    private func scratchURL(_ ext: String) -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("secfloor-\(UUID().uuidString).\(ext)")
        scratch.append(u)
        return u
    }

    // MARK: - The case the ask is built on: the primary MISSES, the harvest ships

    /// A floor no candidate can reach, beside a floor most of them clear. This is the keynote row
    /// from AB-A-0059 — `floor 90 @ source` skipping while a floor-80 file was encoded, scored and
    /// deleted on the way — so it is the one that has to work.
    ///
    /// The floors are chosen RELATIVE to what a synthetic clip can do (95 unreachable at these
    /// bitrates, 40 reachable by anything) rather than at the product's real 90/80, because the
    /// absolute numbers are content-dependent and would make this a flaky assertion about a
    /// fixture instead of a claim about the mechanism.
    func testHarvestShipsWhenThePrimaryFloorIsUnreachable() async throws {
        let source = try await makeClip(seconds: 2.0, withAudio: true)
        let primary = scratchURL("mp4")
        let secondary = scratchURL("mp4")

        let r = try await VideoQualityTarget.encode(
            input: source, output: primary, targetScore: 95, iterations: 4,
            secondaryFloor: 40, secondaryOutput: secondary)

        XCTAssertFalse(r.delivered, "fixture check: floor 95 must be out of reach here")
        XCTAssertFalse(FileManager.default.fileExists(atPath: primary.path),
                       "a floor miss leaves no primary — that is the whole point of the harvest")

        let harvest = try XCTUnwrap(r.secondary, "a candidate cleared 40 and must have been kept")
        XCTAssertGreaterThanOrEqual(harvest.score, 40, "the harvest must have actually cleared its floor")
        XCTAssertLessThan(harvest.score, 95, "a candidate that cleared 95 would have BEEN the primary")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondary.path))
        XCTAssertEqual(harvest.outputBytes, fileSize(secondary), "the receipt must describe the file on disk")
        XCTAssertLessThan(harvest.outputBytes, r.inputBytes,
                          "with no primary, the original is the incumbent — a harvest must beat it")

        // A rendition, not a byte count: it has to play.
        let asset = AVURLAsset(url: secondary)
        let vtracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(vtracks.count, 1)
        let size = try await XCTUnwrap(vtracks.first).load(.naturalSize)
        XCTAssertEqual(Int(abs(size.width).rounded()), harvest.width)
        XCTAssertEqual(Int(abs(size.height).rounded()), harvest.height)
        let atracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(atracks.count, 1,
                       "the source had audio — a silent rendition is a plausible-looking failure "
                       + "that no size or score assertion would catch")

        // Provenance, stated: the receipt names the search it fell out of, never a floor-40 search.
        XCTAssertEqual(harvest.floor, 40)
        XCTAssertEqual(harvest.searchFloor, 95)
        XCTAssertTrue(harvest.provenance.contains("harvested"), harvest.provenance)
    }

    /// The other row of AB-A-0059's table: the search CLEARS its floor and still hands back a
    /// smaller rendition — from the candidates it REJECTED on the way down, which are by
    /// construction the ones that scored below the primary floor.
    ///
    /// The spread between the two floors is wide on purpose. Bisection concentrates its probes
    /// around the floor it is chasing, so a secondary just under the primary may find nothing to
    /// harvest on a short clip; that thinning is a documented property of the mechanism
    /// (`Harvest`), not a defect, and a narrow-spread assertion here would be testing the fixture's
    /// luck rather than the feature.
    func testHarvestIsStrictlySmallerThanADeliveredPrimary() async throws {
        let source = try await makeClip(seconds: 2.0, withAudio: true)
        let primary = scratchURL("mp4")
        let secondary = scratchURL("mp4")

        let r = try await VideoQualityTarget.encode(
            input: source, output: primary, targetScore: 75, iterations: 5,
            secondaryFloor: 30, secondaryOutput: secondary)

        try XCTSkipUnless(r.delivered, "fixture check: this case needs a primary that shipped")
        let harvest = try XCTUnwrap(r.secondary, "candidates below the winner scored below 75 and above 30")
        XCTAssertLessThan(harvest.outputBytes, r.outputBytes,
                          "a rendition that is not smaller than the primary is not a rendition")
        XCTAssertGreaterThanOrEqual(harvest.score, 30)
        XCTAssertLessThan(harvest.score, r.score,
                          "a weaker floor buys a lower score — that is the trade being offered")
        XCTAssertEqual(harvest.outputBytes, fileSize(secondary))
        // Both files stand, independently playable, side by side. This is the deliverable shape:
        // an operator picks per cartridge, so neither may have consumed the other.
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path))
        let atracks = try await AVURLAsset(url: secondary).loadTracks(withMediaType: .audio)
        XCTAssertEqual(atracks.count, 1, "the smaller rung must carry audio too")
    }

    // MARK: - It is an addition, not a change

    /// The premise of "almost free" is that the search does not notice. Same clip, same floor, same
    /// iteration count, with and without a secondary: the primary's delivery decision and score
    /// must be identical. (Bytes are deliberately NOT asserted — VideoToolbox is timing-sensitive
    /// and byte-parity is an encoder property, not a pipeline property; see the ⚠️ in
    /// `VideoQualityTarget`'s speculation comment.)
    func testAskingForASecondaryDoesNotChangeThePrimary() async throws {
        let source = try await makeClip(seconds: 2.0, withAudio: false)

        let plainOut = scratchURL("mp4")
        let plain = try await VideoQualityTarget.encode(
            input: source, output: plainOut, targetScore: 60, iterations: 4)

        let withOut = scratchURL("mp4")
        let withSecondary = try await VideoQualityTarget.encode(
            input: source, output: withOut, targetScore: 60, iterations: 4,
            secondaryFloor: 30, secondaryOutput: scratchURL("mp4"))

        XCTAssertEqual(plain.delivered, withSecondary.delivered)
        XCTAssertEqual(plain.metTarget, withSecondary.metTarget)
        XCTAssertEqual(plain.bitrate, withSecondary.bitrate,
                       "the search trajectory must be untouched — the harvest only observes it")
        XCTAssertEqual(plain.score, withSecondary.score, accuracy: 0.001)
        XCTAssertNil(plain.secondary, "no floor asked for → nothing harvested")
    }

    // MARK: - Refusals leave nothing behind

    /// A floor nothing reaches must leave `secondaryOutput` EMPTY — and specifically must remove a
    /// file already sitting there. The Kit re-runs the search on the same URLs (hint over-reach,
    /// the class ratchet), so a stale rendition surviving a refusal would be silently re-adopted as
    /// this run's, carrying the previous run's floor claim.
    func testRefusalRemovesAStaleRenditionAtTheOutput() async throws {
        let source = try await makeClip(seconds: 1.5, withAudio: false)
        let secondary = scratchURL("mp4")
        try Data("a rendition from an earlier run".utf8).write(to: secondary)

        let r = try await VideoQualityTarget.encode(
            input: source, output: scratchURL("mp4"), targetScore: 60, iterations: 3,
            // Above the primary floor: every candidate that could clear it already IS the primary,
            // so the "strictly smaller than what ships" rule can only refuse.
            secondaryFloor: 99, secondaryOutput: secondary)

        XCTAssertNil(r.secondary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondary.path),
                       "a refused secondary must not leave the previous run's file in place")
    }

    /// `secondaryFloor` without `secondaryOutput` has nowhere to land: harvest nothing, report
    /// nothing, and above all do not fail the item over an incompletely-stated option.
    func testFloorWithoutAnOutputIsInert() async throws {
        let source = try await makeClip(seconds: 1.5, withAudio: false)
        let out = scratchURL("mp4")
        let r = try await VideoQualityTarget.encode(
            input: source, output: out, targetScore: 60, iterations: 3, secondaryFloor: 30)
        XCTAssertNil(r.secondary)
    }

    // MARK: - Fixture

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    /// A moving-gradient clip with a little high-frequency detail, optionally with an AAC tone.
    /// Smooth-but-not-flat on purpose: pure noise is incompressible (no floor is ever reachable and
    /// every candidate scores the same), while a constant frame compresses to nothing (every floor
    /// is reachable at the lowest bitrate) — either extreme collapses the candidate ladder the
    /// harvest is picked from.
    private func makeClip(seconds: Double, withAudio: Bool,
                          width: Int = 320, height: Int = 240) async throws -> URL {
        let url = scratchURL("mp4")
        let fps = 25
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
        ])
        vin.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(vin)

        var ain: AVAssetWriterInput?
        if withAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            ])
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            ain = a
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Audio first, then finish it: `AVAssetWriter` buffers a bounded amount of media time on an
        // input that runs ahead of its siblings, and at these lengths that bound is never reached.
        if let ain {
            for buf in try toneBuffers(seconds: seconds) {
                while !ain.isReadyForMoreMediaData { usleep(500) }
                ain.append(buf)
            }
            ain.markAsFinished()
        }

        for i in 0..<max(1, Int((seconds * Double(fps)).rounded())) {
            while !vin.isReadyForMoreMediaData { usleep(500) }
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
                        p[o + 0] = UInt8((x &+ i &* 3) & 0xFF)                    // B: smooth pan
                        p[o + 1] = UInt8((y &+ i &* 2) & 0xFF)                    // G: smooth pan
                        p[o + 2] = UInt8((((x &* y) >> 3) &+ i &* 5) & 0xFF)      // R: some detail
                        p[o + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i),
                                                                timescale: CMTimeScale(fps)))
        }
        vin.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        return url
    }

    /// 44.1 kHz mono sine, as CMSampleBuffers the AAC writer input accepts.
    private func toneBuffers(seconds: Double) throws -> [CMSampleBuffer] {
        let rate = 44_100.0, chunk = 4410
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        let fmt = try XCTUnwrap(format)

        var out: [CMSampleBuffer] = []
        var frame = 0
        let total = Int(rate * seconds)
        while frame < total {
            let n = min(chunk, total - frame)
            var samples = [Int16](repeating: 0, count: n)
            for i in 0..<n {
                samples[i] = Int16(12_000 * sin(2 * .pi * 440 * Double(frame + i) / rate))
            }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                               blockLength: n * 2, blockAllocator: kCFAllocatorDefault,
                                               customBlockSource: nil, offsetToData: 0,
                                               dataLength: n * 2, flags: 0, blockBufferOut: &block)
            let bb = try XCTUnwrap(block)
            _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!,
                                                                       blockBuffer: bb,
                                                                       offsetIntoDestination: 0,
                                                                       dataLength: n * 2) }
            var sb: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(rate)),
                decodeTimeStamp: .invalid)
            CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb,
                                      formatDescription: fmt, sampleCount: n,
                                      sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: [2],
                                      sampleBufferOut: &sb)
            out.append(try XCTUnwrap(sb))
            frame += n
        }
        return out
    }
}
