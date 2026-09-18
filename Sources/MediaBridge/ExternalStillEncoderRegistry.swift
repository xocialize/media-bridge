//
// ExternalStillEncoderRegistry.swift — MediaBridge
//
// The registration surface for `ExternalStillEncoder`s — the stills twin of
// `ExternalAlphaEncoderRegistry`, and identical in shape for the same reason: the codec lives in the
// REGISTERED package, never here.
//
// A consumer that wants WebP deliverables depends on `webp-swift` too and registers it once at
// startup (`WebPStillEncoder.register()` is the one-liner it ships), after which the floor search can
// race WebP beside the native formats:
//
//     MediaBridge.register(externalStillEncoder: WebPStillEncoder())
//
// With nothing registered, `externalStillEncoder(for: .webp)` returns nil and the caller ships what
// it can write natively. It must never fall back to relabelling other bytes as WebP — a file whose
// extension lies about its codec is the failure mode this seam exists to prevent.
//

import Foundation
import MediaImport

public extension MediaBridge {

    /// Register an encoder for a still format media-bridge can't write natively (today: `.webp`).
    /// Most-recently-registered wins. Typically called once at startup.
    static func register(externalStillEncoder: ExternalStillEncoder) {
        stillEncoderLock.withLock { externalStillEncoders.append(externalStillEncoder) }
    }

    /// Remove all registered external still encoders (teardown / tests).
    static func unregisterAllExternalStillEncoders() {
        stillEncoderLock.withLock { externalStillEncoders.removeAll() }
    }

    /// Whether `format` can be encoded right now — i.e. something is registered for it. Lets a
    /// caller offer only the deliverables that will actually work.
    static func canEncodeStill(_ format: ExternalStillFormat) -> Bool {
        externalStillEncoder(for: format) != nil
    }

    /// The most-recently-registered encoder for `format`, or nil. Public because the consumer of
    /// this registry is not media-bridge's own normalize path but whoever runs the still race —
    /// ForgeOptimizerKit's web profile, for one.
    static func externalStillEncoder(for format: ExternalStillFormat) -> ExternalStillEncoder? {
        stillEncoderLock.withLock { externalStillEncoders.last { $0.format == format } }
    }
}

extension MediaBridge {
    private static let stillEncoderLock = NSLock()
    nonisolated(unsafe) private static var externalStillEncoders: [ExternalStillEncoder] = []
}
