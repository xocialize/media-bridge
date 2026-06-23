import Foundation
import CoreGraphics

/// Tuning for flow-guided temporal matte stabilization.
public struct VideoMatteOptions: Sendable {
    /// Max weight on the flow-warped previous matte in agreeing regions (0 = per-frame, no smoothing).
    public var temporalStrength: Float
    /// Matte difference at which a region is treated as genuinely changed (→ trust the fresh matte).
    public var agreementTolerance: Float
    /// **Flow-downscale perf lever.** Estimate optical flow on frames shrunk by this integer factor, then
    /// upscale the field back to source resolution. SEA-RAFT's cost is dominated by an `(H/8·W/8)²`
    /// correlation volume, so `2` cuts that ~16× for a large speedup; the matte stays full-resolution and
    /// the confidence-blend self-heals the small precision loss in the flow. `1` = full-res flow (default).
    public var flowDownsample: Int
    public init(temporalStrength: Float = 0.6, agreementTolerance: Float = 0.15, flowDownsample: Int = 1) {
        self.temporalStrength = temporalStrength
        self.agreementTolerance = agreementTolerance
        self.flowDownsample = max(1, flowDownsample)
    }
}

/// Automatic video-matting **temporal-consistency core** (Stage 1). Net-clean orchestration: it drives an
/// injected per-frame matte seam (BiRefNet, via ExtractKit's `MatteProvider` at the app layer) and an
/// injected optical-flow seam (SEA-RAFT), and fuses each fresh matte with the flow-warped previous matte
/// (`FlowWarp.backwardWarp` + `confidenceBlend`) to suppress flicker while preserving real motion. Stateful
/// + serial (carries the previous frame + stabilized matte); feed frames in order via `next(_:)`.
///
/// The seams are plain closures so this stays MLX-free — the app converts `CGImage`/engine `FlowField` at the
/// boundary. Matte and flow MUST be at the same resolution (the source/frame resolution).
public final class VideoMatteProcessor {
    public enum MatteError: Error { case flowSizeMismatch(matte: (Int, Int), flow: (Int, Int)) }

    /// Per-frame soft-alpha matte (grayscale `CGImage`, source resolution).
    private let matte: (CGImage) async throws -> CGImage
    /// Dense optical flow `image0 → image1`. The processor passes `(cur, prev)` so the result is the
    /// cur→prev field `backwardWarp` needs.
    private let flow: (CGImage, CGImage) async throws -> DenseFlow
    private let options: VideoMatteOptions

    private var prevFrame: CGImage?
    private var prevStable: [Float]?
    private var width = 0, height = 0

    public init(options: VideoMatteOptions = .init(),
                matte: @escaping (CGImage) async throws -> CGImage,
                flow: @escaping (CGImage, CGImage) async throws -> DenseFlow) {
        self.options = options
        self.matte = matte
        self.flow = flow
    }

    /// Process the next frame in order → its temporally-stabilized soft-alpha matte (grayscale `CGImage`).
    public func next(_ frame: CGImage) async throws -> CGImage {
        let freshCG = try await matte(frame)
        var fresh = Self.grayFloats(freshCG)
        let w = freshCG.width, h = freshCG.height

        if let prevFrame, let prevStable, w == width, h == height {
            let f = try await flowField(cur: frame, prev: prevFrame, width: w, height: h)
            guard f.width == w && f.height == h else {
                throw MatteError.flowSizeMismatch(matte: (w, h), flow: (f.width, f.height))
            }
            let (warped, valid) = FlowWarp.backwardWarp(prevMatte: prevStable, width: w, height: h, flow: f)
            fresh = FlowWarp.confidenceBlend(fresh: fresh, warped: warped, valid: valid,
                                             strength: options.temporalStrength,
                                             tolerance: options.agreementTolerance)
        }

        prevFrame = frame
        prevStable = fresh
        width = w; height = h
        return Self.grayCGImage(fresh, width: w, height: h)
    }

    /// Reset between independent clips/shots (clears the temporal history so frame 0 is fresh).
    public func reset() { prevFrame = nil; prevStable = nil }

    /// cur→prev flow at `width × height`. With `flowDownsample > 1`, estimate on shrunk frames (cheap) and
    /// upscale the field back to source resolution — the matte stays full-res; the blend absorbs the slack.
    private func flowField(cur: CGImage, prev: CGImage, width w: Int, height h: Int) async throws -> DenseFlow {
        let k = options.flowDownsample
        guard k > 1 else { return try await flow(cur, prev) }
        let sw = max(1, w / k), sh = max(1, h / k)
        let size = CGSize(width: sw, height: sh)
        let f = try await flow(VideoQuality.resample(cur, to: size), VideoQuality.resample(prev, to: size))
        return f.upscaled(toWidth: w, toHeight: h)
    }

    // MARK: - grayscale CGImage ⇄ [Float] (0…1, row-major)

    static func grayFloats(_ image: CGImage) -> [Float] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        if let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                               space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes.map { Float($0) / 255 }
    }

    static func grayCGImage(_ buf: [Float], width: Int, height: Int) -> CGImage {
        var bytes = buf.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }
}
