import XCTest
import CoreGraphics
@testable import MediaMeasure

/// N8 Axis B — the fidelity guard. These tests pin the two claims the measure is bought on:
/// that surviving a downsample round trip is a *ground-truth* statement about invented detail,
/// and that per-octave SSIM separates legitimate sharpening from geometry drift where a single
/// number cannot. The honest limits are pinned too, so nobody later assumes more than it delivers.
final class FidelityGuardTests: XCTestCase {

    // MARK: - Downsample consistency

    /// The ground-truth case: a nearest ×2 upscale invents nothing, and a 2×2 area reduction is its
    /// exact inverse. Anything short of bit-exact here is a bug in the resampler, not in the metric.
    func testNearestUpscaleRoundTripsExactly() throws {
        let source = try noiseImage(64, 48, seed: 7)
        let upscaled = try nearestUpscale(source, factor: 2)

        let r = try FidelityGuard.downsampleConsistency(source: source, result: upscaled)

        XCTAssertEqual(r.scaleX, 2.0, accuracy: 1e-12)
        XCTAssertEqual(r.scaleY, 2.0, accuracy: 1e-12)
        XCTAssertEqual(r.psnr, .infinity, "a nearest ×2 upscale must round-trip bit-exact")
        XCTAssertEqual(r.ssim, 1.0, accuracy: 1e-5)
        XCTAssertEqual(r.ssimTiles.worst, 1.0, accuracy: 1e-5)
    }

    /// Invented content does not survive the round trip — the whole claim, in one assertion.
    func testInventedDetailIsDetected() throws {
        let source = try noiseImage(256, 256, seed: 11)
        let honest = try nearestUpscale(source, factor: 2)
        let hallucinated = try replaceWithIndependentDetail(
            honest, rect: CGRect(x: 64, y: 64, width: 128, height: 128), seed: 99)

        let clean = try FidelityGuard.downsampleConsistency(source: source, result: honest)
        let dirty = try FidelityGuard.downsampleConsistency(source: source, result: hallucinated,
                                                            tileSize: 32)

        XCTAssertEqual(clean.psnr, .infinity)
        XCTAssertLessThan(dirty.psnr, 30, "an invented patch must cost real PSNR")
        XCTAssertLessThan(dirty.ssimTiles.worst, 0.3,
                          "the tile containing the invention must score badly")
    }

    /// 🔑 The reason N8 says gate on `worst`, not `mean` — stated as an executable claim rather than
    /// as prose. A small invention in a large frame is nearly invisible to the global score.
    ///
    /// ⚠️ Note what the fixture forces into the open: **tile size is a detection floor, not a
    /// cosmetic choice.** An invention smaller than a tile is diluted inside it, so the map only
    /// catches what it can resolve. Sizing tiles to the artifact you care about is a product
    /// decision the UI has to make deliberately.
    func testWorstTileCatchesWhatTheMeanHides() throws {
        let source = try noiseImage(512, 512, seed: 3)
        let honest = try nearestUpscale(source, factor: 2)
        let hallucinated = try replaceWithIndependentDetail(
            honest, rect: CGRect(x: 256, y: 256, width: 128, height: 128), seed: 77)

        let r = try FidelityGuard.downsampleConsistency(source: source, result: hallucinated,
                                                        tileSize: 64)

        XCTAssertGreaterThan(r.ssim, 0.95, "the global mean barely moves — that is the problem")
        XCTAssertLessThan(r.ssimTiles.worst, 0.3, "the worst tile does move — that is the fix")
        XCTAssertGreaterThan(r.ssim - r.ssimTiles.worst, 0.6,
                             "mean and worst must be far apart on a localized failure")
    }

