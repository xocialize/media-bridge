import CoreVideo
import Foundation

/// Print-resolution tiling (PRD §4 "tiling mandatory"). A poster/print still (e.g.
/// 6000×4000) would blow the MLX model's memory at full res, so this decorator wraps
/// any same-resolution `FrameProcessor` (NAFNet restoration is scale-1) and runs it
/// tile-by-tile when the input exceeds a whole-frame budget, feather-blending the
/// overlaps to hide seams. At/below the budget it's a straight passthrough to the inner
/// processor (one dispatch, no blend) — numerically identical for a fully-convolutional
/// model. The inner model stays format-blind: it only ever sees a tile-sized buffer.
///
/// This is the `FrameProcessor`-level analog of ForgeUpscaler's MLXTileProcessor (which
/// is MLX-closure-based + upscale-oriented); the still chain is buffer-based + scale-1,
/// so it tiles here, at the I/O boundary, with no MLX dependency.
public struct TiledFrameProcessor: FrameProcessor, @unchecked Sendable {

    private let inner: any FrameProcessor
    private let maxWholePixels: Int
    private let tileSize: Int
    private let overlap: Int

    /// - Parameters:
    ///   - inner: the (scale-1) model chain to run per tile.
    ///   - maxWholePixels: input-pixel ceiling for the whole-frame fast path. Default
    ///     3840×2160 (4K) — the largest size proven to run whole-frame in the video path.
    ///   - tileSize: square tile edge in pixels (default 512).
    ///   - overlap: feather-blend overlap between adjacent tiles (default 32).
    public init(inner: any FrameProcessor, maxWholePixels: Int = 3840 * 2160,
                tileSize: Int = 512, overlap: Int = 32) {
        self.inner = inner
        self.maxWholePixels = max(1, maxWholePixels)
        self.tileSize = max(16, tileSize)
        self.overlap = max(0, min(overlap, tileSize / 2))
    }

    public func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        // Whole-frame fast path, or formats we can't byte-tile (let the inner handle it).
        guard w * h > maxWholePixels,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return inner.process(pixelBuffer)
        }
        return tiled(pixelBuffer, w: w, h: h) ?? inner.process(pixelBuffer)
    }

    // MARK: - tiled path

    private func tiled(_ src: CVPixelBuffer, w: Int, h: Int) -> CVPixelBuffer? {
        guard let out = makeBGRA(w, h) else { return nil }
        // Zero the output so the feather blend's "first write into this pixel" test works.
        CVPixelBufferLockBaseAddress(out, [])
        if let ob = CVPixelBufferGetBaseAddress(out) {
            memset(ob, 0, CVPixelBufferGetBytesPerRow(out) * h)
        }
        CVPixelBufferUnlockBaseAddress(out, [])

        let step = max(tileSize - overlap, 1)
        var ty = 0
        while ty < h {
            let y = min(ty, max(0, h - tileSize))
            let th = min(tileSize, h - y)
            var tx = 0
            while tx < w {
                let x = min(tx, max(0, w - tileSize))
                let tw = min(tileSize, w - x)
                if let tile = crop(src, x: x, y: y, tw: tw, th: th) {
                    let processed = inner.process(tile)
                    blend(processed, into: out, x: x, y: y, tw: tw, th: th)
                }
                if x + tw >= w { break }
                tx += step
            }
            if y + th >= h { break }
            ty += step
        }
        // Force opaque (the decode/alpha path treats stills as opaque BGRA here).
        setOpaque(out, w: w, h: h)
        return out
    }

    /// Copy a sub-rectangle of a BGRA buffer into a fresh tw×th BGRA buffer.
    private func crop(_ src: CVPixelBuffer, x: Int, y: Int, tw: Int, th: Int) -> CVPixelBuffer? {
        guard let dst = makeBGRA(tw, th) else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let sb = CVPixelBufferGetBaseAddress(src), let db = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let sBPR = CVPixelBufferGetBytesPerRow(src), dBPR = CVPixelBufferGetBytesPerRow(dst)
        let sp = sb.assumingMemoryBound(to: UInt8.self), dp = db.assumingMemoryBound(to: UInt8.self)
        for row in 0 ..< th {
            memcpy(dp + row * dBPR, sp + (y + row) * sBPR + x * 4, tw * 4)
        }
        return dst
    }

    /// Feather-blend a processed tile into the output at (x, y). Same ramp as the video
    /// tiler: weight 1 in the tile centre, →0 over `overlap` at the edges; first write to
    /// a pixel stamps, later writes blend. Reads only the top-left tw×th of the processed
    /// tile (a scale-1 model returns the same size; anything larger is clipped).
    private func blend(_ tile: CVPixelBuffer, into out: CVPixelBuffer, x: Int, y: Int, tw: Int, th: Int) {
        CVPixelBufferLockBaseAddress(tile, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(tile, .readOnly)
        }
        guard let tb = CVPixelBufferGetBaseAddress(tile), let ob = CVPixelBufferGetBaseAddress(out) else { return }
        let tBPR = CVPixelBufferGetBytesPerRow(tile), oBPR = CVPixelBufferGetBytesPerRow(out)
        let tp = tb.assumingMemoryBound(to: UInt8.self), op = ob.assumingMemoryBound(to: UInt8.self)
        let writeH = min(th, CVPixelBufferGetHeight(tile)), writeW = min(tw, CVPixelBufferGetWidth(tile))
        let ov = Float(max(overlap, 1))
        for row in 0 ..< writeH {
            let wyT = min(Float(row) / ov, 1), wyB = min(Float(writeH - 1 - row) / ov, 1)
            let tRow = row * tBPR, oRow = (y + row) * oBPR
            for col in 0 ..< writeW {
                let wxL = min(Float(col) / ov, 1), wxR = min(Float(writeW - 1 - col) / ov, 1)
                let weight = min(wxL, wxR) * min(wyT, wyB)
                let t = tRow + col * 4, o = oRow + (x + col) * 4
                if weight >= 0.999 || op[o + 3] == 0 {
                    op[o] = tp[t]; op[o + 1] = tp[t + 1]; op[o + 2] = tp[t + 2]; op[o + 3] = 255
                } else {
                    op[o]     = mix(op[o],     tp[t],     weight)
                    op[o + 1] = mix(op[o + 1], tp[t + 1], weight)
                    op[o + 2] = mix(op[o + 2], tp[t + 2], weight)
                    op[o + 3] = 255
                }
            }
        }
    }

    // MARK: - helpers

    private func mix(_ a: UInt8, _ b: UInt8, _ w: Float) -> UInt8 {
        UInt8(max(0, min(255, (Float(a) * (1 - w) + Float(b) * w).rounded())))
    }

    private func setOpaque(_ pb: CVPixelBuffer, w: Int, h: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let b = CVPixelBufferGetBaseAddress(pb) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pb), p = b.assumingMemoryBound(to: UInt8.self)
        for yy in 0 ..< h { for xx in 0 ..< w { p[yy * bpr + xx * 4 + 3] = 255 } }
    }

    private func makeBGRA(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
                == kCVReturnSuccess else { return nil }
        return pb
    }
}
