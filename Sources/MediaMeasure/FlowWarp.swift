import Foundation

/// Net-clean dense optical-flow field (the engine's `FlowField` converted at the app boundary, so
/// media-bridge stays MLX-free). Row-major `width × height`, interleaved per-pixel `(u, v)` displacement
/// in pixels: the pixel at `(x, y)` in the *source* of the flow moved by `(u, v)`.
public struct DenseFlow: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let uv: [Float]            // count == width * height * 2

    public init(width: Int, height: Int, uv: [Float]) {
        precondition(uv.count == width * height * 2, "uv must be width*height*2")
        self.width = width; self.height = height; self.uv = uv
    }

    @inline(__always) public func flow(_ x: Int, _ y: Int) -> (u: Float, v: Float) {
        let i = (y * width + x) * 2
        return (uv[i], uv[i + 1])
    }

    /// Resample this field to `toWidth × toHeight`, scaling the displacements by the resolution ratio.
    /// Used by the **flow-downscale** perf lever: flow is estimated on shrunk frames (cheap — SEA-RAFT's
    /// correlation volume is `(H/8·W/8)²`), then the reduced field is upscaled back to source resolution.
    /// A displacement of 1 px at the reduced scale is `toWidth/width` px at full scale, so `u` is scaled by
    /// the X ratio and `v` by the Y ratio. Bilinear sample with pixel-center alignment. No-op if already sized.
    public func upscaled(toWidth tw: Int, toHeight th: Int) -> DenseFlow {
        if tw == width && th == height { return self }
        let sx = Float(tw) / Float(width), sy = Float(th) / Float(height)
        let maxX = Float(width - 1), maxY = Float(height - 1)
        var out = [Float](repeating: 0, count: tw * th * 2)
        for y in 0..<th {
            let srcY = min(max((Float(y) + 0.5) / sy - 0.5, 0), maxY)
            let y0 = Int(srcY.rounded(.down)), y1 = min(Int(srcY.rounded(.down)) + 1, height - 1)
            let fy = srcY - Float(y0)
            for x in 0..<tw {
                let srcX = min(max((Float(x) + 0.5) / sx - 0.5, 0), maxX)
                let x0 = Int(srcX.rounded(.down)), x1 = min(Int(srcX.rounded(.down)) + 1, width - 1)
                let fx = srcX - Float(x0)
                let o = (y * tw + x) * 2
                for c in 0..<2 {                                  // u (c=0), v (c=1)
                    let p00 = uv[(y0 * width + x0) * 2 + c], p10 = uv[(y0 * width + x1) * 2 + c]
                    let p01 = uv[(y1 * width + x0) * 2 + c], p11 = uv[(y1 * width + x1) * 2 + c]
                    let top = p00 + (p10 - p00) * fx, bot = p01 + (p11 - p01) * fx
                    out[o + c] = (top + (bot - top) * fy) * (c == 0 ? sx : sy)
                }
            }
        }
        return DenseFlow(width: tw, height: th, uv: out)
    }
}

/// Flow-guided temporal warping for video-matte consistency.
///
/// To stabilize the matte at frame *t*, we warp the previous matte (aligned to frame *t-1*) into frame *t*'s
/// coordinates and blend it with the freshly-computed matte. **Backward warp** is the well-posed direction:
/// for each output pixel `q` at *t* we need where it came from in *t-1* → that is the flow from **cur→prev**
/// (`flow(curFrame, prevFrame)`), and we bilinearly sample the previous matte at `q + flow(q)`. Pixels whose
/// sample falls outside the frame (disocclusion / new content) are marked **invalid** so the blend can fall
/// back to the fresh matte there instead of smearing.
public enum FlowWarp {

