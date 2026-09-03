//
// AlphaDeclaration.swift — MediaMeasure
//
// The one definition of "this video stream declares an alpha channel", read by the probe
// (`VideoStreamInfo.hasAlpha`), the target-quality encoder, and the SR pipeline.
//

import CoreMedia
import Foundation

public extension CMFormatDescription {

    /// Whether this video format description **declares** an alpha channel
    /// (`kCMFormatDescriptionExtension_ContainsAlphaChannel`). ProRes 4444 (`ap4h`) and
    /// HEVC-with-alpha (`hvc1` in `.mov`) both tag it; no decode is needed.
    ///
    /// Declaration-level by design, not per-pixel: an opaque-but-alpha-tagged stream reads `true`.
    /// The asymmetry is deliberate — refusing to flatten something that turns out to be opaque
    /// costs a skip; flattening something that turns out to be transparent costs a wrong file
    /// that nothing downstream can catch (SSIMULACRA2 composites both sides over an opaque
    /// ground before scoring, so a flattened candidate clears its floor against a flattened
    /// reference). A caller who knows the plane is opaque says so explicitly (`flattenAlpha:`).
    var declaresAlphaChannel: Bool {
        (CMFormatDescriptionGetExtension(
            self, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool) ?? false
    }
}
