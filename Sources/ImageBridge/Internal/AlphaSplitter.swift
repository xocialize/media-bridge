import CoreVideo
import Foundation

// Alpha handling for the AI chain (PRD §4 — "the real new problem"). NAFNet and
// the SR models are trained on OPAQUE RGB; a still's transparency must never reach
// them premultiplied. So: un-premultiply → force opaque → run the FrameProcessor
// on straight RGB → recombine the original alpha (re-premultiplying to keep the
// CoreImage premultiplied-BGRA invariant the encoder expects). The opaque models
// stay format-blind; all alpha logic lives here at the I/O boundary.
//
// Decoded buffers are premultiplied 32BGRA (CIContext.render's convention), bytes
// B,G,R,A per pixel.

struct AlphaPlane: Sendable {
    let width: Int
    let height: Int
    var data: [UInt8]      // one byte per pixel, row-major
}

enum AlphaSplitter {

    /// Split a premultiplied BGRA buffer into (opaque straight-RGB buffer, alpha plane).
    static func split(_ src: CVPixelBuffer) -> (opaque: CVPixelBuffer, alpha: AlphaPlane)? {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        guard let opaque = makeBGRA(w, h) else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(opaque, [])
        defer {
            CVPixelBufferUnlockBaseAddress(opaque, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let sb = CVPixelBufferGetBaseAddress(src),
              let ob = CVPixelBufferGetBaseAddress(opaque) else { return nil }
        let sStride = CVPixelBufferGetBytesPerRow(src)
        let oStride = CVPixelBufferGetBytesPerRow(opaque)
        let sp = sb.assumingMemoryBound(to: UInt8.self)
        let op = ob.assumingMemoryBound(to: UInt8.self)
        var alpha = [UInt8](repeating: 0, count: w * h)

        for y in 0 ..< h {
            let sRow = y * sStride, oRow = y * oStride
            for x in 0 ..< w {
                let s = sRow + x * 4, o = oRow + x * 4
                let a = sp[s + 3]
                alpha[y * w + x] = a
                if a == 0 {                        // fully transparent → RGB undefined; use 0
                    op[o] = 0; op[o + 1] = 0; op[o + 2] = 0
                } else {
                    let inv = 255.0 / Double(a)    // un-premultiply: straight = premult·255/α
                    op[o]     = clamp(Double(sp[s])     * inv)
                    op[o + 1] = clamp(Double(sp[s + 1]) * inv)
                    op[o + 2] = clamp(Double(sp[s + 2]) * inv)
                }
                op[o + 3] = 255                    // opaque for the model
            }
        }
        return (opaque, AlphaPlane(width: w, height: h, data: alpha))
    }

    /// Recombine a processed straight-RGB buffer with the original alpha,
    /// re-premultiplying. If the processor changed dimensions (e.g. SR upscale),
    /// the alpha is nearest-neighbour resized to match.
    static func recombine(rgb: CVPixelBuffer, alpha: AlphaPlane) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(rgb), h = CVPixelBufferGetHeight(rgb)
        let a = (w == alpha.width && h == alpha.height) ? alpha : resizeNearest(alpha, w, h)
        guard let out = makeBGRA(w, h) else { return nil }
        CVPixelBufferLockBaseAddress(rgb, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(rgb, .readOnly)
        }
        guard let rb = CVPixelBufferGetBaseAddress(rgb),
              let ob = CVPixelBufferGetBaseAddress(out) else { return nil }
        let rStride = CVPixelBufferGetBytesPerRow(rgb)
        let oStride = CVPixelBufferGetBytesPerRow(out)
        let rp = rb.assumingMemoryBound(to: UInt8.self)
        let op = ob.assumingMemoryBound(to: UInt8.self)

        for y in 0 ..< h {
            let rRow = y * rStride, oRow = y * oStride
            for x in 0 ..< w {
                let r = rRow + x * 4, o = oRow + x * 4
                let av = a.data[y * w + x]
                let m = Double(av) / 255.0         // re-premultiply: premult = straight·α/255
                op[o]     = clamp(Double(rp[r])     * m)
                op[o + 1] = clamp(Double(rp[r + 1]) * m)
                op[o + 2] = clamp(Double(rp[r + 2]) * m)
                op[o + 3] = av
            }
        }
        return out
    }

    // MARK: - helpers

    private static func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

    private static func makeBGRA(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
                == kCVReturnSuccess else { return nil }
        return pb
    }

    private static func resizeNearest(_ src: AlphaPlane, _ w: Int, _ h: Int) -> AlphaPlane {
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0 ..< h {
            let sy = min(src.height - 1, y * src.height / h)
            for x in 0 ..< w {
                let sx = min(src.width - 1, x * src.width / w)
                out[y * w + x] = src.data[sy * src.width + sx]
            }
        }
        return AlphaPlane(width: w, height: h, data: out)
    }
}
