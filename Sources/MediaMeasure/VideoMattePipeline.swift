import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

/// End-to-end **automatic video matting**: read a clip's frames, compute a per-frame soft-alpha matte with
/// flow-guided temporal stabilization (V1a `VideoMatteProcessor` over injected matte/flow seams), composite
/// the cutout (foreground over transparent, alpha = the stabilized matte), and write a **ProRes 4444 `.mov`
/// with alpha** (V1b `AlphaVideoWriter`). Net-clean: the BiRefNet (matte) + SEA-RAFT (flow) models are
/// injected closures, converted at the app boundary, so this package stays MLX-free.
public enum VideoMattePipeline {
    public enum PipelineError: Error { case noVideoTrack, composeFailed }

    /// Matte `input` → ProRes 4444 cutout at `output`. Returns frames written.
    @discardableResult
    public static func matteToProRes4444(
        input: URL, output: URL, options: VideoMatteOptions = .init(),
        matte: @escaping (CGImage) async throws -> CGImage,
        flow: @escaping (CGImage, CGImage) async throws -> DenseFlow
    ) async throws -> Int {
        try await matteToProRes4444Measured(input: input, output: output, options: options,
                                            matte: matte, flow: flow).framesWritten
    }

    /// As `matteToProRes4444`, but also returns the motion-compensated temporal-stability metric (the flicker
    /// gate) — residual jitter of the stabilized matte and how much the temporal blend removed.
    @discardableResult
    public static func matteToProRes4444Measured(
        input: URL, output: URL, options: VideoMatteOptions = .init(),
        matte: @escaping (CGImage) async throws -> CGImage,
        flow: @escaping (CGImage, CGImage) async throws -> DenseFlow
    ) async throws -> VideoMatteOutcome {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PipelineError.noVideoTrack
        }
        let size = try await track.load(.naturalSize)
        let fpsRaw = try await track.load(.nominalFrameRate)
        let w = Int(abs(size.width).rounded()), h = Int(abs(size.height).rounded())
        let fps = Double(fpsRaw > 0 ? fpsRaw : 30)

        let reader = try FrameStream(input)
        let proc = VideoMatteProcessor(options: options, matte: matte, flow: flow)
        // Color-management OFF: the matte is coverage (alpha), not colour — a managed working space would
        // gamma-linearize the grayscale mask (0.5 → ~0.21) and shift it. Raw also passes source RGB through
        // unchanged for a faithful cutout.
        let ci = CIContext(options: [.workingColorSpace: NSNull()])

        let frames = try await AlphaVideoWriter.writeProRes4444(to: output, width: w, height: h, frameRate: fps) {
            guard let frame = reader.next() else { return nil }
            let stable = try await proc.next(frame)                 // matte + flow + temporal blend
            guard let cutout = Self.compose(frame: frame, matte: stable, ci: ci) else {
                throw PipelineError.composeFailed
            }
            return cutout
        }
        return VideoMatteOutcome(framesWritten: frames, stability: proc.stability())
    }

    /// Run the matte pipeline but, instead of compositing a cutout, map each **temporally-stabilized matte**
    /// through `transform` and write the result as an opaque video — the basis for a **control-mask** sequence
    /// (matte → discrete palette frame), distinct from the alpha cutout. `transform` MUST preserve frame size.
    /// Uses the ProRes 4444 writer (visually lossless, so a hard palette survives the downstream >225 threshold).
    @discardableResult
    public static func mattesToVideo(
        input: URL, output: URL, options: VideoMatteOptions = .init(),
        matte: @escaping (CGImage) async throws -> CGImage,
        flow: @escaping (CGImage, CGImage) async throws -> DenseFlow,
        transform: @escaping (CGImage) throws -> CGImage
    ) async throws -> VideoMatteOutcome {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PipelineError.noVideoTrack
        }
        let size = try await track.load(.naturalSize)
        let fpsRaw = try await track.load(.nominalFrameRate)
        let w = Int(abs(size.width).rounded()), h = Int(abs(size.height).rounded())
        let fps = Double(fpsRaw > 0 ? fpsRaw : 30)

        let reader = try FrameStream(input)
        let proc = VideoMatteProcessor(options: options, matte: matte, flow: flow)
        let frames = try await AlphaVideoWriter.writeProRes4444(to: output, width: w, height: h, frameRate: fps) {
            guard let frame = reader.next() else { return nil }
            let stable = try await proc.next(frame)
            let outFrame = try transform(stable)
            guard let pb = Self.bgraBuffer(outFrame, width: w, height: h) else { throw PipelineError.composeFailed }
            return pb
        }
        return VideoMatteOutcome(framesWritten: frames, stability: proc.stability())
    }

    /// Render an opaque RGB `CGImage` into a premultiplied-BGRA `CVPixelBuffer` (alpha 255 → premult is identity,
    /// so palette colours pass through unchanged). No colour management — the mask carries labels, not colour.
    static func bgraBuffer(_ image: CGImage, width w: Int, height h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf),
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    /// Composite foreground over transparent using the matte as alpha → premultiplied-BGRA `CVPixelBuffer`
    /// (the form `AlphaVideoWriter` encodes). Colour-preserving (`blendWithMask` keeps source RGB).
    static func compose(frame: CGImage, matte: CGImage, ci: CIContext) -> CVPixelBuffer? {
        let w = frame.width, h = frame.height
        let blend = CIFilter.blendWithMask()
        blend.inputImage = CIImage(cgImage: frame)
        blend.backgroundImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        blend.maskImage = CIImage(cgImage: matte)
        guard let out = blend.outputImage else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let buf = pb else { return nil }
        ci.render(out, to: buf)
        return buf
    }
}
