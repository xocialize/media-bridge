import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decodes stills via ImageIO (`CGImageSource`) to BGRA `CVPixelBuffer`s, honoring
/// EXIF orientation and preserving ICC/alpha/DPI into `StillMetadata`. ImageIO
/// hands back packed RGB(A) — NOT NV12 — so the `ensureBGRA()` NV12 assumption from
/// the video path must never be applied here (PRD §4).
final class ImageIODecoderImpl: StillDecoding, @unchecked Sendable {

    /// Shared CIContext for CGImage↔CVPixelBuffer + orientation. Working space is
    /// pinned (sRGB) so we render deterministically; the source ICC is preserved
    /// in metadata and re-tagged on encode (PRD §9, the BT.709-pinning analog).
    private let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// DPI to rasterize vector (PDF) input at. ImageIO raster formats ignore it.
    private let pdfDPI: Double

    private let rawOptions: RawDecodeOptions

    init(pdfDPI: Double = PDFRasterizer.defaultDPI, rawOptions: RawDecodeOptions = .faithful) {
        self.pdfDPI = pdfDPI
        self.rawOptions = rawOptions
    }

    /// RAW by UTType conformance, falling back to an extension allowlist for bodies this OS has no UTI
    /// for. Shared by decode and probe so they cannot disagree about what a file is.
    static func isRaw(_ url: URL) -> Bool {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let ut = CGImageSourceGetType(src) as String?,
           let t = UTType(ut), t.conforms(to: .rawImage) { return true }
        return rawExtensions.contains(url.pathExtension.lowercased())
    }

    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "dng", "pef", "3fr", "iiq", "gpr",
    ]

    func decode(url: URL) throws -> (frames: [CVPixelBuffer], metadata: StillMetadata) {
        if PDFRasterizer.isPDF(url) { return try PDFRasterizer.decode(url: url, dpi: pdfDPI) }
        // RAW before CGImageSource: ImageIO *can* open many RAWs and hand back the embedded preview
        // JPEG, which would silently substitute a baked thumbnail for the sensor data — the exact
        // downstream-of-demosaic position accepting RAW exists to escape.
        if Self.isRaw(url) { return try RawDecoderImpl(options: rawOptions).decode(url: url) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageBridgeError.decodeFailed("CGImageSourceCreateWithURL(\(url.lastPathComponent))")
        }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw ImageBridgeError.decodeFailed("empty image source") }

        let meta = Self.metadata(from: src, url: url, frameCount: count)

        var frames: [CVPixelBuffer] = []
        frames.reserveCapacity(count)
        for i in 0 ..< count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else {
                throw ImageBridgeError.decodeFailed("decode frame \(i)")
            }
            // Honor EXIF orientation so downstream sees upright pixels.
            var ci = CIImage(cgImage: cg)
            if meta.exifOrientation != 1 {
                ci = ci.oriented(forExifOrientation: Int32(meta.exifOrientation))
            }
            frames.append(try Self.makeBuffer(from: ci, context: ciContext))
        }
        return (frames, meta)
    }

    // MARK: - Metadata

    static func metadata(from src: CGImageSource, url: URL, frameCount: Int) -> StillMetadata {
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let depth = (props[kCGImagePropertyDepth] as? Int) ?? 8
        let hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1

        // DPI (explicit, else from JFIF/TIFF blocks).
        let dpi = (props[kCGImagePropertyDPIWidth] as? Double)
            ?? ((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFXResolution] as? Double)

        // Embedded ICC profile, preserved by default.
        var icc: Data?
        if let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
           let cs = cg.colorSpace, let data = cs.copyICCData() {
            icc = data as Data
        }

        let alpha: AlphaMode = {
            guard hasAlpha else { return .none }
            if let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                switch cg.alphaInfo {
                case .premultipliedFirst, .premultipliedLast: return .premultiplied
                default: return .straight
                }
            }
            return .straight
        }()

        let fmt = Self.format(from: src, url: url)
        return StillMetadata(
            format: fmt,
            width: w, height: h, bitDepth: depth, alpha: alpha,
            iccProfile: icc, dpi: dpi, exifOrientation: orientation, frameCount: frameCount,
            frameDelays: frameCount > 1 ? Self.frameDelays(from: src, count: frameCount, format: fmt) : nil
        )
    }

    /// Per-frame display durations (seconds) for animated GIF/APNG — drives §7
    /// animated→video timing. Prefers the unclamped delay; falls back to the clamped
    /// value, then a 10 fps default for any missing/zero entry (matches browser behaviour).
    static func frameDelays(from src: CGImageSource, count: Int, format: StillFormat) -> [Double]? {
        guard format == .gif || format == .png else { return nil }   // APNG reports as .png
        var delays: [Double] = []
        delays.reserveCapacity(count)
        for i in 0 ..< count {
            let props = (CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]) ?? [:]
            var d = 0.0
            if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            } else if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
                d = (png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
                    ?? (png[kCGImagePropertyAPNGDelayTime] as? Double) ?? 0
            }
            delays.append(d > 0.0001 ? d : 0.1)
        }
        return delays.isEmpty ? nil : delays
    }

    static func format(from src: CGImageSource, url: URL) -> StillFormat {
        if let ut = CGImageSourceGetType(src) as String? {
            switch ut {
            case UTType.png.identifier: return .png
            case UTType.jpeg.identifier: return .jpeg
            case UTType.tiff.identifier: return .tiff
            case UTType.heic.identifier, "public.heif": return .heic
            case "public.avif": return .avif
            case UTType.bmp.identifier: return .bmp
            case UTType.gif.identifier: return .gif
            default:
                // Camera RAW has no single UTI — every vendor declares its own, all conforming to
                // `public.camera-raw-image`. Ask the conformance rather than enumerate 784 bodies.
                if let t = UTType(ut), t.conforms(to: .rawImage) { return .raw }
            }
        }
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "tif", "tiff": return .tiff
        case "heic", "heif": return .heic
        case "avif": return .avif
        case "bmp": return .bmp
        case "gif": return .gif
        // Belt-and-braces: a body whose UTI this OS does not know still routes to the RAW decoder,
        // which then either decodes it or defers honestly — better than falling through to `.unknown`,
        // which reads as "not an image".
        case "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "dng", "pef", "3fr", "iiq", "gpr":
            return .raw
        default: return .unknown
        }
    }

    // MARK: - CIImage → CVPixelBuffer (BGRA, IOSurface-backed)

    /// `pixelFormat` is parameterized so P2 (16-bit latitude) is a call-site change rather than a
    /// rewrite of every decode path. P1 passes 32BGRA everywhere.
    static func makeBuffer(from ci: CIImage, context: CIContext,
                           pixelFormat: OSType = kCVPixelFormatType_32BGRA,
                           colorSpace: CGColorSpace? = nil) throws -> CVPixelBuffer {
        let w = Int(ci.extent.width.rounded()), h = Int(ci.extent.height.rounded())
        guard w > 0, h > 0 else { throw ImageBridgeError.decodeFailed("zero-size image") }
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(nil, w, h, pixelFormat,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else {
            throw ImageBridgeError.decodeFailed("CVPixelBufferCreate \(w)x\(h)")
        }
        // Render at the image's origin (oriented images can have a non-zero extent).
        context.render(ci, to: buffer, bounds: CGRect(x: ci.extent.origin.x, y: ci.extent.origin.y,
                                                       width: CGFloat(w), height: CGFloat(h)),
                       colorSpace: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
        return buffer
    }
}

/// Probe = decode's metadata path without materialising pixels.
final class ImageIOProbeImpl: StillMediaProbing, @unchecked Sendable {
    private let pdfDPI: Double
    init(pdfDPI: Double = PDFRasterizer.defaultDPI) { self.pdfDPI = pdfDPI }

    func probe(url: URL) throws -> StillMetadata {
        if PDFRasterizer.isPDF(url) { return try PDFRasterizer.probe(url: url, dpi: pdfDPI) }
        // Probing a RAW through CGImageSource would describe the embedded preview — wrong dimensions,
        // `isRaw: false`. Decode it so probe and decode cannot disagree.
        if ImageIODecoderImpl.isRaw(url) {
            return try RawDecoderImpl().decode(url: url).metadata
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageBridgeError.decodeFailed("CGImageSourceCreateWithURL(\(url.lastPathComponent))")
        }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw ImageBridgeError.decodeFailed("empty image source") }
        return ImageIODecoderImpl.metadata(from: src, url: url, frameCount: count)
    }
}
