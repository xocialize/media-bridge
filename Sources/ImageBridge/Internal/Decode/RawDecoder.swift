//
// RawDecoder.swift — ImageBridge
//
// Camera RAW → `CVPixelBuffer`, via `CIRAWFilter`.
//
// It converges on the *identical* output contract as every other decoder —
// `(frames: [CVPixelBuffer], metadata: StillMetadata)` — so the orchestrator, the enhance chain, the
// quality search and the encoder never learn the source was RAW. That is the whole design: RAW is a
// better *entry* to the existing pipeline, not a second pipeline.
//

import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class RawDecoderImpl: StillDecoding, @unchecked Sendable {

    private let options: RawDecodeOptions
    private let context: CIContext

    init(options: RawDecodeOptions = .faithful, context: CIContext? = nil) {
        self.options = options
        // Software renderer: decode runs headless and under test, where a GPU CIContext is flaky.
        self.context = context ?? CIContext(options: [.useSoftwareRenderer: true])
    }

    func decode(url: URL) throws -> (frames: [CVPixelBuffer], metadata: StillMetadata) {
        // `CIRAWFilter` returning nil is the honest "this body isn't supported" signal — an unknown
        // camera, or a file that only looks like RAW. Surface it as a deferral rather than a failure:
        // the user's file is fine, we just cannot demosaic it yet.
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw ImageBridgeError.deferred(
                "RAW from this camera isn't supported yet (\(url.pathExtension.uppercased()))")
        }

        apply(options, to: filter)

        // `CIRAWFilter` is permissive: it accepts a file it cannot actually demosaic and hands back an
        // image with a ZERO or INFINITE extent rather than nil. Left unchecked that reaches
        // `makeBuffer` and surfaces as a generic "decode failed", which tells a user their file is
        // broken when the truth is that we cannot read this body yet. Validate the extent here so the
        // deferral stays honest — this is the case the tests caught.
        guard let image = filter.outputImage,
              !image.extent.isEmpty, !image.extent.isInfinite,
              image.extent.width >= 1, image.extent.height >= 1 else {
            throw ImageBridgeError.deferred(
                "RAW from this camera isn't supported yet (\(url.pathExtension.uppercased()))")
        }

        // ⚠️ `CIRAWFilter` has ALREADY applied EXIF orientation — its output is upright. Reporting the
        // file's orientation here would make a downstream consumer rotate a second time, which is the
        // trap BRIDGE-023 named. Report `1` (up), because that is what the pixels now are.
        let buffer = try ImageIODecoderImpl.makeBuffer(from: image, context: context)

        let metadata = StillMetadata(
            format: .raw,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            // P1 narrows to 8-bit BGRA at the buffer boundary; report what the buffer *is*, not what
            // the sensor held, so nothing downstream over-promises latitude it was not handed.
            bitDepth: 8,
            alpha: .none,                       // RAW is opaque sensor data
            iccProfile: nil,
            dpi: Self.dpi(from: url),
            exifOrientation: 1,                 // already applied — see above
            frameCount: 1,
            frameDelays: nil,
            isRaw: true,
            isLinear: false)                    // display-referred in P1

        return ([buffer], metadata)
    }

    // MARK: - Options

    private func apply(_ options: RawDecodeOptions, to filter: CIRAWFilter) {
        switch options.decoderVersion {
        case .osDefault:
            break                               // deliberately unpinned — see RawDecodeOptions
        case .version8:
            if filter.supportedDecoderVersions.contains(.version8) {
                filter.decoderVersion = .version8
            }
        case .version9:
            if filter.supportedDecoderVersions.contains(.version9) {
                filter.decoderVersion = .version9
            }
        }

        // Faithful by default: only touch a knob the caller actually set. Writing `filter.exposure = 0`
        // is not the same as leaving it alone on every decoder version.
        if let ev = options.exposureEV { filter.exposure = ev }
        if let boost = options.boost { filter.boostAmount = boost }
        if let k = options.neutralTemperature { filter.neutralTemperature = k }
        if let tint = options.neutralTint { filter.neutralTint = tint }

        // There is no on/off switch — only an amount. Leaving it alone keeps the decoder's
        // camera-appropriate default, which is what "faithful, noise reduction on" means; turning it
        // off means explicitly zeroing it. Guarded on support because not every body exposes it, and
        // under decoder v9 it has no effect at all — the neural model owns denoise.
        if !options.enableRawNoiseReduction, filter.isColorNoiseReductionSupported {
            filter.colorNoiseReductionAmount = 0
        }
    }

    /// DPI from the file's own metadata, when it carries any. RAW usually does not.
    private static func dpi(from url: URL) -> Double? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        return props[kCGImagePropertyDPIWidth] as? Double
    }
}
