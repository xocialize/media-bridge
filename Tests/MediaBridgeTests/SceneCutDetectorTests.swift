import XCTest
import AVFoundation
import CoreGraphics
import CoreVideo
@testable import MediaMeasure

final class SceneCutDetectorTests: XCTestCase {
    private let gridCount = SceneCutDetector.gridWidth * SceneCutDetector.gridHeight

    /// Flat grid at `luma`, with tiny deterministic per-frame jitter so the MAD isn't degenerate zero.
    private func flat(_ luma: Double, jitterSeed: Int = 0) -> [Double] {
        var g = [Double](repeating: luma, count: gridCount)
        // ±0.5 deterministic jitter, varying by seed so consecutive frames differ slightly.
        for i in 0..<g.count {
            g[i] += Double((i &* 31 &+ jitterSeed &* 17) % 100) / 100.0 - 0.5
        }
        return g
    }

    private func feed(_ detector: SceneCutDetector, _ grids: [[Double]]) -> [SceneCutDecision?] {
        grids.map { detector.next(lumaGrid: $0) }
    }

    // MARK: - Streaming (causal)

    /// flat(A) → flat(B) step: exactly one cut, at the step transition.
    func testHardStepIsExactlyOneCut() {
        let det = SceneCutDetector()
        var grids: [[Double]] = (0..<30).map { flat(60, jitterSeed: $0) }
        grids += (0..<30).map { flat(180, jitterSeed: $0) }
        let out = feed(det, grids)

        XCTAssertNil(out[0], "first frame has no transition")
        let cutIndices = out.indices.filter { out[$0]?.isCut == true }
        XCTAssertEqual(cutIndices, [30], "the A→B step is the one and only cut")
    }

    /// A gradual luma ramp (dissolve-like) never fires — V1 is hard cuts only.
    func testRampIsNoCut() {
        let det = SceneCutDetector()
        // 2 luma units per frame, every frame — steady, so it IS the local distribution.
        let grids = (0..<80).map { flat(40 + Double($0) * 2, jitterSeed: $0) }
        let out = feed(det, grids)
        XCTAssertTrue(out.compactMap { $0 }.allSatisfy { !$0.isCut }, "a steady ramp is motion, not a cut")
    }

    /// Single-frame white flash (the anime hazard): the detector DOES fire — documented false positive —
    /// but the refractory gap collapses the in+out spike pair into ONE event, not two.
    func testFlashFrameFiresOnce() {
        let det = SceneCutDetector()
        var grids: [[Double]] = (0..<30).map { flat(60, jitterSeed: $0) }
        grids.append(flat(250))                                   // the flash
        grids += (0..<30).map { flat(60, jitterSeed: $0) }        // back to the same shot
        let out = feed(det, grids)
        let cutIndices = out.indices.filter { out[$0]?.isCut == true }
        XCTAssertEqual(cutIndices, [30], "flash-in fires (known hazard); flash-out is refractory-suppressed")
    }

    /// No cuts during warmup: the causal statistic needs `minHistory` transitions first.
    func testWarmupNeverFires() {
        let det = SceneCutDetector(options: .init(minHistory: 12))
        var grids: [[Double]] = (0..<5).map { flat(60, jitterSeed: $0) }
        grids += (0..<5).map { flat(200, jitterSeed: $0) }         // step INSIDE the warmup window
        let out = feed(det, grids)
        XCTAssertTrue(out.compactMap { $0 }.allSatisfy { !$0.isCut }, "warmup transitions are never cuts")
        XCTAssertTrue(out.compactMap { $0 }.allSatisfy { $0.threshold == .infinity })
    }

    /// A cut spike must not poison the rolling statistics: a second cut shortly after a first is still
    /// detected (if the first spike entered the window, the MAD would explode and mask it).
    func testCutSpikeDoesNotPoisonThreshold() {
        let det = SceneCutDetector()
        var grids: [[Double]] = (0..<20).map { flat(60, jitterSeed: $0) }
        grids += (0..<10).map { flat(150, jitterSeed: $0) }        // cut 1
        grids += (0..<10).map { flat(40, jitterSeed: $0) }         // cut 2, 10 frames later
        let out = feed(det, grids)
        let cutIndices = out.indices.filter { out[$0]?.isCut == true }
        XCTAssertEqual(cutIndices, [20, 30], "both cuts detected — the first spike was excluded from the window")
    }

