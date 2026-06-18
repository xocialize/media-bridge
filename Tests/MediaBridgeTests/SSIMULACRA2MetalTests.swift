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
