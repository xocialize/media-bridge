//
// RawDecodeOptions.swift — ImageBridge
//
// How a camera RAW is demosaiced. **Faithful by default**: every adjustment is opt-in, so an untouched
// `.faithful` reproduces what the camera metadata asks for rather than an opinionated "look". Forge's
// job downstream is to optimise without visibly changing the image; starting from a silently graded
// decode would make that claim meaningless.
//

import Foundation

public struct RawDecodeOptions: Sendable, Equatable {

    /// Which Apple RAW decoder generation to use. **Default is the OS default** — deliberately not
    /// pinned.
    ///
    /// Version 9 replaces separate demosaic and denoise with a single tiled CoreML model on the ANE.
    /// Under it `colorNoiseReductionAmount` has no effect and `detailAmount` / `moireReductionAmount`
    /// are unsupported: the neural model owns denoise and cannot be switched off. Pinning `.version8`
    /// is the only way to make *your own* denoise the one that matters — a real trade, so it is
    /// exposed rather than decided here.
    ///
    /// ⚠️ v9 was still marked beta at last check; behaviour may shift before the GM.
    public enum DecoderVersion: Sendable, Equatable {
        case osDefault
        /// Classical demosaic — the only version whose denoise knobs still respond.
        case version8
        /// Neural joint demosaic + denoise on the ANE.
        case version9
    }

    public var decoderVersion: DecoderVersion

    /// Keep more than 8 bits per component through the buffer boundary.
    ///
    /// **P1 ships `false` and this is not yet honoured** — the buffer is narrowed to 8-bit BGRA so
    /// nothing downstream (model adapters, the encoder, the quality search) has to learn RAW exists.
    /// It is declared now so 16-bit latitude is an additive flip in P2 rather than a rework, and so the
    /// option's absence is visible instead of implied.
    public var preserveHighBitDepth: Bool

    /// Exposure adjustment in stops. 0 = as shot.
    public var exposureEV: Float?
    /// Shadow/highlight boost, 0…1. nil = the decoder's default for this camera.
    public var boost: Float?
    /// White-balance temperature in kelvin. nil = as shot.
    public var neutralTemperature: Float?
    /// White-balance tint. nil = as shot.
    public var neutralTint: Float?
    /// RAW-domain noise reduction. **Default true** — this is the demosaic-from-sensor win, and under
    /// decoder v9 it is the neural model's joint denoise rather than a separate pass.
    public var enableRawNoiseReduction: Bool

    public init(decoderVersion: DecoderVersion = .osDefault,
                preserveHighBitDepth: Bool = false,
                exposureEV: Float? = nil,
                boost: Float? = nil,
                neutralTemperature: Float? = nil,
                neutralTint: Float? = nil,
                enableRawNoiseReduction: Bool = true) {
        self.decoderVersion = decoderVersion
        self.preserveHighBitDepth = preserveHighBitDepth
        self.exposureEV = exposureEV
        self.boost = boost
        self.neutralTemperature = neutralTemperature
        self.neutralTint = neutralTint
        self.enableRawNoiseReduction = enableRawNoiseReduction
    }

    /// As the camera recorded it, with RAW noise reduction on. The shipping default.
    public static let faithful = RawDecodeOptions()
}
