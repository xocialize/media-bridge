import CoreVideo
import Foundation

// Public still-image models (ImageBridge-PRD §3/§8). New to the still path;
// reuses FormatBridge enums (OptimizationLevel, QualityPreset, ColorSpaceInfo)
// where they apply rather than redefining.

/// Input still container formats ImageBridge can decode (ImageIO; `pdf` via CoreGraphics).
public enum StillFormat: String, Sendable, CaseIterable {
    case png, jpeg, tiff, heic, avif, bmp, gif
    case pdf            // rasterized per page (multi-page → sequence)
    case unknown
}

/// Output still formats. Ship tier = native ImageIO (HEIC/JPEG/PNG/TIFF, ADR-0020);
/// AVIF is also native on macOS 13+ (royalty-free next-gen — the still analog of the
/// AV1 video tier). WebP would need a vendored libwebp; deferred (AVIF supersedes it).
public enum StillOutputFormat: String, Sendable, CaseIterable {
    case png, jpeg, tiff, heic, avif
}

/// How alpha is carried. Stills routinely have alpha; the AI models are trained
/// on opaque RGB, so alpha must be unassociated before processing and recombined
/// after (Phase 3). Phase 1 preserves it through the round-trip.
public enum AlphaMode: String, Sendable {
    case none           // opaque
    case straight       // unassociated (un-premultiplied)
    case premultiplied  // associated
}

/// Sidecar metadata extracted at decode and (optionally) re-applied at encode.
public struct StillMetadata: Sendable {
    public let format: StillFormat
    public let width: Int
    public let height: Int
    public let bitDepth: Int            // bits per component (8 / 16)
    public let alpha: AlphaMode
    public let iccProfile: Data?        // embedded colour profile, preserved by default
    public let dpi: Double?             // pixels-per-inch, when present
    public let exifOrientation: Int     // 1…8 (TIFF/EXIF); 1 = up
    public let frameCount: Int          // >1 = animated/multi-page → sequence path (§7)
    /// Per-frame display durations in seconds (animated GIF/APNG); nil for stills and
    /// untimed multi-page sources (PDF/TIFF). Drives animated→video frame timing (§7).
    public let frameDelays: [Double]?

    public init(format: StillFormat, width: Int, height: Int, bitDepth: Int,
                alpha: AlphaMode, iccProfile: Data?, dpi: Double?,
                exifOrientation: Int, frameCount: Int, frameDelays: [Double]? = nil) {
        self.format = format
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.alpha = alpha
        self.iccProfile = iccProfile
        self.dpi = dpi
        self.exifOrientation = exifOrientation
        self.frameCount = frameCount
        self.frameDelays = frameDelays
    }
}

/// Encode parameters (still analog of `VideoEncoderSettings`).
public struct StillEncoderSettings: Sendable {
    public let format: StillOutputFormat
    /// Lossy quality in [0, 1] (JPEG/HEIC). Ignored for PNG/TIFF (lossless).
    public let quality: Double
    /// Drop ICC/EXIF/DPI on write (oxipng `--strip` analog). Default: preserve.
    public let stripMetadata: Bool
    /// Run the lossless PNG optimizer (oxipng) after writing a PNG — the
    /// "pngcrush but keeps quality" pass. Lossless ⇒ pixels preserved exactly.
    /// No effect on non-PNG formats. Default: on for PNG.
    public let losslessOptimize: Bool
    /// oxipng preset 0…6 (higher = slower / smaller). Default 4 (good ratio/speed).
    public let optimizeLevel: UInt8

    public init(format: StillOutputFormat, quality: Double = 0.9, stripMetadata: Bool = false,
                losslessOptimize: Bool = true, optimizeLevel: UInt8 = 4) {
        self.format = format
        self.quality = max(0, min(1, quality))
        self.stripMetadata = stripMetadata
        self.losslessOptimize = losslessOptimize
        self.optimizeLevel = min(6, optimizeLevel)
    }
}
