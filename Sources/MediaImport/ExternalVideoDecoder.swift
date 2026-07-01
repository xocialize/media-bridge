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

public protocol ExternalVideoDecoder: Sendable {
    /// Whether this decoder handles the given Matroska CodecID (e.g. "V_VP9", "V_VP8").
    func canDecode(codecID: String) -> Bool

    /// Decode raw codec packets (absolute-ns PTS, straight from the demuxer) to BGRA frames, emitting
    /// each via `onFrame`. Implementations should stream (bounded memory) and emit in PTS order —
    /// media-bridge feeds frames directly into its HEVC encoder, so every `DecodedVideoFrame` must wrap
    /// a BGRA `CVPixelBuffer` with its nanosecond PTS. Mirrors `VideoDecodeSession.decodeStreaming` so
    /// the native and external backends share the exact same downstream encode path.
    func decodeStreaming(codecID: String,
                         codecPrivate: Data?,
                         packets: [(data: Data, ptsNanos: Int64)],
                         onFrame: (DecodedVideoFrame) async throws -> Void) async throws
}
