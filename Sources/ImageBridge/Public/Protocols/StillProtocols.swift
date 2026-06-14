import CoreVideo
import Foundation

// Public protocol surface — mirrors FormatBridge's probing/decoding/encoding
// seam so the still path is independent of which impl backs it (ImageBridge-PRD §8).

/// Probe a still's shape + metadata without fully decoding pixels.
public protocol StillMediaProbing: Sendable {
    func probe(url: URL) throws -> StillMetadata
}

/// Decode a still (or animated/multi-page sequence) to pixel buffers + metadata.
public protocol StillDecoding: Sendable {
    /// `frames` has count 1 for a still; >1 for animated/multi-page (sequence path).
    func decode(url: URL) throws -> (frames: [CVPixelBuffer], metadata: StillMetadata)
}

/// Encode one pixel buffer to a still file via a native (ImageIO) destination.
public protocol StillEncoding: Sendable {
    func encode(_ pixelBuffer: CVPixelBuffer, settings: StillEncoderSettings,
                metadata: StillMetadata?, to url: URL) throws
}

/// End-to-end: decode → run the injected `FrameProcessor` (ForgeOptimizer chain,
/// reused unchanged) → encode. A `nil` processor is a passthrough (no-op).
public protocol StillConversionOrchestrating: Sendable {
    /// Single-output conversion. A multi-page/animated source emits frame/page 1 only
    /// (use `convertSequence` for all pages).
    func convert(input: URL, output: URL, settings: StillEncoderSettings,
                 frameProcessor: (any FrameProcessor)?) throws

    /// Multi-page/animated → one file per frame, named `<output-stem>-NNN.<ext>` beside
    /// `output` (1-based, zero-padded). A single-frame source writes `output` itself.
    /// Returns the written files in page order (PRD §7 multi-page-PDF disposition).
    @discardableResult
    func convertSequence(input: URL, output: URL, settings: StillEncoderSettings,
                         frameProcessor: (any FrameProcessor)?) throws -> [URL]
}
