//
// MediaBridge.swift — MediaBridge
//
// The public media-foundation surface (FFmpeg-free successor to format-bridge's FormatBridge):
// convert / normalize any supported input → native HEVC+AAC mp4, probe, ShotDetector, and
// quality-targeted encode. Decode comes from MediaImport; encode is native VideoToolbox/AAc via
// AVAssetWriter.
//
// Phase 4 of MEDIABRIDGE-PLAN.md salvages the FFmpeg-free Swift from format-bridge into here:
//   SALVAGE (per the audit): MediaInfo/Enums/ConversionSettings/Progress/EncoderSettings models;
//     the MediaProbing/VideoDecoding/VideoEncoding/QualityScoring protocols; NativeEncoder,
//     VideoToolboxEncoder, Tier1Exporter, QualityTargetSearch/Encoder; TierRouter,
//     ConversionOrchestrator (relinked), MetadataWriter, ShotDetector, TimestampMapper.
//   REBUILD: FFmpegFormatProbe → Matroska(MatroskaDemux)+AVAsset probe; FFmpegDecoder → MediaImport;
//     PixelBufferConverter → vImage/CoreImage.  DROP: FFmpegAV1Encoder, FFmpegXC, FFmpegLogger.
//

import Foundation
import MediaImport

public enum MediaBridge {
    /// Placeholder until Phase 4 lands the salvaged convert/normalize surface.
    public static let scaffolded = true
}
