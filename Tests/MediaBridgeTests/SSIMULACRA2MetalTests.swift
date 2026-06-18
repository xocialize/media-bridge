import XCTest
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
}
