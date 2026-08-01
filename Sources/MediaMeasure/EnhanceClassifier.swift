// EnhanceClassifier.swift — MediaMeasure
//
// The probe → classify half of the enhance decision layer (`GAP-PROGRAM.md` T4).
//
// 🔑 **The finding this encodes (C7, measured on two real libraries): RESOLUTION IS THE WRONG
// DEGRADATION AXIS — bits per pixel per frame is what separates the two defects.**
//
//   · **Resolution-limited** (SD television at 0.29 bits/px): few pixels, each reasonably encoded.
//     Detail is genuinely MISSING — upscaling is the right tool, a learned model has something to add.
//   · **Bitrate-starved** (a modern 1278×682 encode at 0.045 bits/px): plenty of pixels, each
//     carrying blocking, banding, mosquito noise. **Upscaling AMPLIFIES the damage** — restoration
//     must come first, and V12 measured exactly that (Real-ESRGAN's value on starved sources is
//     deblocking, not resolution).
//
// The naive SD→720p→1080p ladder conflates these; every competitor's UI does too. This classifier is
// the piece that routes between them from measurements, which is the differentiator T4 names.
//
// ⚠️ **Thresholds are calibrated, not guessed** — against the 11-title C7 table (receipt in the T4
// row): the starved class tops out at 0.074 bits/px and the healthy class starts at 0.125, so the
// 0.09 default sits in the measured gap; the resolution floor separates the ≤0.22 MP SD cluster from
// the ≥0.67 MP one. They are still injectable (`EnhanceThresholds`) because C7's own history warns
// exactly here: its first guidance ("BSG is the archetypal degraded source") was inverted by
// measurement — treat any threshold as a hypothesis a new corpus is allowed to move.
//
// 🔑 **The rationale string is product surface, not debug output** (FORGE-UI §1.11): it names the
// numbers and the consequence, because "Autopilot chose restore-first" is only trustworthy when it
// says why.
//
// This file is deliberately engine-free (category A): the optional no-reference quality score is an
// INPUT a host may supply from the engine's `imageQualityScore` oracle — the Kit never calls MLX.

import Foundation

/// Container-level facts about a video source, in the units the classifier reasons in.
public struct SourceProfile: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let frameRate: Double
    /// Video-stream data rate, bits/second. `0` = unknown (e.g. Matroska without a stated rate) —
    /// classification then degrades honestly to the resolution axis alone, and says so.
    public let videoBitsPerSecond: Double

    public var pixels: Int { width * height }

    /// The C7 axis: `bps / (w·h·fps)`. `nil` when bitrate or frame rate is unknown.
    public var bitsPerPixelPerFrame: Double? {
        guard videoBitsPerSecond > 0, frameRate > 0, pixels > 0 else { return nil }
        return videoBitsPerSecond / (Double(pixels) * frameRate)
    }

    public init(width: Int, height: Int, frameRate: Double, videoBitsPerSecond: Double) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoBitsPerSecond = videoBitsPerSecond
    }

}

// The probe-side convenience lives in MediaBridge (which already depends on this module — the
// dependency cannot run the other way without a cycle): `MediaInfo.sourceProfile`.

/// The calibrated decision boundaries. Defaults from the C7 11-title calibration; injectable
/// because thresholds are hypotheses (see header).
public struct EnhanceThresholds: Sendable, Equatable {
    /// Below this pixel count the source is resolution-limited (detail missing). Default separates
    /// the measured SD cluster (≤ 0.22 MP) from the smallest healthy-resolution title (0.67 MP).
    public var resolutionFloorPixels: Int
    /// Below this bits/px/frame the encode is starved (detail damaged). Default sits in the
    /// measured gap: worst healthy 0.125, best starved 0.074.
    public var starvedBitsPerPixel: Double

    public init(resolutionFloorPixels: Int = 450_000, starvedBitsPerPixel: Double = 0.09) {
        self.resolutionFloorPixels = resolutionFloorPixels
        self.starvedBitsPerPixel = starvedBitsPerPixel
    }
}

