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
    public static func ssimulacra2(reference: CGImage, distorted: CGImage) throws -> Double {
        try SSIMULACRA2.score(reference: reference, distorted: distorted)
    }
}
