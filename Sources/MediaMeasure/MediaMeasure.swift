//
// MediaMeasure.swift — MediaMeasure
//
// Video quality measurement. The FFmpeg VMAF path (subprocess to `ffmpeg -lavfi libvmaf`) is
// **dropped**; replaced by **SSIMULACRA2-video** (decision: results matter, not VMAF comparability).
// PSNR/SSIM (pure-Swift luma math from format-bridge's QualityMeasure) are salvaged as cheap extras.
//
// Approach: decode reference + distorted natively (MediaImport) → score per-frame with SSIMULACRA2
// (extends ImageBridge's still scorer) → aggregate. NOTE per the salvage audit: the SSIMULACRA2
// scorer is a SUBPROCESS to libjxl's `ssimulacra2` binary (brew install jpeg-xl) — fine for
// optimizer-time / content-prep use, but a pure-Swift/Metal port would be needed for on-device
// scoring inside a shipping app. Tracked as a follow-up, not a Phase 4 blocker.
//
// Phase 4 of MEDIABRIDGE-PLAN.md.
//

import Foundation
import ImageBridge

public enum MediaMeasure {
    public static let scaffolded = true
}