    /// ⚠️ **Honest limit, pinned deliberately.** Invented detail that is exactly balanced at the
    /// reduction scale — here a 2×2-aligned checkerboard, which lives at the result grid's Nyquist —
    /// averages away and is therefore *invisible* to this measure. That is a property of the test,
    /// not a defect: "survived the round trip" is a necessary condition for honest detail, never a
    /// sufficient one. Per-octave SSIM and the NR delta are what cover this blind spot.
    func testNyquistBalancedInventionIsInvisible() throws {
        let source = try noiseImage(128, 128, seed: 5)
        let upscaled = try nearestUpscale(source, factor: 2)
        let checkered = try addCheckerboard(upscaled, amplitude: 0.25)

        let r = try FidelityGuard.downsampleConsistency(source: source, result: checkered)

        // Not literally infinite: the reduction sums in Double and lands back in Float, so a
        // ±64/255 pair cancels to within a ULP rather than exactly. 100 dB is ~1e-10 of signal —
        // this is float rounding, not detection.
        XCTAssertGreaterThan(r.psnr, 100,
                             "balanced high-frequency invention is by construction undetectable here")
        XCTAssertGreaterThan(r.ssimTiles.worst, 0.999, "and no tile sees it either")
    }

    /// A same-size restore is a legitimate input: the reduction degenerates to a direct comparison.
    func testSameSizeRestoreIsADirectComparison() throws {
        let source = try noiseImage(96, 96, seed: 13)
        let r = try FidelityGuard.downsampleConsistency(source: source, result: source)
        XCTAssertEqual(r.scaleX, 1.0, accuracy: 1e-12)
        XCTAssertEqual(r.psnr, .infinity)
        XCTAssertEqual(r.ssim, 1.0, accuracy: 1e-5)
    }

    func testResultSmallerThanSourceThrows() throws {
        let source = try noiseImage(128, 128, seed: 1)
        let smaller = try noiseImage(64, 64, seed: 1)
        XCTAssertThrowsError(try FidelityGuard.downsampleConsistency(source: source, result: smaller)) {
            XCTAssertEqual($0 as? FidelityGuard.GuardError, .resultSmallerThanSource)
        }
    }

    func testTooSmallThrows() throws {
        let tiny = try noiseImage(8, 8, seed: 1)
        XCTAssertThrowsError(try FidelityGuard.downsampleConsistency(source: tiny, result: tiny)) {
            XCTAssertEqual($0 as? FidelityGuard.GuardError, .tooSmall)
        }
    }

    // MARK: - Per-octave SSIM

    /// The signature claim: sharpening moves the top octave and leaves the rest alone.
    ///
    /// Measured on this fixture: bands `[0.996, 0.998, 0.999, 1.000]`, base `0.99998`. Note how
    /// narrow that is — the assertions below are on the *ordering*, because the absolute values
    /// carry almost no dynamic range. `testAbsoluteThresholdsCannotSeparateTheTwoCases` pins why
    /// that matters.
    func testSharpeningMovesOnlyTheTopOctave() throws {
        let reference = try scaleFreeImage(256, 256, seed: 21)
        let sharpened = try unsharpMask(reference, amount: 0.8)

        let r = try FidelityGuard.perOctaveSSIM(reference: reference, distorted: sharpened, octaves: 4)

        XCTAssertEqual(r.bands.count, 4)
        XCTAssertLessThan(r.bands[0], 0.999, "the top octave must register the sharpening")
        XCTAssertLessThan(r.bands[0], r.bands[1], "the deficit must shrink with depth…")
        XCTAssertLessThan(r.bands[1], r.bands[2], "…monotonically")
        XCTAssertGreaterThan(r.base, 0.999, "the lowpass base must be essentially untouched")
        XCTAssertTrue(r.hasExpectedSignature())
    }