    /// Deterministic: identical inputs → identical decisions.
    func testDeterministic() {
        var grids: [[Double]] = (0..<25).map { flat(70, jitterSeed: $0) }
        grids += (0..<25).map { flat(190, jitterSeed: $0) }
        let a = feed(SceneCutDetector(), grids)
        let b = feed(SceneCutDetector(), grids)
        XCTAssertEqual(a, b)
    }

    /// `reset()` forgets the previous frame: the next call reports no transition.
    func testResetForgetsHistory() {
        let det = SceneCutDetector()
        _ = feed(det, (0..<20).map { flat(60, jitterSeed: $0) })
        det.reset()
        XCTAssertNil(det.next(lumaGrid: flat(200)), "first frame after reset has no transition")
    }

    /// **The anime hazard, as measured on Frieren.** Limited animation draws on threes: two of every
    /// three transitions are near-zero duplicate frames and every third is a new drawing. That makes the
    /// delta distribution zero-inflated, which collapses the MAD — under `.medianAbsoluteDeviation` every
    /// new drawing reads as an outlier at any k. `.upperTail` tracks the motion mode instead and separates
    /// the cut from the drawing changes. Magnitudes here are the measured ones (drawings 12–42, cut ~97).
    func testLimitedAnimationDefeatsMADButNotUpperTail() {
        var deltas: [Double] = []
        for i in 0..<180 {
            deltas.append(i % 3 == 0 ? 12 + Double((i * 7) % 30) : 0.25)   // drawings on threes
        }
        deltas[150] = 97                                                   // the one real cut

        let mad = SceneCutDetector.causalCutTransitions(
            deltas: deltas, options: .init(k: 12, scale: .medianAbsoluteDeviation))
        let tail = SceneCutDetector.causalCutTransitions(
            deltas: deltas, options: .init(k: 2, scale: .upperTail))

        XCTAssertGreaterThan(mad.count, 10, "MAD degenerates: drawing changes flood the detector")
        XCTAssertEqual(tail, [150], "upperTail finds the cut and only the cut")
    }

    /// A global lighting change within one shot (subway car entering a tunnel — measured on Joker) is a
    /// documented false positive, not something the statistic can reject. Pinned so the behaviour is a
    /// known limit rather than a surprise.
    func testGlobalLightingTransitionIsAFalsePositive() {
        let det = SceneCutDetector()
        var grids: [[Double]] = (0..<30).map { flat(90, jitterSeed: $0) }
        grids += (0..<10).map { flat(4, jitterSeed: $0) }        // lights out, same shot
        grids += (0..<20).map { flat(90, jitterSeed: $0) }       // lights back, same framing
        let out = feed(det, grids)
        XCTAssertTrue(out.contains { $0?.isCut == true },
                      "documented limit: a whole-frame lighting change is indistinguishable from a cut")
    }

    // MARK: - Two-pass

    /// Two-pass on a step sequence: one cut at the step; the ramp neighbours of a single transition
    /// collapse to one local maximum.
    func testTwoPassStepAndLocalMaxima() {
        var deltas = [Double](repeating: 1.0, count: 30)
        deltas[15] = 80        // the cut spike
        deltas[16] = 12        // its ramp neighbour (still above a low threshold, but not a local max)
        XCTAssertEqual(SceneCutDetector.cutTransitions(deltas: deltas, k: 8), [15])
    }

    func testTwoPassRampIsNoCut() {
        // Constant-slope deltas: median ≈ every value, nothing is an outlier.
        let deltas = [Double](repeating: 2.0, count: 50)
        XCTAssertEqual(SceneCutDetector.cutTransitions(deltas: deltas, k: 8), [])
    }

    // MARK: - Luma grids

