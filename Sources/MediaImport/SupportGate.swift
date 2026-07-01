//
// SupportGate.swift — MediaImport
//
// The native-decode-support matrix: a pure `CodecID → SupportStatus` lookup, independent of the
// parser. The convert/normalize layer asks the gate and, on `.deferred`, either hands off to a
// registered `ExternalVideoDecoder` or raises a clear "unsupported codec" error — WITHOUT failing the
// demux. A `.deferred` codec (VP9/VP8/…) is re-enabled by a permissive decoder (e.g. libvpx — BSD,
// never FFmpeg) that lives in a SEPARATE package and plugs in via `MediaBridge.register(externalDecoder:)`,
// so the binary never enters media-bridge. See MEDIABRIDGE-PLAN.md §4 + DEFERRED-CODEC-PLAN.md §9.
//

import Foundation

public enum SupportStatus: Sendable, Equatable {
    case nativeVideo
    case nativeAudio
    /// Demux succeeds; native decode unavailable. Surfaced, not silently failed.
    case deferred
}

public enum SupportGate {

    /// Static native-support verdict for a Matroska CodecID. NOTE: AV1 (`V_AV1`) is reported
    /// `.nativeVideo` here but must additionally be runtime-gated by
    /// `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` at decode time (HW only, M3+).
    public static func status(forCodecID id: String) -> SupportStatus {
        switch id {
        case "V_MPEG4/ISO/AVC",      // H.264 — VideoToolbox HW
             "V_MPEGH/ISO/HEVC",     // HEVC  — VideoToolbox HW
             "V_AV1",                // AV1   — VideoToolbox HW (M3+), runtime-gated by VTIsHardwareDecodeSupported
             "V_MPEG2", "V_MPEG1":   // MPEG-1/2 — legacy VideoToolbox decoder, availability machine-
            return .nativeVideo      //            dependent → runtime-gated by session-create success.

        case "A_OPUS",               // AudioToolbox (macOS 14+)
             "A_FLAC",               // AudioToolbox (macOS 10.13+)
             "A_ALAC",               // AudioToolbox
             "A_AC3",                // AudioToolbox (macOS 10.2+)
             "A_EAC3",               // AudioToolbox (macOS 10.11+)
             "A_MPEG/L1", "A_MPEG/L2", "A_MPEG/L3",   // AudioToolbox MPEG Layer I/II/III
             "A_PCM/INT/LIT", "A_PCM/INT/BIG", "A_PCM/FLOAT/IEEE":
            return .nativeAudio

        case let s where s.hasPrefix("A_AAC"):   // A_AAC and legacy suffixed variants
            return .nativeAudio

        default:
            // V_VP9 / V_VP8 / A_VORBIS / A_DTS* / A_TRUEHD / …
            // NOTE: VP9 has NO native decode on Apple Silicon — VTDecompressionSessionCreate returns
            // kVTCouldNotFindVideoDecoderErr (-12906), and AVFoundation can't read a VP9 track either
            // (verified macOS 27, M-series 2026-07-01). Apple's "macOS 11 VP9" is Safari-internal only.
            // Re-enable path is permissive libvpx (BSD) as an optional binaryTarget, deferred until needed.
            return .deferred
        }
    }
}
