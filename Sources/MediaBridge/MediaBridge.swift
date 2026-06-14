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

import CoreMedia
import CoreVideo
import Foundation
import MatroskaDemux
import MediaImport
import VideoToolbox

public enum MediaBridge {

    public struct NormalizeResult: Sendable {
        public let sourceCodecID: String
        public let width: Int
        public let height: Int
        public let frameCount: Int
        /// The source audio codec muxed (passthrough), or nil if there was no mp4-muxable audio.
        public let audioCodecID: String?
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
        // AV1 is HW-only (M3+): if this machine can't decode it, treat it as deferred, not a crash.
        if track.codecID == "V_AV1", !VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) {
            throw NormalizeError.deferredCodec(track.codecID)
        }

        let allPackets = try demuxer.readAllPackets()
        let videoPackets = allPackets
            .filter { $0.trackNumber == track.number }
            .map { (data: $0.data, ptsNanos: $0.ptsNanos) }

        let formatDesc = try FormatDescriptionFactory.makeVideo(
            codecID: track.codecID, codecPrivate: track.codecPrivate,
            width: track.video?.pixelWidth ?? 0, height: track.video?.pixelHeight ?? 0)
        let frames = try VideoDecodeSession(formatDescription: formatDesc).decode(videoPackets)
        guard let first = frames.first else { throw NormalizeError.noFramesDecoded }

        let w = CVPixelBufferGetWidth(first.image)
        let h = CVPixelBufferGetHeight(first.image)

        // Optional audio: decode a natively-supported track (AAC/FLAC/Opus) to PCM, then AAC-re-encode
        // into the mp4 (robust esds, vs. the AVFoundation-invalid hand-built passthrough).
        let audioTrack = demuxer.tracks.first {
            $0.type == .audio && AudioDecodeSession.isSupported(codecID: $0.codecID)
                && SupportGate.status(forCodecID: $0.codecID) == .nativeAudio && $0.codecPrivate != nil
        }
        // Best-effort: a problematic audio track degrades to a video-only output, never fails the job.
        var audioPCM: AudioDecodeSession.PCM?
        var muxedAudioCodec: String?
        if let at = audioTrack {
            do {
                let packets = allPackets.filter { $0.trackNumber == at.number }.map(\.data)
                let decoder = try AudioDecodeSession(
                    codecID: at.codecID, codecPrivate: at.codecPrivate,
                    sampleRate: at.audio?.samplingFrequency ?? 48_000,
                    channels: at.audio?.channels ?? 2, bitDepth: at.audio?.bitDepth ?? 16)
                let pcm = try decoder.decode(packets)
                if pcm.frameCount > 0 { audioPCM = pcm; muxedAudioCodec = at.codecID }
            } catch {
                audioPCM = nil          // drop audio rather than fail the normalize
            }
        }

        let basePTS = frames.map(\.ptsNanos).min() ?? 0   // re-base video so output starts at 0

        let writer = try NativeMP4Writer(
            output: output, width: w, height: h,
            audioPCM: audioPCM.map { ($0.sampleRate, $0.channels) })
        for f in frames { try await writer.appendVideo(f.image, ptsNanos: f.ptsNanos - basePTS) }
        if let pcm = audioPCM, pcm.frameCount > 0 {
            try await writer.appendAudio(pcm.makeSampleBuffer(ptsNanos: 0))
        }
        try await writer.finish()

        return NormalizeResult(sourceCodecID: track.codecID, width: w, height: h,
                               frameCount: frames.count, audioCodecID: muxedAudioCodec)
    }
}
