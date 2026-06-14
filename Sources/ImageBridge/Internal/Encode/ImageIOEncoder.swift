import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes a BGRA `CVPixelBuffer` to a still file via ImageIO `CGImageDestination`
/// (PRD §5 ship tier: HEIC/JPEG/PNG/TIFF — Apple frameworks, $0 SPDX). Preserves
/// ICC + DPI by default; re-tags the working space (PRD §9). Strips metadata only
/// when the caller opts in.
final class ImageIOEncoderImpl: StillEncoding, @unchecked Sendable {

    private let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    func encode(_ pixelBuffer: CVPixelBuffer, settings: StillEncoderSettings,
                metadata: StillMetadata?, to url: URL) throws {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        // Tag the output with the source ICC if preserved, else sRGB (never
        // untagged — the still analog of the BT.709 untagged-drift lesson).
        let outputCS: CGColorSpace = {
            if !settings.stripMetadata, let icc = metadata?.iccProfile,
               let cs = CGColorSpace(iccData: icc as CFData) { return cs }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        guard let cg = ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: outputCS) else {
            throw ImageBridgeError.encodeFailed("createCGImage")
        }

        let utType = Self.utType(settings.format)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil) else {
            throw ImageBridgeError.encodeFailed("CGImageDestinationCreateWithURL(\(url.lastPathComponent))")
        }

        // ICC is embedded via the CGImage's own colour space (set above to the
        // source profile when preserved). Only quality + DPI go in the props dict.
        var props: [CFString: Any] = [:]
        if settings.format == .jpeg || settings.format == .heic || settings.format == .avif {
            props[kCGImageDestinationLossyCompressionQuality] = settings.quality
        }
        if !settings.stripMetadata, let dpi = metadata?.dpi {
            props[kCGImagePropertyDPIWidth] = dpi
            props[kCGImagePropertyDPIHeight] = dpi
        }

        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageBridgeError.encodeFailed("CGImageDestinationFinalize")
        }
        // NOTE: the oxipng lossless-PNG recompression pass was dropped in the media-bridge salvage
        // (it vendored a 6.2 MB liboxipng_shim.a — incompatible with the no-binary, net-clean
        // doctrine). ImageIO's PNG output is used as-is; a pure-Swift PNG optimizer could restore it.
        _ = settings.losslessOptimize
    }

    static func utType(_ f: StillOutputFormat) -> UTType {
        switch f {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .heic: return .heic
        case .avif: return UTType("public.avif") ?? .heic   // native ImageIO encode (macOS 13+)
        }
    }
}