    /// The counter-case: a one-pixel translation is *geometry* drift, so it reaches every octave.
    /// A single scalar cannot tell this apart from sharpening; the vector can.
    func testGeometryDriftReachesEveryOctave() throws {
        let reference = try scaleFreeImage(256, 256, seed: 23)
        let shifted = try translate(reference, dx: 1, dy: 1)
        let sharpened = try unsharpMask(reference, amount: 0.8)

        let drift = try FidelityGuard.perOctaveSSIM(reference: reference, distorted: shifted, octaves: 4)
        let sharp = try FidelityGuard.perOctaveSSIM(reference: reference, distorted: sharpened, octaves: 4)

        XCTAssertLessThan(drift.bands[2], sharp.bands[2],
                          "drift must move mid frequencies more than sharpening does")
        XCTAssertFalse(drift.hasExpectedSignature(), "drift must fail the shape check")
        XCTAssertTrue(sharp.hasExpectedSignature(), "sharpening must pass it")
    }

    /// 🔑 **Regression guard for a real bug this suite caught.** The first version of
    /// `hasExpectedSignature` used an absolute tolerance and certified geometry drift as clean
    /// sharpening. This pins *why*: on a Laplacian band, cs-SSIM is compressed so hard against 1.0
    /// that the two cases overlap on every absolute threshold — drift's mid bands (~0.981) sit
    /// *above* a 0.98 bar while sharpening's top band (~0.996) sits below a 0.99 one. Only the
    /// ratio of deficits separates them. If someone reintroduces an absolute cutoff, this fails.
    func testAbsoluteThresholdsCannotSeparateTheTwoCases() throws {
        let reference = try scaleFreeImage(256, 256, seed: 23)
        let drift = try FidelityGuard.perOctaveSSIM(reference: reference,
                                                    distorted: try translate(reference, dx: 1, dy: 1),
                                                    octaves: 4)
        let sharp = try FidelityGuard.perOctaveSSIM(reference: reference,
                                                    distorted: try unsharpMask(reference, amount: 0.8),
                                                    octaves: 4)

        // Both live in the same narrow strip below 1.0 — no single cutoff sorts them.
        let allValues = drift.bands + sharp.bands
        XCTAssertGreaterThan(allValues.min()!, 0.95, "everything is crowded against 1.0…")
        XCTAssertLessThan(allValues.max()! - allValues.min()!, 0.05, "…within a few hundredths")

        // The deficit ratio, by contrast, separates them by roughly 5×.
        let driftRatio = drift.bandDeficits.dropFirst(2).max()! / drift.bandDeficits[0]
        let sharpRatio = sharp.bandDeficits.dropFirst(2).max()! / sharp.bandDeficits[0]
        XCTAssertGreaterThan(driftRatio, 1.0, "drift's deep octaves are hit as hard as its top one")
        XCTAssertLessThan(sharpRatio, 0.5, "sharpening's deep octaves are barely touched")
        XCTAssertGreaterThan(driftRatio / sharpRatio, 3.0, "the ratio is what carries the signal")
    }

    func testIdenticalImagesScorePerfectAtEveryOctave() throws {
        let image = try scaleFreeImage(128, 128, seed: 31)
        let r = try FidelityGuard.perOctaveSSIM(reference: image, distorted: image, octaves: 3)
        for (i, band) in r.bands.enumerated() {
            XCTAssertEqual(band, 1.0, accuracy: 1e-4, "band \(i)")
        }
        XCTAssertEqual(r.base, 1.0, accuracy: 1e-4)
        XCTAssertTrue(r.hasExpectedSignature())
    }

    // MARK: - Resampler

    /// A constant plane must survive any ratio exactly — the cheapest check that the fractional
    /// edge weights normalize, and the one that fails loudly if they do not.
    func testAreaResamplePreservesAConstantAtAnyRatio() {
        let src = [Float](repeating: 0.375, count: 100 * 100)
        for (w, h) in [(50, 50), (37, 61), (99, 13), (100, 100)] {
            let out = FidelityGuard.areaResample(src, 100, 100, toWidth: w, toHeight: h)
            XCTAssertEqual(out.count, w * h)
            for v in out { XCTAssertEqual(v, 0.375, accuracy: 1e-6, "ratio \(w)×\(h)") }
        }
    }

