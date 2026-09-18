//
// ExternalStillEncoder.swift — MediaImport
//
// The STILLS twin of `ExternalVideoDecoder` / `ExternalAlphaVideoEncoder`: a pluggable encoder for a
// still format media-bridge cannot write natively, living in a SEPARATE package so that media-bridge
// itself stays pure-Swift and binary-free — the package boundary is the quarantine.
//
// The one format today is WebP. Apple has decoded it natively since macOS 11 but ships no encoder:
// measured on macOS 27.2, `CGImageDestinationCopyTypeIdentifiers()` lists 22 writable types and
// `org.webmproject.webp` is not among them (`CGImageDestinationCreateWithData` returns nil). The only
// encoder is libwebp (BSD-3 + PATENTS), and it lives in `webp-swift`. Registered once, it becomes a
// lane the floor search can race beside HEIC/JPEG/PNG (`ImageQualityTarget.encode(…, encoder:)`).
//
// Register with `MediaBridge.register(externalStillEncoder:)`. With none registered, nothing changes:
// a caller asking `MediaBridge.externalStillEncoder(for: .webp)` gets nil and reports that honestly.
//

import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// A still delivery format media-bridge decodes natively but cannot encode without a plug-in.
public enum ExternalStillFormat: String, Sendable, CaseIterable {
    /// WebP — `org.webmproject.webp`. Lossy (VP8 key frame), lossless (VP8L), alpha in either.
    case webp

    public var utType: UTType { .webP }
    public var fileExtension: String { "webp" }
    public var mimeType: String { "image/webp" }
}

public protocol ExternalStillEncoder: Sendable {
    /// The one format this encoder writes.
    var format: ExternalStillFormat { get }
    /// Whether transparent images may be handed to `encode` — an encoder that cannot carry alpha
    /// must say so, and the caller routes transparency elsewhere (PNG) rather than flattening.
    var supportsAlpha: Bool { get }
    /// Whether `encodeLossless` works.
    var supportsLossless: Bool { get }

    /// Lossy encode at `quality` in [0, 1] — the floor search's knob, normalised. The encoder maps it
    /// onto its own scale and MUST keep the whole range lossy: 1.0 is its best lossy setting, never a
    /// switch into a lossless mode (a search whose top candidate changed codec mode would be
    /// comparing two encoders). The image's alpha state is whatever `image.alphaInfo` says; the
    /// encoder owns the conversion to whatever its bitstream needs (straight alpha, for WebP).
    func encode(_ image: CGImage, quality: Double) throws -> Data

    /// Lossless encode. Throws when `supportsLossless` is false.
    func encodeLossless(_ image: CGImage) throws -> Data
}
