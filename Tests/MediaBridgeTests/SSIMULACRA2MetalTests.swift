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
