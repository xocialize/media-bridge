import XCTest
import CoreGraphics
import MediaMeasure

/// Stage-1 parity: the Metal separable Gaussian blur must match the pure-Swift FIR (`SSIMULACRA2.blur`)
/// within fp tolerance. Reference FIR replicated here (the Swift one is private) — same kernel + edge
/// clamp. Non-multiple-of-16 dims exercise the dispatch bounds guard.
final class SSIMULACRA2MetalTests: XCTestCase {

    func testMetalBlurMatchesCPUFIR() throws {
        guard let metal = SSIMULACRA2Metal() else { throw XCTSkip("no Metal device") }
        let w = 67, h = 53

        var src = [Float](repeating: 0, count: w * h)
        var s: UInt32 = 0x1234_5678
        for i in 0..<src.count { s = s &* 1_664_525 &+ 1_013_904_223; src[i] = Float((s >> 8) & 0xffff) / 65535.0 }

        let kernel = firKernel(sigma: 1.5)
        let reference = blurFIR(src, w, h, kernel)
        let got = metal.blur(src, width: w, height: h, kernel: kernel)

        XCTAssertEqual(got.count, reference.count)
        var maxErr: Float = 0
        for i in 0..<reference.count { maxErr = max(maxErr, abs(got[i] - reference[i])) }
        XCTAssertLessThan(maxErr, 1e-5, "Metal blur vs CPU FIR maxErr=\(maxErr)")
    }

    /// End-to-end: GPU-blur score agrees with the full pure-Swift score (only the blur differs, and it's
    /// parity-tested) — so the Metal backend is a drop-in that preserves the corpus-validated floors.
    func testMetalScoreMatchesSwiftScore() throws {
        guard let metal = SSIMULACRA2Metal() else { throw XCTSkip("no Metal device") }
        let ref = gradientImage(160, 120, shift: 0)
        let dist = gradientImage(160, 120, shift: 0.05)

        let swiftScore = try SSIMULACRA2.score(reference: ref, distorted: dist)
        let metalScore = try metal.score(reference: ref, distorted: dist)

        XCTAssertGreaterThan(swiftScore, 0)
        XCTAssertLessThan(abs(metalScore - swiftScore), 0.05,
                          "metal=\(metalScore) swift=\(swiftScore) Δ=\(abs(metalScore - swiftScore))")
    }

    /// Full-GPU per-channel path (products + blur + maps + reduction on-device) vs the pure-Swift score.
    func testFullGPUChannelScalarsMatchesSwift() throws {
        guard let metal = SSIMULACRA2Metal() else { throw XCTSkip("no Metal device") }
        let ref = gradientImage(160, 120, shift: 0)
        let dist = gradientImage(160, 120, shift: 0.05)

        let swiftScore = try SSIMULACRA2.score(reference: ref, distorted: dist)
        let gpuScore = try SSIMULACRA2.score(reference: ref, distorted: dist,
                                             channelScalars: metal.channelScalarsFunction)
        XCTAssertLessThan(abs(gpuScore - swiftScore), 0.1,
                          "full-GPU=\(gpuScore) swift=\(swiftScore) Δ=\(abs(gpuScore - swiftScore))")
    }

    /// Resident whole-score path (ingest + XYB + pyramid + reductions on-device, one sync) vs the
    /// pure-Swift score — the ±0.05 bar the routing relies on. Odd, non-multiple-of-16 dims
    /// exercise the pyramid's edge clamp and every kernel's bounds guard; the second call reuses
    /// the pooled working set and must reproduce the first bit-for-bit.
    func testResidentScoreMatchesSwiftScore() throws {
        guard let metal = SSIMULACRA2Metal(), metal.residentAvailable else {
            throw XCTSkip("no Metal device / resident disabled")
        }
        // Gradient pair, same fixture as the V1 tests.
        let ref = gradientImage(160, 120, shift: 0)
        let dist = gradientImage(160, 120, shift: 0.05)
        let swiftScore = try SSIMULACRA2.score(reference: ref, distorted: dist)
        let resident = try metal.scoreResident(reference: ref, distorted: dist)
        XCTAssertLessThan(abs(resident - swiftScore), 0.05,
                          "resident=\(resident) swift=\(swiftScore) Δ=\(abs(resident - swiftScore))")

        // Odd dims + deterministic noise (LCG) — pyramid edges, bounds guards, six full scales.
        let refN = noiseImage(131, 97, seed: 0x1234_5678)
        let distN = noiseImage(131, 97, seed: 0x8765_4321)
        let swiftN = try SSIMULACRA2.score(reference: refN, distorted: distN)
        let residentN = try metal.scoreResident(reference: refN, distorted: distN)
        XCTAssertLessThan(abs(residentN - swiftN), 0.05,
                          "resident=\(residentN) swift=\(swiftN) Δ=\(abs(residentN - swiftN))")

        // Pool reuse determinism: identical inputs through the cached set → identical output.
        let again = try metal.scoreResident(reference: refN, distorted: distN)
        XCTAssertEqual(again, residentN, "pooled re-score must be deterministic")
    }

