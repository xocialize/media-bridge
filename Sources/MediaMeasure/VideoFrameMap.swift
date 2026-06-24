import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo

/// Generic **per-frame transform → opaque HEVC** video. Reads `input` frame by frame, runs each through `map`
/// (size-preserving), writes the result. `map` is called **sequentially in frame order**, so it may carry state
/// across frames (e.g. a flow-propagated erase mask). Net-clean (AVFoundation only); the model/flow inject as
/// closures at the app boundary.
///
/// Distinct from `VideoConsistencyPipeline.enhanceToVideo`: that one runs a flow-warp *blend across the whole
/// frame* (right for upscale/colorize flicker, WRONG for erase — it would smear a moving subject). This is a
/// plain map with no cross-frame blending; the per-frame transform owns any temporal logic it wants.
public enum VideoFrameMap {
    public enum MapError: Error { case noVideoTrack }

    @discardableResult
    public static func mapToVideo(input: URL, output: URL, quality: Float = 0.9,
                                  map: (CGImage) async throws -> CGImage) async throws -> Int {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MapError.noVideoTrack }
        let size = try await track.load(.naturalSize)
        let fpsRaw = try await track.load(.nominalFrameRate)
        let w = Int(abs(size.width).rounded()), h = Int(abs(size.height).rounded())
        let fps = Double(fpsRaw > 0 ? fpsRaw : 30)

        let reader = try FrameStream(input)
        return try await OpaqueVideoWriter.writeHEVC(to: output, width: w, height: h, frameRate: fps, quality: quality) {
            guard let frame = reader.next() else { return nil }
            let out = try await map(frame)
            return VideoMattePipeline.bgraBuffer(out, width: w, height: h)   // size-preserving transform
        }
    }
}
