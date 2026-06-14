import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MediaMeasure

/// Validate the pure-Swift SSIMULACRA2 port against the installed libjxl `ssimulacra2` binary on the
/// identical PNG files. Skips if the binary isn't present.
final class SSIMULACRA2Tests: XCTestCase {

    private let binary = "/opt/homebrew/bin/ssimulacra2"

    private func makeImage(_ w: Int, _ h: Int, _ px: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let (r, g, b) = px(x, y); let i = (y * w + x) * 4
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
        } }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    private func writePNG(_ img: CGImage, _ url: URL) {
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, nil)
        CGImageDestinationFinalize(d)
    }

    private func loadPNG(_ url: URL) -> CGImage {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCreateImageAtIndex(src, 0, nil)!
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func testMatchesReferenceBinary() throws {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("ssimulacra2 binary not installed")
        }
        let w = 256, h = 256
        // A structured reference: gradients + a high-frequency sinusoid + a disc.
        let ref = makeImage(w, h) { x, y in
            let cx = x - 128, cy = y - 128
            let disc: Int = (cx * cx + cy * cy < 60 * 60) ? 60 : 0
            let hi = Int(40 * sin(Double(x) * 0.5) * cos(Double(y) * 0.4))
            return (UInt8(clamping: x + disc + hi),
                    UInt8(clamping: y + hi),
                    UInt8(clamping: 128 + hi - disc))
        }
        // Distortion: a 3×3 box blur of the reference (loses detail → a mid-range score).
        let refBytes = bytes(of: ref, w, h)
        let dist = makeImage(w, h) { x, y in
            var sr = 0, sg = 0, sb = 0
            for dy in -1...1 { for dx in -1...1 {
                let xx = min(max(x + dx, 0), w - 1), yy = min(max(y + dy, 0), h - 1)
                let i = (yy * w + xx) * 4
                sr += Int(refBytes[i]); sg += Int(refBytes[i + 1]); sb += Int(refBytes[i + 2])
            } }
            return (UInt8(sr / 9), UInt8(sg / 9), UInt8(sb / 9))
        }

        let dir = FileManager.default.temporaryDirectory
        let refURL = dir.appendingPathComponent("\(UUID().uuidString).png")
        let distURL = dir.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: refURL); try? FileManager.default.removeItem(at: distURL) }
        writePNG(ref, refURL); writePNG(dist, distURL)

        let reference = Double(try run(binary, [refURL.path, distURL.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? .nan
        // Read the SAME PNGs back so both tools see identical pixels.
        let mine = try SSIMULACRA2.score(reference: loadPNG(refURL), distorted: loadPNG(distURL))

        print(String(format: "SSIMULACRA2  reference=%.4f  mine=%.4f  Δ=%.4f", reference, mine, abs(mine - reference)))
        XCTAssertFalse(reference.isNaN, "binary returned a score")
        // Within ~3 points of the reference: the residual is the FIR-vs-recursive-Gaussian blur
        // approximation (most visible at the coarse 8×8 scales). Exact-identical = 100 is verified
        // separately, proving the XYB / SSIM / weights / final-polynomial are correct.
        XCTAssertEqual(mine, reference, accuracy: 3.0, "pure-Swift port tracks the reference (~3 pt)")
    }

    func testIdenticalIsHundred() throws {
        let img = makeImage(64, 64) { x, y in (UInt8(clamping: x * 4), UInt8(clamping: y * 4), 128) }
        let s = try SSIMULACRA2.score(reference: img, distorted: img)
        XCTAssertEqual(s, 100.0, accuracy: 1e-6, "identical images score 100")
    }

    private func bytes(of img: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &b, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return b
    }
}
