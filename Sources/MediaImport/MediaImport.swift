//
// MediaImport.swift — MediaImport
//
// The native-decode layer: turns MatroskaDemux packets into decoded CVPixelBuffers / PCM via
// VideoToolbox / AudioToolbox. Composed of the SupportGate (CodecID → native/deferred), a
// FormatDescriptionFactory (CodecPrivate → CMFormatDescription), and decode-session management.
//
// Phases 2–3 of MEDIABRIDGE-PLAN.md. SupportGate.swift already lands the gate; the factory and
// decode sessions follow.
//

import Foundation

// TODO(Phase 2): FormatDescriptionFactory
//   - H.264 (avcC) → CMVideoFormatDescriptionCreateFromH264ParameterSets (nalUnitHeaderLength = 4)
//   - HEVC  (hvcC) → CMVideoFormatDescriptionCreateFromHEVCParameterSets (VPS+SPS+PPS)
//   - AV1   (av1C + seq-header OBU) → manual 'av01' description (no convenience API); runtime-gate
//   - AAC (ASC) / ALAC / Opus (OpusHead) / FLAC (STREAMINFO) → magic-cookie CMAudioFormatDescription
//   - PCM → hand-built ASBD
//   Matroska stores H.264/HEVC AVCC length-prefixed → pass blocks through (no Annex-B reframing).
//
// TODO(Phase 2–3): decode sessions — VTDecompressionSession (video → CVPixelBuffer),
//   AudioConverter (audio → PCM); ns→CMTime here (the demuxer stays CoreMedia-free).
