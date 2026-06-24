import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo

/// End-to-end **temporally-consistent video upscale/enhance** (Forge V4b): read a clip, run each frame through
/// the injected enhance seam (Real-ESRGAN / SeedVR2) with flow-guided temporal stabilization
/// (`VideoConsistencyProcessor` over a SEA-RAFT flow seam), and write the result as an opaque HEVC `.mp4`.
/// Net-clean: the SR + flow models are injected closures, converted at the app boundary, so this stays MLX-free.
///
/// The enhanced frames are larger than the source (super-resolution), and the output size isn't known until the
/// first frame is enhanced — so we peek frame 0 to size the writer, then stream the rest.
public enum VideoConsistencyPipeline {
    public enum PipelineError: Error { case noVideoTrack, emptyClip }

    /// Upscale/enhance `input` → temporally-stabilized HEVC `.mp4` at `output`. Returns frames written + the
    /// temporal-stability metric (how much flicker the stabilization removed).
    @discardableResult
    public static func enhanceToVideo(
        input: URL, output: URL, options: VideoConsistencyOptions = .init(), quality: Float = 0.9,
        enhance: @escaping (CGImage) async throws -> CGImage,
        flow: @escaping (CGImage, CGImage) async throws -> DenseFlow
    ) async throws -> VideoMatteOutcome {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PipelineError.noVideoTrack
        }
        let fpsRaw = try await track.load(.nominalFrameRate)
        let fps = Double(fpsRaw > 0 ? fpsRaw : 30)

        let reader = try FrameStream(input)
        let proc = VideoConsistencyProcessor(options: options, enhance: enhance, flow: flow)

        // Peek frame 0 to learn the enhanced output resolution (SR changes dimensions), then stream the rest.
        guard let first = reader.next() else { throw PipelineError.emptyClip }
        let firstOut = try await proc.next(first)
        let ow = firstOut.width, oh = firstOut.height
        var pending: CGImage? = firstOut

        let frames = try await OpaqueVideoWriter.writeHEVC(
            to: output, width: ow, height: oh, frameRate: fps, quality: quality
        ) {
            if let p = pending {                                    // emit the already-enhanced frame 0
                pending = nil
                return VideoMattePipeline.bgraBuffer(p, width: ow, height: oh)
            }
            guard let src = reader.next() else { return nil }
            let out = try await proc.next(src)
            return VideoMattePipeline.bgraBuffer(out, width: ow, height: oh)
        }
        return VideoMatteOutcome(framesWritten: frames, stability: proc.stability())
    }
}
