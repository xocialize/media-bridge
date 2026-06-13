//
// SupportGate.swift — MediaImport
//
// The native-decode-support matrix: a pure `CodecID → SupportStatus` lookup, independent of the
// parser. The convert/normalize layer asks the gate and, on `.deferred`, raises a clear
// "unsupported codec" error WITHOUT failing the demux. This is the clean seam that lets a future
// permissive per-codec fallback (dav1d/libvpx — BSD, never FFmpeg) slot in behind the gate as an
// optional binaryTarget, with the parser unchanged. See MEDIABRIDGE-PLAN.md §4.
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
             "V_AV1":                // AV1   — VideoToolbox HW (M3+), runtime-gated
            return .nativeVideo

        case "A_OPUS",               // AudioToolbox (macOS 14+)
             "A_FLAC",               // AudioToolbox (macOS 10.13+)
             "A_ALAC",               // AudioToolbox
             "A_PCM/INT/LIT", "A_PCM/INT/BIG", "A_PCM/FLOAT/IEEE":
            return .nativeAudio

        case let s where s.hasPrefix("A_AAC"):   // A_AAC and legacy suffixed variants
            return .nativeAudio

        default:
            // V_VP9 / V_VP8 / A_VORBIS / A_AC3 / A_EAC3 / A_DTS* / A_TRUEHD / V_MPEG1 / V_MPEG2 / …
            return .deferred
        }
    }
}