    /// CGImage and BGRA-pixel-buffer paths agree on solid-color frames (both BT.601 luma, 0…255).
    func testLumaGridPathsAgreeOnSolidColor() throws {
        func solidCG(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CGImage {
            var bytes = [UInt8](repeating: 0, count: 64 * 48 * 4)
            for p in stride(from: 0, to: bytes.count, by: 4) {
                bytes[p] = r; bytes[p + 1] = g; bytes[p + 2] = b; bytes[p + 3] = 255
            }
            let ctx = CGContext(data: &bytes, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
        func solidPB(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<48 { for x in 0..<64 {
                let p = y * bpr + x * 4
                base[p] = b; base[p + 1] = g; base[p + 2] = r; base[p + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            return buf
        }
        let fromCG = SceneCutDetector.lumaGrid(of: solidCG(200, 100, 50))
        let fromPB = try XCTUnwrap(SceneCutDetector.lumaGrid(of: solidPB(200, 100, 50)))
        XCTAssertEqual(fromCG.count, fromPB.count)
        for (a, b) in zip(fromCG, fromPB) {
            XCTAssertEqual(a, b, accuracy: 2.0, "CG and PB luma paths agree (small CG color-management slack)")
        }
        XCTAssertNil(SceneCutDetector.lumaGrid(of: {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb)
            return pb!
        }()), "non-BGRA buffers are refused, not misread")
    }

    // MARK: - Pipeline wiring (the reset actually fires)

    /// Two visually distinct shots spliced into one H.264 clip: scrolling gradients so within-shot deltas are
    /// steady (motion), with one hard cut between them.
    private func makeTwoShotClip(at url: URL, shotFrames: Int) throws {
        let w = 64, h = 48, fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<(2 * shotFrames) {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let p = base.assumingMemoryBound(to: UInt8.self)
                let bpr = CVPixelBufferGetBytesPerRow(buf)
                let shotB = i >= shotFrames
                for y in 0..<h { for x in 0..<w {
                    // Shot A: dark horizontal gradient scrolling right. Shot B: bright vertical, scrolling down.
                    let v = shotB ? UInt8(140 + ((y + i * 2) % 24) * 4) : UInt8(20 + ((x + i * 2) % 24) * 4)
                    let o = y * bpr + x * 4
                    p[o] = v; p[o + 1] = v; p[o + 2] = v; p[o + 3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
    }

    /// The pipeline wiring: with `sceneCut` on, the detected cut fires the processor's existing `reset()` —
    /// visible as one fewer measured transition (a shot start has no previous frame). With it off, the
    /// cross-shot transition is (wrongly) measured.
    func testConsistencyPipelineResetsAtDetectedCut() async throws {
        let inURL = FileManager.default.temporaryDirectory.appendingPathComponent("cut-in-\(UUID()).mp4")
        let onURL = FileManager.default.temporaryDirectory.appendingPathComponent("cut-on-\(UUID()).mp4")
        let offURL = FileManager.default.temporaryDirectory.appendingPathComponent("cut-off-\(UUID()).mp4")
        defer { for u in [inURL, onURL, offURL] { try? FileManager.default.removeItem(at: u) } }
        let shotFrames = 24                               // > warmup, so the causal detector is live at the cut
        try makeTwoShotClip(at: inURL, shotFrames: shotFrames)

        func run(_ sceneCut: SceneCutOptions?, to out: URL) async throws -> VideoMatteOutcome {
            try await VideoConsistencyPipeline.enhanceToVideo(
                input: inURL, output: out, sceneCut: sceneCut,
                enhance: { $0 },
                flow: { a, _ in DenseFlow(width: a.width, height: a.height,
                                          uv: [Float](repeating: 0, count: a.width * a.height * 2)) })
        }
        let on = try await run(.init(), to: onURL)
        let off = try await run(nil, to: offURL)

        XCTAssertEqual(on.framesWritten, 2 * shotFrames)
        let onT = try XCTUnwrap(on.stability?.transitions)
        let offT = try XCTUnwrap(off.stability?.transitions)
        XCTAssertEqual(offT, 2 * shotFrames - 1, "detector off: every transition measured, cut included")
        XCTAssertEqual(onT, 2 * shotFrames - 2, "detector on: exactly one reset fired, at the cut")
    }
}
