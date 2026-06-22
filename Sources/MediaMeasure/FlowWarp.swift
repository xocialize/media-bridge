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