    /// Backward-warp `prevMatte` (row-major grayscale in [0,1], `width × height`) by a cur→prev `flow`.
    /// Returns the warped matte plus a per-pixel validity mask (false where the sample was out of bounds).
    public static func backwardWarp(prevMatte: [Float], width: Int, height: Int,
                                    flow: DenseFlow) -> (warped: [Float], valid: [Bool]) {
        precondition(prevMatte.count == width * height, "prevMatte size mismatch")
        precondition(flow.width == width && flow.height == height, "flow size mismatch")
        var warped = [Float](repeating: 0, count: width * height)
        var valid = [Bool](repeating: false, count: width * height)
        let maxX = Float(width - 1), maxY = Float(height - 1)

        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let (u, v) = flow.flow(x, y)
                let sx = Float(x) + u, sy = Float(y) + v
                if sx < 0 || sy < 0 || sx > maxX || sy > maxY { continue }   // disocclusion → invalid
                warped[i] = bilinear(prevMatte, width: width, height: height, x: sx, y: sy)
                valid[i] = true
            }
        }
        return (warped, valid)
    }

    /// Temporal confidence blend: fuse the freshly-computed matte with the flow-warped previous matte.
    /// Where the warp is **valid** and the two **agree** (the stable-region case), trust the warped-prev to
    /// kill frame-to-frame flicker; where they **disagree** (a moving edge / genuinely new coverage) or the
    /// warp is **invalid** (disocclusion), trust the fresh matte so real changes aren't smeared.
    ///
    /// `agreement = max(0, 1 − |fresh−warped| / tolerance)` (1 when equal, 0 once the gap reaches `tolerance`);
    /// `w = strength · agreement` is the weight on the warped-prev; `out = w·warped + (1−w)·fresh`.
    /// `strength` ∈ [0,1] is the max temporal smoothing (0 = per-frame, no smoothing); `tolerance` is the
    /// matte-difference at which a region is treated as genuinely changed.
    public static func confidenceBlend(fresh: [Float], warped: [Float], valid: [Bool],
                                       strength: Float, tolerance: Float) -> [Float] {
        precondition(fresh.count == warped.count && fresh.count == valid.count, "size mismatch")
        let invTol = tolerance > 0 ? 1 / tolerance : 0
        var out = fresh
        for i in 0..<fresh.count where valid[i] {
            let agreement = max(0, 1 - abs(fresh[i] - warped[i]) * invTol)
            let w = strength * agreement
            out[i] = w * warped[i] + (1 - w) * fresh[i]
        }
        return out
    }

    /// Multi-channel backward warp — the `backwardWarp` generalization for an interleaved **C-channel** frame
    /// (row-major, channels innermost: `[y*W*C + x*C + c]`). Used to flow-warp a previous **upscaled RGB**
    /// frame for video temporal-consistency (the upscale analog of warping the previous matte). Out-of-bounds
    /// samples → `valid[i]=false` so the blend falls back to the fresh frame there.
    public static func backwardWarpChannels(prev: [Float], width: Int, height: Int, channels c: Int,
                                            flow: DenseFlow) -> (warped: [Float], valid: [Bool]) {
        precondition(prev.count == width * height * c, "prev size mismatch")
        precondition(flow.width == width && flow.height == height, "flow size mismatch")
        var warped = [Float](repeating: 0, count: width * height * c)
        var valid = [Bool](repeating: false, count: width * height)
        let maxX = Float(width - 1), maxY = Float(height - 1)
        for y in 0..<height {
            for x in 0..<width {
                let (u, v) = flow.flow(x, y)
                let sx = Float(x) + u, sy = Float(y) + v
                if sx < 0 || sy < 0 || sx > maxX || sy > maxY { continue }
                let o = (y * width + x) * c
                for ch in 0..<c {
                    warped[o + ch] = bilinearChannel(prev, width: width, height: height, channels: c,
                                                     channel: ch, x: sx, y: sy)
                }
                valid[y * width + x] = true
            }
        }
        return (warped, valid)
    }

    /// Multi-channel confidence blend — the `confidenceBlend` generalization. Agreement is a **single per-pixel
    /// scalar** from the mean absolute channel difference (so all channels move together, no colour-fringing):
    /// `agreement = max(0, 1 − meanAbs(fresh−warped)/tolerance)`, `w = strength·agreement`, then
    /// `out = w·warped + (1−w)·fresh` per channel. Stable regions (consecutive frames agree) get smoothed to
    /// kill flicker; moving/changed regions (disagreement) or disocclusions (invalid) keep the fresh frame, so
    /// real detail and motion aren't smeared.
    public static func confidenceBlendChannels(fresh: [Float], warped: [Float], valid: [Bool],
                                               channels c: Int, strength: Float, tolerance: Float) -> [Float] {
        precondition(fresh.count == warped.count && fresh.count == valid.count * c, "size mismatch")
        let invTol = tolerance > 0 ? 1 / tolerance : 0
        var out = fresh
        for p in 0..<valid.count where valid[p] {
            let o = p * c
            var diff: Float = 0
            for ch in 0..<c { diff += abs(fresh[o + ch] - warped[o + ch]) }
            let agreement = max(0, 1 - (diff / Float(c)) * invTol)
            let w = strength * agreement
            if w > 0 { for ch in 0..<c { out[o + ch] = w * warped[o + ch] + (1 - w) * fresh[o + ch] } }
        }
        return out
    }

    /// Bilinear sample of channel `ch` in an interleaved C-channel buffer at fractional `(x, y)` (in-bounds).
    @inline(__always)
    static func bilinearChannel(_ buf: [Float], width: Int, height: Int, channels c: Int, channel ch: Int,
                                x: Float, y: Float) -> Float {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = x - Float(x0), fy = y - Float(y0)
        let p00 = buf[(y0 * width + x0) * c + ch], p10 = buf[(y0 * width + x1) * c + ch]
        let p01 = buf[(y1 * width + x0) * c + ch], p11 = buf[(y1 * width + x1) * c + ch]
        let top = p00 + (p10 - p00) * fx, bot = p01 + (p11 - p01) * fx
        return top + (bot - top) * fy
    }

    /// Bilinear sample of a row-major grayscale buffer at fractional `(x, y)` (caller guarantees in-bounds).
    @inline(__always)
    static func bilinear(_ buf: [Float], width: Int, height: Int, x: Float, y: Float) -> Float {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = x - Float(x0), fy = y - Float(y0)
        let p00 = buf[y0 * width + x0], p10 = buf[y0 * width + x1]
        let p01 = buf[y1 * width + x0], p11 = buf[y1 * width + x1]
        let top = p00 + (p10 - p00) * fx
        let bot = p01 + (p11 - p01) * fx
        return top + (bot - top) * fy
    }
}