    /// The resident path rasterizes into POOLED upload buffers, and `CGContext.draw` composites
    /// source-over — so before the clear, an image carrying alpha blended against whatever the
    /// working set held from its previous occupant. That made the score a function of what the
    /// pool scored last, and diverged from the CPU path, which composites over black every call.
    /// Nothing else in this suite exercises alpha: every other fixture writes A = 255.
    func testResidentScoreIsDeterministicForTranslucentInput() throws {
        guard let metal = SSIMULACRA2Metal(), metal.residentAvailable else {
            throw XCTSkip("no Metal device / resident disabled")
        }
        let (w, h) = (160, 120)
        let ref = translucentImage(w, h, tint: 0)
        let dist = translucentImage(w, h, tint: 6)

        let first = try metal.scoreResident(reference: ref, distorted: dist)
        // Poison the pooled upload buffers with an unrelated OPAQUE pair at the SAME dims — the
        // pool reuses by (w, h), so this lands in the very working set the pair just used.
        _ = try metal.scoreResident(reference: noiseImage(w, h, seed: 0x0A11_CE00),
                                    distorted: noiseImage(w, h, seed: 0x0B0B_0B0B))
        let second = try metal.scoreResident(reference: ref, distorted: dist)

        XCTAssertEqual(first, second,
                       "a translucent score must not depend on what the pool scored before it")

        // …and the ground it composites over must be the CPU path's ground (black), not merely
        // *some* stable ground — otherwise the two backends disagree on every alpha-bearing still.
        let swiftScore = try SSIMULACRA2.score(reference: ref, distorted: dist)
        XCTAssertLessThan(abs(second - swiftScore), 0.05,
                          "resident=\(second) swift=\(swiftScore) Δ=\(abs(second - swiftScore))")
    }

    /// SSIMULACRA2 is DEFINED so an identical pair scores exactly 100 — every per-pixel term is
    /// a difference of two quantities that are bitwise equal when the images are. The GPU path
    /// did not: it returned 99.13-99.43 on all ten corpus 1080 masters while the CPU path
    /// returned exactly 100 (AB-T-0136). Metal's default fast-math had contracted the covariance
    /// subtraction into an fma and left the variance subtractions uncontracted, so numerator and
    /// denominator disagreed by the rounding of one product and refused to cancel. The kernel now
    /// writes every multiply-add out explicitly.
    ///
    /// Nothing in this suite caught it: `testResidentScoreMatchesSwiftScore` compares a DISTORTED
    /// pair within ±0.05 and stayed green throughout, because the defect concentrates at the top
    /// of the scale. This is the missing test, and it asserts EXACT equality deliberately — with
    /// i1 == i2 the whole pipeline is bitwise symmetric (same ingest, same XYB, same blur taps,
    /// so mu1 == mu2 and s11 == s12 == s22), which makes every map term identically zero rather
    /// than merely small. A tolerance here would re-admit the bug it exists to catch.
    ///
    /// Flat content is the worst case (it is all low-variance pixels, which is where the error
    /// lived, and is exactly what ClassAdaptiveFloor raises the floor on), so both a flat and a
    /// textured fixture run, through BOTH GPU entry points.
    func testIdenticalPairScoresExactly100() throws {
        guard let metal = SSIMULACRA2Metal() else { throw XCTSkip("no Metal device") }

        for (label, image) in [("flat", flatImage(160, 120, level: 128)),
                               ("textured", noiseImage(160, 120, seed: 0x5E1F_5E1F)),
                               ("gradient", gradientImage(160, 120, shift: 0))] {
            // The CPU twin is the definition being matched, not just a second opinion.
            let cpu = try SSIMULACRA2.score(reference: image, distorted: image)
            XCTAssertEqual(cpu, 100.0, "\(label): CPU identical pair must be 100, got \(cpu)")

            let gpuScalars = try SSIMULACRA2.score(reference: image, distorted: image,
                                                   channelScalars: metal.channelScalarsFunction)
            XCTAssertEqual(gpuScalars, 100.0,
                           "\(label): channelScalars identical pair must be 100, got \(gpuScalars)")

            if metal.residentAvailable {
                let resident = try metal.scoreResident(reference: image, distorted: image)
                XCTAssertEqual(resident, 100.0,
                               "\(label): resident identical pair must be 100, got \(resident)")
            }
        }
    }

