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

        return try await AlphaVideoWriter.writeProRes4444(to: output, width: w, height: h, frameRate: fps) {
            guard let frame = reader.next() else { return nil }
            let stable = try await proc.next(frame)                 // matte + flow + temporal blend
            guard let cutout = Self.compose(frame: frame, matte: stable, ci: ci) else {
                throw PipelineError.composeFailed
            }
            return cutout
        }
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
