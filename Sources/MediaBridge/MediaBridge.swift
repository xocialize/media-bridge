//
// MediaBridge.swift — MediaBridge
//
// The public media-foundation surface (FFmpeg-free successor to format-bridge's FormatBridge). The
// first end-to-end path: **normalize a Matroska/WebM container to a native HEVC mp4** by demuxing
// (matroska-swift) → native decode (MediaImport) → native HEVC encode (NativeVideoEncoder). This is
// the upstream normalizer the model pipeline (frame-stream-native) consumes.
//
// Phase 4 folds in the salvaged FormatBridge surface (convert settings, probe, TierRouter for native-
// container passthrough via AVAssetExportSession, ShotDetector, quality-targeted encode). For now
// this is the video path; audio mux + AV1 land alongside the rest of Phase 2–3.
//

import CoreVideo
import Foundation
import MatroskaDemux
import MediaImport

public enum MediaBridge {

    public struct NormalizeResult: Sendable {
        public let sourceCodecID: String
        public let width: Int
        public let height: Int
        public let frameCount: Int
    }

    public enum NormalizeError: Error, Equatable {
        case noVideoTrack
        /// The source video codec isn't natively decodable (VP9/VP8/…); it must be handled by a
        /// future SupportGate fallback. Surfaced here, never silently produced as a broken file.
        case deferredCodec(String)
        case noFramesDecoded
    }

    /// Normalize a Matroska/WebM file's video to a native HEVC/BT.709 mp4. Video-only for now.
    @discardableResult
    public static func normalizeVideoToHEVC(input: URL, output: URL) async throws -> NormalizeResult {
        let demuxer = MatroskaDemuxer(data: try Data(contentsOf: input))
        try demuxer.parseHeaders()

        guard let track = demuxer.tracks.first(where: { $0.type == .video }) else {
            throw NormalizeError.noVideoTrack
        }
        guard SupportGate.status(forCodecID: track.codecID) == .nativeVideo else {
            throw NormalizeError.deferredCodec(track.codecID)
        }

        let packets = try demuxer.readAllPackets()
            .filter { $0.trackNumber == track.number }
            .map { (data: $0.data, ptsNanos: $0.ptsNanos) }

        let formatDesc = try FormatDescriptionFactory.makeVideo(codecID: track.codecID,
                                                                codecPrivate: track.codecPrivate)
        let frames = try VideoDecodeSession(formatDescription: formatDesc).decode(packets)
        guard let first = frames.first else { throw NormalizeError.noFramesDecoded }

        let w = CVPixelBufferGetWidth(first.image)
        let h = CVPixelBufferGetHeight(first.image)
        let basePTS = frames.map(\.ptsNanos).min() ?? 0   // re-base so output starts at 0

        let encoder = try NativeVideoEncoder(output: output, width: w, height: h)
        for f in frames { try await encoder.append(f.image, ptsNanos: f.ptsNanos - basePTS) }
        try await encoder.finish()

        return NormalizeResult(sourceCodecID: track.codecID, width: w, height: h,
                               frameCount: frames.count)
    }
}