    /// Uniform fill — zero variance everywhere, so `denomS` is C2 alone and the SSIM term has no
    /// signal to hide a cancellation failure behind. Opaque, like every fixture here but
    /// `translucentImage`.
    private func flatImage(_ w: Int, _ h: Int, level: UInt8) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in 0..<(w * h) {
            buf[i * 4] = level; buf[i * 4 + 1] = level; buf[i * 4 + 2] = level; buf[i * 4 + 3] = 255
        }
        return ctx.makeImage()!
    }

    /// White premultiplied by a left-to-right alpha ramp (B=G=R=A), the `AlphaVideoWriterTests:8`
    /// idiom — the only genuinely non-opaque fixture shape in this suite. `tint` darkens the
    /// colour slightly so a ref/dist pair scores below 100; premultiplication requires RGB ≤ A.
    private func translucentImage(_ w: Int, _ h: Int, tint: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let a = x * 255 / max(1, w - 1)          // fully transparent → fully opaque
                let v = max(0, a - tint)
                let i = (y * w + x) * 4
                buf[i] = UInt8(v)
                buf[i + 1] = UInt8(v)
                buf[i + 2] = UInt8(max(0, v - (y % 3)))  // a little vertical structure to score on
                buf[i + 3] = UInt8(a)
            }
        }
        return ctx.makeImage()!
    }

    private func noiseImage(_ w: Int, _ h: Int, seed: UInt32) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var s = seed
        func next() -> UInt8 { s = s &* 1_664_525 &+ 1_013_904_223; return UInt8((s >> 16) & 0xff) }
        for i in 0..<(w * h) {
            buf[i * 4] = next(); buf[i * 4 + 1] = next(); buf[i * 4 + 2] = next(); buf[i * 4 + 3] = 255
        }
        return ctx.makeImage()!
    }

    /// The multi-set pool behind the Kit's width-3 bulk default: three CONCURRENT resident scores
    /// of the same pair must all equal the serial answer (each caller gets its own set — no
    /// cross-talk), and a dims change afterward must still score correctly (idle-set eviction).
    func testResidentPoolConcurrencyAndDimsChange() async throws {
        guard let metal = SSIMULACRA2Metal(), metal.residentAvailable else {
            throw XCTSkip("no Metal device / resident disabled")
        }
        let ref = gradientImage(160, 120, shift: 0)
        let dist = gradientImage(160, 120, shift: 0.05)
        let serial = try metal.scoreResident(reference: ref, distorted: dist)

        // CGImage is immutable-in-practice; the package's .v5 stance made this exact call. The
        // scorer itself is @unchecked Sendable (pool-locked) as of the multi-set pool.
        struct Pair: @unchecked Sendable { let r: CGImage, d: CGImage }
        let pair = Pair(r: ref, d: dist)
        let concurrent = await withTaskGroup(of: Double?.self) { group -> [Double] in
            for _ in 0..<3 {
                group.addTask { try? metal.scoreResident(reference: pair.r, distorted: pair.d) }
            }
            var out: [Double] = []
            for await s in group { if let s { out.append(s) } }
            return out
        }
        XCTAssertEqual(concurrent.count, 3)
        for s in concurrent {
            XCTAssertEqual(s, serial, "a pooled concurrent score must equal the serial answer")
        }

        // Dims change: stale idle sets evict, the new geometry scores clean, and going BACK to
        // the first geometry still agrees with the original answer.
        let refN = noiseImage(97, 131, seed: 0x0BAD_F00D)
        let distN = noiseImage(97, 131, seed: 0x0D15_EA5E)
        let swiftN = try SSIMULACRA2.score(reference: refN, distorted: distN)
        let residentN = try metal.scoreResident(reference: refN, distorted: distN)
        XCTAssertLessThan(abs(residentN - swiftN), 0.05)
        XCTAssertEqual(try metal.scoreResident(reference: ref, distorted: dist), serial)
    }

    // MARK: - Reference (mirrors SSIMULACRA2.gaussianKernel + blur)

    private func firKernel(sigma: Float) -> [Float] {
        let r = Int(ceilf(sigma * 4))
        var k = [Float](); var sum: Float = 0
        for i in -r...r { let v = expf(-Float(i * i) / (2 * sigma * sigma)); k.append(v); sum += v }
        return k.map { $0 / sum }
    }

    private func blurFIR(_ src: [Float], _ w: Int, _ h: Int, _ kernel: [Float]) -> [Float] {
        let r = kernel.count / 2
        var tmp = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                var a: Float = 0
                for k in -r...r { a += src[row + min(max(x + k, 0), w - 1)] * kernel[k + r] }
                tmp[row + x] = a
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var a: Float = 0
                for k in -r...r { a += tmp[min(max(y + k, 0), h - 1) * w + x] * kernel[k + r] }
                out[y * w + x] = a
            }
        }
        return out
    }

    private func gradientImage(_ w: Int, _ h: Int, shift: Float) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        func u8(_ f: Float) -> UInt8 { UInt8(min(max(f, 0), 1) * 255) }
        for y in 0..<h {
            for x in 0..<w {
                let gx = Float(x) / Float(w), gy = Float(y) / Float(h)
                let i = (y * w + x) * 4
                buf[i] = u8(gx + shift); buf[i + 1] = u8(gy); buf[i + 2] = u8(1 - gx + shift * 0.5); buf[i + 3] = 255
            }
        }
        return ctx.makeImage()!
    }
}
