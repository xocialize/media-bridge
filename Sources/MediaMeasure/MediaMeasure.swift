//
// MediaMeasure.swift — MediaMeasure
//
// Video quality measurement. The FFmpeg VMAF path is dropped; quality = **SSIMULACRA2**, now a
// pure-Swift port (`SSIMULACRA2.score`) — F1 done, NO external libjxl binary. Per-frame scoring for
// a video pair (decode both via MediaImport, score each frame, aggregate) is the remaining wrapper;
// the metric itself is complete and validated against the reference binary (~3 pt, exact at identity).
//
// Phase 4 of MEDIABRIDGE-PLAN.md.
//

import CoreGraphics
import Foundation

public enum MediaMeasure {
    /// Image-pair SSIMULACRA2 score (100 = identical). See `SSIMULACRA2`.
    ///
    /// ⚠️ **Read this as an odometer, not a speedometer.** It reads grain synthesis as ringing and
    /// denoising as blur, so a before/after score decreases monotonically with restoration strength.
    /// Excellent for over-processing detection and regression testing; useless as a quality signal.
    /// (Its role as a full-reference *compression* gate against a restored frame is unaffected —
    /// that is exactly what it is right for.) For the restoration question use `FidelityGuard`.
    public static func ssimulacra2(reference: CGImage, distorted: CGImage) throws -> Double {
        try SSIMULACRA2.score(reference: reference, distorted: distorted)
    }

    /// N8 Axis B — did the pipeline recover detail or invent it? See `FidelityGuard`.
    public static func downsampleConsistency(source: CGImage, result: CGImage,
                                             tileSize: Int = 128) throws
        -> FidelityGuard.DownsampleConsistency {
        try FidelityGuard.downsampleConsistency(source: source, result: result, tileSize: tileSize)
    }

    /// N8 Axis B — which octaves the pipeline actually moved. See `FidelityGuard`.
    public static func perOctaveSSIM(reference: CGImage, distorted: CGImage,
                                     octaves: Int = 4) throws -> FidelityGuard.OctaveSSIM {
        try FidelityGuard.perOctaveSSIM(reference: reference, distorted: distorted, octaves: octaves)
    }
}
