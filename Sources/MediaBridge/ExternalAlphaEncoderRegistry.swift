//
// ExternalAlphaEncoderRegistry.swift — MediaBridge
//
// The registration surface for `ExternalAlphaVideoEncoder`s — the write-side twin of
// `ExternalDecoderRegistry`, and identical in shape for the same reason: the codec binary lives in
// the REGISTERED package, never here.
//
// media-bridge writes the Apple half of transparent delivery natively (`.mov` + HEVC-with-alpha).
// The non-Apple half — `.webm` + VP9-with-alpha, the only transparent format Chrome, Firefox and
// Edge accept — needs a VP9 encoder, which means libvpx, which media-bridge does not carry. A
// consumer that needs WebM export depends on `vpx-swift` too and registers it once at startup:
//
//     MediaBridge.register(externalAlphaEncoder: VpxTransparentWebMEncoder())
//
// With nothing registered, `transparentEncoder(for: .webmVP9Alpha)` returns nil and the caller
// reports that honestly. It must never fall back to an opaque write — losing transparency in
// silence is the failure mode this whole area exists to prevent.
//

import Foundation
import MediaImport

public extension MediaBridge {

    /// Register an encoder for a transparent delivery format media-bridge can't write natively
    /// (today: `.webmVP9Alpha`). Most-recently-registered wins. Typically called once at startup.
    static func register(externalAlphaEncoder: ExternalAlphaVideoEncoder) {
        alphaEncoderLock.withLock { externalAlphaEncoders.append(externalAlphaEncoder) }
    }

    /// Remove all registered external alpha encoders (teardown / tests).
    static func unregisterAllExternalAlphaEncoders() {
        alphaEncoderLock.withLock { externalAlphaEncoders.removeAll() }
    }

    /// Whether `format` can be written right now — natively, or by something registered. Lets a
    /// caller offer only the export formats that will actually work.
    static func canWriteTransparent(_ format: TransparentVideoFormat) -> Bool {
        format.isNative || externalAlphaEncoder(for: format) != nil
    }
}

extension MediaBridge {
    private static let alphaEncoderLock = NSLock()
    nonisolated(unsafe) private static var externalAlphaEncoders: [ExternalAlphaVideoEncoder] = []

    /// The most-recently-registered encoder that claims `format`, or nil.
    static func externalAlphaEncoder(for format: TransparentVideoFormat) -> ExternalAlphaVideoEncoder? {
        alphaEncoderLock.withLock { externalAlphaEncoders.last { $0.canWrite(format) } }
    }
}