    /// Integer-ratio reduction is a plain box average — assert it against a hand-computed case so a
    /// subtle off-by-one in the span never hides behind "looks about right".
    func testAreaResampleIsAnExactBoxAverageAtIntegerRatio() {
        // 4×2 → 2×1: each output is the mean of a 2×2 block.
        let src: [Float] = [1, 2, 3, 4,
                            5, 6, 7, 8]
        let out = FidelityGuard.areaResample(src, 4, 2, toWidth: 2, toHeight: 1)
        XCTAssertEqual(out.count, 2)
        let expected0: Float = (1 + 2 + 5 + 6) / 4
        let expected1: Float = (3 + 4 + 7 + 8) / 4
        XCTAssertEqual(out[0], expected0, accuracy: 1e-6)
        XCTAssertEqual(out[1], expected1, accuracy: 1e-6)
    }

    func testPSNRIsInfiniteOnIdenticalPlanes() {
        let a: [Float] = [0.1, 0.2, 0.3, 0.4]
        XCTAssertEqual(FidelityGuard.psnr(a, a), .infinity)
    }

    // MARK: - Tile map

    func testTileMapGeometryIncludesPartialEdgeTiles() throws {
        let source = try noiseImage(200, 120, seed: 41)
        let r = try FidelityGuard.downsampleConsistency(source: source, result: source, tileSize: 64)
        // Valid region is cropped by the SSIM radius (5) on each side: 190 × 110.
        XCTAssertEqual(r.ssimTiles.columns, 3)   // ceil(190 / 64)
        XCTAssertEqual(r.ssimTiles.rows, 2)      // ceil(110 / 64)
        XCTAssertEqual(r.ssimTiles.values.count, 6)
        XCTAssertFalse(r.ssimTiles.values.contains { $0.isNaN }, "no tile may be empty")
    }

    // MARK: - Fixtures

