//
// ExternalVideoDecoder.swift — MediaImport
//
// A pluggable decoder for a container codec media-bridge does NOT decode natively (VP9/VP8/…). This is
// the seam that lets a SEPARATE package supply the decode so media-bridge itself carries no decoder
// binary — the package boundary is the demarcation. A permissive-but-binary decoder (e.g. libvpx, BSD)
// lives entirely in the registered package; media-bridge stays pure-Swift and binary-free.
//
// Register with `MediaBridge.register(externalDecoder:)`. With none registered, an unsupported codec
// defers exactly as before (zero behavior change). See DEFERRED-CODEC-PLAN.md.
//

import CoreVideo
import Foundation

/// One frame's compressed data, plus the alpha stream that travels beside it.
///
/// VP9-in-WebM does not store alpha as a fourth plane — it stores a **second complete VP9 stream** in
/// each block's Matroska `BlockAdditional`, whose luma plane is that frame's alpha. That is why this is
/// a struct rather than the `(data:ptsNanos:)` tuple it replaces: a tuple had nowhere to put the second
/// stream, so alpha was structurally undeliverable to a decoder no matter how capable.
public struct ExternalVideoPacket: Sendable {
    public let data: Data
    public let ptsNanos: Int64
    /// The alpha stream's packet for this frame, or `nil` for an opaque source.
    public let alpha: Data?

    public init(data: Data, ptsNanos: Int64, alpha: Data? = nil) {
        self.data = data
        self.ptsNanos = ptsNanos
        self.alpha = alpha
    }
}

public protocol ExternalVideoDecoder: Sendable {
    /// Whether this decoder handles the given Matroska CodecID (e.g. "V_VP9", "V_VP8").
    func canDecode(codecID: String) -> Bool

    /// Whether this decoder reads `ExternalVideoPacket.alpha` and returns frames with a real alpha
    /// channel, rather than ignoring it.
    ///
    /// **Defaults to `false`, and that default is the safe one.** A decoder that ignores the alpha
    /// stream still produces a complete, plausible, entirely opaque image — there is no error, no
    /// missing frame, nothing to notice. media-bridge therefore cannot infer this and must be told, so
    /// that it can refuse an alpha-preserving export rather than quietly writing a flattened one.
    var decodesAlpha: Bool { get }

    /// Decode raw codec packets (absolute-ns PTS, straight from the demuxer) to BGRA frames, emitting
    /// each via `onFrame`. Implementations should stream (bounded memory) and emit in PTS order —
    /// media-bridge feeds frames directly into its HEVC encoder, so every `DecodedVideoFrame` must wrap
    /// a BGRA `CVPixelBuffer` with its nanosecond PTS. Mirrors `VideoDecodeSession.decodeStreaming` so
    /// the native and external backends share the exact same downstream encode path.
    func decodeStreaming(codecID: String,
                         codecPrivate: Data?,
                         packets: [ExternalVideoPacket],
                         onFrame: (DecodedVideoFrame) async throws -> Void) async throws
}

public extension ExternalVideoDecoder {
    /// Opaque unless a decoder says otherwise — see the note on the requirement.
    var decodesAlpha: Bool { false }
}
