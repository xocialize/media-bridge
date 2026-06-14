import Foundation

/// Public entry point — mirrors `FormatBridgeFactory` (PRD §8). Phase 1 wires the
/// native ImageIO probe/decode/encode + the passthrough orchestrator. The
/// quality-target encoder (still analog of the VMAF-target search) lands in
/// Phase 2 with the `StillQualityScoring` seam.
public enum ImageBridgeFactory {

    /// Default DPI for rasterizing vector (PDF) input. ImageIO raster formats ignore it.
    public static let defaultPDFDPI: Double = 150

    public static func makeProbe(pdfDPI: Double = defaultPDFDPI) -> any StillMediaProbing {
        ImageIOProbeImpl(pdfDPI: pdfDPI)
    }

    public static func makeDecoder(pdfDPI: Double = defaultPDFDPI) -> any StillDecoding {
        ImageIODecoderImpl(pdfDPI: pdfDPI)
    }

    public static func makeEncoder() -> any StillEncoding {
        ImageIOEncoderImpl()
    }

    /// End-to-end orchestrator. Pass a `ForgeOptimizer.ModelChain` as the
    /// `frameProcessor` at the call site to run the AI chain unchanged; `nil`
    /// (the default) is a passthrough conversion. `pdfDPI` controls vector
    /// rasterization (raise it for crisp small text on signage maps).
    public static func makeOrchestrator(pdfDPI: Double = defaultPDFDPI) -> any StillConversionOrchestrating {
        StillConversionOrchestratorImpl(decoder: ImageIODecoderImpl(pdfDPI: pdfDPI), encoder: ImageIOEncoderImpl())
    }

    // Quality-targeted still encoding lives in `MediaMeasure.ImageQualityTarget` (pure-Swift
    // SSIMULACRA2 oracle). Lossless-PNG oxipng and animated→video were dropped in the media-bridge
    // salvage (vendored liboxipng binary; video-encode coupling) — see CLAUDE.md.
}
