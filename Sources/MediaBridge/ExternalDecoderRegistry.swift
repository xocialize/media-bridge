//
// ExternalDecoderRegistry.swift — MediaBridge
//
// The registration surface for `ExternalVideoDecoder`s. media-bridge consults this registry when it
// hits a codec it can't decode natively; a registered decoder (living in a SEPARATE package, e.g. a
// libvpx-backed VP9 package) rescues the codec without media-bridge ever carrying a decoder binary.
// With nothing registered, behavior is unchanged — the codec defers.
//

import Foundation
import MediaImport

public extension MediaBridge {

    /// Register a decoder for codecs media-bridge doesn't handle natively (VP9/VP8/…). The decoder — and
    /// its binary — live in the REGISTERED package, never in media-bridge; this seam is what keeps
    /// media-bridge pure-Swift and binary-free while a consumer (e.g. Forge, via a libvpx package) opts
    /// into extra codecs. Most-recently-registered wins when two decoders claim the same codec. Typically
    /// called once at app startup.
    static func register(externalDecoder: ExternalVideoDecoder) {
        registryLock.withLock { externalDecoders.append(externalDecoder) }
    }

    /// Remove all registered external decoders (teardown / tests).
    static func unregisterAllExternalDecoders() {
        registryLock.withLock { externalDecoders.removeAll() }
    }
}

extension MediaBridge {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var externalDecoders: [ExternalVideoDecoder] = []

    /// The most-recently-registered decoder that claims `codecID`, or nil. Internal — the normalizer's
    /// hand-off point.
    static func externalDecoder(for codecID: String) -> ExternalVideoDecoder? {
        registryLock.withLock { externalDecoders.last { $0.canDecode(codecID: codecID) } }
    }
}
