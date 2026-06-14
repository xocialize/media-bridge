import CoreVideo
import Foundation

// Shared per-frame execution of the (opaque-RGB) FrameProcessor with alpha handled at
// the boundary (PRD §4): a buffer with transparency is un-premultiplied → processed →
// recombined, so the models never see premultiplied RGBA. No processor / no alpha → direct.
// Used by both the still orchestrator and the animated→video converter.
enum FrameRun {
    static func run(_ buffer: CVPixelBuffer, processor: (any FrameProcessor)?, alpha: AlphaMode) -> CVPixelBuffer {
        guard let fp = processor else { return buffer }          // passthrough preserves alpha as-is
        guard alpha != .none, let (opaque, plane) = AlphaSplitter.split(buffer) else {
            return fp.process(buffer)                            // opaque → process directly
        }
        let processedRGB = fp.process(opaque)
        return AlphaSplitter.recombine(rgb: processedRGB, alpha: plane) ?? processedRGB
    }
}