/// What kind of enhancement a source actually needs — the four cells the C7 2×2 defines.
public enum EnhanceClass: String, Sendable, Codable, CaseIterable {
    /// Few pixels, honestly encoded → detail is missing → UPSCALE is the right tool.
    case resolutionLimited
    /// Enough pixels, starved encode → detail is damaged → RESTORE first; upscaling first
    /// amplifies the artefacts.
    case bitrateStarved
    /// Both defects at once → restore, then upscale, in that order.
    case mixed
    /// Neither container-level defect → leave it alone unless a content-level oracle disagrees.
    case clean
}

/// A classification plus the evidence, ready for a receipt or the Autopilot rationale line.
public struct EnhanceVerdict: Sendable, Equatable {
    public let enhanceClass: EnhanceClass
    /// Human sentence naming the numbers and the consequence (FORGE-UI §1.11).
    public let rationale: String
    /// True when bitrate/fps were unknown and the starved axis could not be evaluated —
    /// the verdict then rests on resolution alone and a caller may want a deeper probe.
    public let bitrateAxisUnknown: Bool
    public let profile: SourceProfile
}

public enum EnhanceClassifier {

    /// Classify a source from container-level measurements.
    public static func classify(_ profile: SourceProfile,
                                thresholds: EnhanceThresholds = EnhanceThresholds()) -> EnhanceVerdict {
        let mp = Double(profile.pixels) / 1_000_000
        let resLimited = profile.pixels < thresholds.resolutionFloorPixels

        guard let bpp = profile.bitsPerPixelPerFrame else {
            // Bitrate axis unavailable — classify on resolution and say the evidence is partial.
            let cls: EnhanceClass = resLimited ? .resolutionLimited : .clean
            return EnhanceVerdict(
                enhanceClass: cls,
                rationale: resLimited
                    ? String(format: "%dx%d is %.2f MP — below the %.2f MP floor, so detail is genuinely missing: upscale. (Bitrate unknown; the damage axis was not evaluated.)",
                             profile.width, profile.height, mp, Double(thresholds.resolutionFloorPixels) / 1_000_000)
                    : String(format: "%dx%d (%.2f MP) needs no more pixels, and the bitrate is unknown — no container-level defect found; a content-level check may still disagree.",
                             profile.width, profile.height, mp),
                bitrateAxisUnknown: true,
                profile: profile)
        }

        let starved = bpp < thresholds.starvedBitsPerPixel
        let cls: EnhanceClass
        let rationale: String
        switch (resLimited, starved) {
        case (true, true):
            cls = .mixed
            rationale = String(format: "%dx%d is only %.2f MP AND the encode carries %.3f bits/px (< %.2f): detail is both missing and damaged — restore first, then upscale.",
                               profile.width, profile.height, mp, bpp, thresholds.starvedBitsPerPixel)
        case (true, false):
            cls = .resolutionLimited
            rationale = String(format: "%dx%d is only %.2f MP but honestly encoded (%.3f bits/px): detail is missing, not damaged — upscale.",
                               profile.width, profile.height, mp, bpp)
        case (false, true):
            cls = .bitrateStarved
            rationale = String(format: "%dx%d has enough pixels (%.2f MP) but the encode is starved (%.3f bits/px < %.2f): the pixels carry blocking and mosquito noise — restore; upscaling first would amplify the damage.",
                               profile.width, profile.height, mp, bpp, thresholds.starvedBitsPerPixel)
        case (false, false):
            cls = .clean
            rationale = String(format: "%dx%d at %.3f bits/px: no container-level defect — leave it alone unless a content-level oracle disagrees.",
                               profile.width, profile.height, bpp)
        }
        return EnhanceVerdict(enhanceClass: cls, rationale: rationale,
                              bitrateAxisUnknown: false, profile: profile)
    }
}