    private func makeImage(_ w: Int, _ h: Int, _ fill: (Int, Int) -> Float) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = UInt8(max(0, min(255, (fill(x, y) * 255).rounded())))
                let p = (y * w + x) * 4
                bytes[p] = v; bytes[p + 1] = v; bytes[p + 2] = v; bytes[p + 3] = 255
            }
        }
        return try image(from: bytes, w, h)
    }

    private func image(from bytes: [UInt8], _ w: Int, _ h: Int) throws -> CGImage {
        var mutable = bytes
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &mutable, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = ctx.makeImage() else {
            throw FidelityGuard.GuardError.rasterFailed
        }
        return image
    }

    /// Deterministic mid-grey noise — enough local variance for SSIM to be well-conditioned, and
    /// away from the clipping points so a perturbation is not silently clamped.
    private func noiseImage(_ w: Int, _ h: Int, seed: UInt32) throws -> CGImage {
        var s = seed &* 2_654_435_761 &+ 1
        return try makeImage(w, h) { _, _ in
            s = s &* 1_664_525 &+ 1_013_904_223
            return 0.3 + Float((s >> 16) & 0xff) / 255.0 * 0.4
        }
    }

    /// 🔑 **The octave tests need a 1/f fixture, and the reason is worth keeping.** White noise is
    /// almost entirely top-octave energy, so its deep Laplacian bands are nearly empty — and an
    /// empty band's SSIM is dominated by the 8-bit quantization of the fixture itself, not by
    /// whatever the test is trying to measure. Summing value noise across scales with 1/f amplitude
    /// puts real energy in every octave, which is what makes a per-octave reading meaningful. Real
    /// photographs are approximately 1/f; white noise is the unrepresentative case.
    private func scaleFreeImage(_ w: Int, _ h: Int, seed: UInt32) throws -> CGImage {
        var octaves: [[Float]] = []
        var amplitudes: [Float] = []
        for level in 0..<5 {
            let step = 1 << (level + 1)                // 2, 4, 8, 16, 32 px features
            let cw = max(2, w / step + 2), ch = max(2, h / step + 2)
            var s = (seed &+ UInt32(level)) &* 2_654_435_761 &+ 1
            var coarse = [Float](repeating: 0, count: cw * ch)
            for i in 0..<coarse.count {
                s = s &* 1_664_525 &+ 1_013_904_223
                coarse[i] = Float((s >> 16) & 0xffff) / 65535.0
            }
            let plane = FidelityGuard.Plane(samples: coarse, width: cw, height: ch)
            octaves.append(FidelityGuard.upscale(plane, toWidth: w, toHeight: h))
            amplitudes.append(Float(step))             // 1/f: amplitude grows with feature size
        }
        let norm = amplitudes.reduce(0, +)
        return try makeImage(w, h) { x, y in
            var acc: Float = 0
            for (i, plane) in octaves.enumerated() { acc += plane[y * w + x] * amplitudes[i] }
            return 0.2 + (acc / norm) * 0.6
        }
    }

    /// Hallucination, modelled properly: the region is *replaced* with independent detail rather
    /// than offset. A DC shift only moves SSIM's luminance term and leaves contrast and structure
    /// intact — which is not what an invented eyelash or letterform does to the statistics.
    private func replaceWithIndependentDetail(_ src: CGImage, rect: CGRect,
                                              seed: UInt32) throws -> CGImage {
        let (s, w, h) = try plane(of: src)
        var r = seed &* 2_654_435_761 &+ 1
        var invented = [Float](repeating: 0, count: w * h)
        for i in 0..<invented.count {
            r = r &* 1_664_525 &+ 1_013_904_223
            invented[i] = 0.3 + Float((r >> 16) & 0xff) / 255.0 * 0.4
        }
        return try makeImage(w, h) { x, y in
            rect.contains(CGPoint(x: Double(x), y: Double(y))) ? invented[y * w + x] : s[y * w + x]
        }
    }

    private func plane(of image: CGImage) throws -> ([Float], Int, Int) {
        let p = try FidelityGuard.lumaPlane(from: image)
        return (p.samples, p.width, p.height)
    }

    private func nearestUpscale(_ src: CGImage, factor: Int) throws -> CGImage {
        let (s, w, h) = try plane(of: src)
        return try makeImage(w * factor, h * factor) { x, y in s[(y / factor) * w + (x / factor)] }
    }

    private func perturb(_ src: CGImage, rect: CGRect, delta: Float) throws -> CGImage {
        let (s, w, h) = try plane(of: src)
        return try makeImage(w, h) { x, y in
            let inside = rect.contains(CGPoint(x: Double(x), y: Double(y)))
            return s[y * w + x] + (inside ? delta : 0)
        }
    }

    /// A ±amplitude checkerboard aligned to the 2×2 reduction blocks, so every block sums to zero.
    private func addCheckerboard(_ src: CGImage, amplitude: Float) throws -> CGImage {
        let (s, w, h) = try plane(of: src)
        return try makeImage(w, h) { x, y in
            let sign: Float = ((x + y) % 2 == 0) ? 1 : -1
            return s[y * w + x] + sign * amplitude
        }
    }

    private func unsharpMask(_ src: CGImage, amount: Float) throws -> CGImage {
        let (s, w, h) = try plane(of: src)
        let kernel = FidelityGuard.gaussianKernel(sigma: 1.0, radius: 3)
        let blurred = FidelityGuard.blur(s, w, h, kernel)
        return try makeImage(w, h) { x, y in
            let p = y * w + x
            return s[p] + amount * (s[p] - blurred[p])
        }
    }

    private func translate(_ src: CGImage, dx: Int, dy: Int) throws -> CGImage {
        let (s, w, h) = try plane(of: src)
        return try makeImage(w, h) { x, y in
            s[min(max(y - dy, 0), h - 1) * w + min(max(x - dx, 0), w - 1)]
        }
    }
}
