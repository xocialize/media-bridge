import Foundation
import CoreGraphics

/// Tuning for flow-guided temporal consistency of an **upscaled / enhanced** video (the upscale analog of
/// `VideoMatteOptions`).
public struct VideoConsistencyOptions: Sendable {
    /// Max weight on the flow-warped previous frame in agreeing regions (0 = per-frame, no smoothing).
    /// Kept moderate by default — SR detail is precious, so we only borrow from the previous frame where the
    /// two already agree (i.e. flicker, not detail).
    public var temporalStrength: Float
    /// Mean per-channel difference (0…1 units) at which a region is treated as genuinely changed (→ trust the
    /// fresh frame). ~0.06 ≈ 15/255.
    public var agreementTolerance: Float
    public init(temporalStrength: Float = 0.5, agreementTolerance: Float = 0.06) {
        self.temporalStrength = temporalStrength
        self.agreementTolerance = agreementTolerance
    }
}

/// **Flow-guided temporal-consistency core** for upscaled/enhanced video (Forge V4b). Net-clean orchestration:
/// it drives an injected per-frame **enhance** seam (Real-ESRGAN / SeedVR2, via the app layer) and an injected
/// **optical-flow** seam (SEA-RAFT), and fuses each fresh upscaled frame with the flow-warped previous *stable*
/// frame (`FlowWarp.backwardWarpChannels` + `confidenceBlendChannels`) to suppress the inter-frame flicker that
/// per-frame super-resolution introduces, while preserving real motion and detail (self-healing on disagreement).
///
/// Mirrors `VideoMatteProcessor`, on 3-channel RGB instead of a 1-channel matte. Flow is estimated on the
/// **source** frames (the cheap small side) and upscaled to the output resolution via `DenseFlow.upscaled` —
/// reusing exactly the matting infrastructure. Stateful + serial; feed frames in order via `next(_:)`.
public final class VideoConsistencyProcessor {
    private let options: VideoConsistencyOptions
    private let enhance: (CGImage) async throws -> CGImage          // source frame → upscaled RGB (output res)
    private let flow: (CGImage, CGImage) async throws -> DenseFlow  // (curSrc, prevSrc) → cur→prev at source res

    private var prevSource: CGImage?
    private var prevStable: [Float]?            // previous stabilized output, interleaved RGB 0…1
    private var outW = 0, outH = 0

    // Temporal-stability accumulators (pixel-weighted; mean-abs across channels). See `stability()`.
    private var stabTransitions = 0, stabValidPixels = 0
    private var stabInputSum: Double = 0, stabOutputSum: Double = 0

    public init(options: VideoConsistencyOptions = .init(),
                enhance: @escaping (CGImage) async throws -> CGImage,
                flow: @escaping (CGImage, CGImage) async throws -> DenseFlow) {
        self.options = options
        self.enhance = enhance
        self.flow = flow
    }

    /// Process the next source frame in order → its temporally-stabilized upscaled RGB frame.
    public func next(_ sourceFrame: CGImage) async throws -> CGImage {
        let up = try await enhance(sourceFrame)
        let ow = up.width, oh = up.height
        var fresh = Self.rgbFloats(up, width: ow, height: oh)

        if let prevSource, let prevStable, ow == outW, oh == outH {
            let f = try await flow(sourceFrame, prevSource)            // cur→prev at source res
            let upFlow = f.upscaled(toWidth: ow, toHeight: oh)         // scale field to output res
            let (warped, valid) = FlowWarp.backwardWarpChannels(prev: prevStable, width: ow, height: oh,
                                                                channels: 3, flow: upFlow)
            let raw = fresh
            fresh = FlowWarp.confidenceBlendChannels(fresh: raw, warped: warped, valid: valid, channels: 3,
                                                     strength: options.temporalStrength,
                                                     tolerance: options.agreementTolerance)
            accumulateStability(raw: raw, output: fresh, warped: warped, valid: valid)
        }

        prevSource = sourceFrame
        prevStable = fresh
        outW = ow; outH = oh
        return Self.rgbCGImage(fresh, width: ow, height: oh)
    }

    /// Reset between independent clips/shots (clears the temporal history).
    public func reset() { prevSource = nil; prevStable = nil }

    /// Whole-clip motion-compensated temporal stability (flicker) of the enhanced output, or nil if no
    /// transitions were measured.
    public func stability() -> TemporalStability? {
        guard stabTransitions > 0, stabValidPixels > 0 else { return nil }
        return TemporalStability(transitions: stabTransitions,
                                 inputFlicker: Float(stabInputSum / Double(stabValidPixels)),
                                 outputFlicker: Float(stabOutputSum / Double(stabValidPixels)))
    }

    private func accumulateStability(raw: [Float], output: [Float], warped: [Float], valid: [Bool]) {
        var inSum = 0.0, outSum = 0.0, n = 0
        for p in 0..<valid.count where valid[p] {
            let o = p * 3
            var di: Float = 0, dou: Float = 0
            for ch in 0..<3 { di += abs(raw[o + ch] - warped[o + ch]); dou += abs(output[o + ch] - warped[o + ch]) }
            inSum += Double(di / 3); outSum += Double(dou / 3); n += 1
        }
        guard n > 0 else { return }
        stabTransitions += 1; stabValidPixels += n
        stabInputSum += inSum; stabOutputSum += outSum
    }

    // MARK: - RGB CGImage ⇄ interleaved [Float] (0…1, row-major, 3 channels)

    static func rgbFloats(_ image: CGImage, width w: Int, height h: Int) -> [Float] {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var out = [Float](repeating: 0, count: w * h * 3)
        for p in 0..<(w * h) {
            out[p * 3] = Float(bytes[p * 4]) / 255
            out[p * 3 + 1] = Float(bytes[p * 4 + 1]) / 255
            out[p * 3 + 2] = Float(bytes[p * 4 + 2]) / 255
        }
        return out
    }

    static func rgbCGImage(_ buf: [Float], width w: Int, height h: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for p in 0..<(w * h) {
            bytes[p * 4] = UInt8(max(0, min(255, (buf[p * 3] * 255).rounded())))
            bytes[p * 4 + 1] = UInt8(max(0, min(255, (buf[p * 3 + 1] * 255).rounded())))
            bytes[p * 4 + 2] = UInt8(max(0, min(255, (buf[p * 3 + 2] * 255).rounded())))
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}
