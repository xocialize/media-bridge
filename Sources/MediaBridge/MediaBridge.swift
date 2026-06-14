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

import AVFoundation
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
        case exportFailed(String)
    }

    /// Normalize any supported container's video to a native HEVC mp4 (with AAC audio). Routes:
    /// AVFoundation-readable native containers (mp4/mov/m4v) take the fast AVAssetExportSession path
    /// (passthrough if already HEVC, hardware transcode otherwise); non-native (MKV/WebM) take the
    /// pure-Swift demux → native-decode → encode path.
    @discardableResult
    public static func normalizeVideoToHEVC(input: URL, output: URL) async throws -> NormalizeResult {
        if let native = try await normalizeNativeContainer(input: input, output: output) {
            return native
        }
        return try await normalizeMatroska(input: input, output: output)
    }

    // MARK: - Native-container fast path (AVFoundation)

    /// Returns nil if AVFoundation can't read the input (→ caller falls back to the Matroska path).
    private static func normalizeNativeContainer(input: URL, output: URL) async throws -> NormalizeResult? {
        let asset = AVURLAsset(url: input)
        guard let vtrack = (try? await asset.loadTracks(withMediaType: .video))?.first else {
            return nil                                   // not AVFoundation-readable (e.g. MKV/WebM)
        }
        let size = try await vtrack.load(.naturalSize)
        let frameRate = try await vtrack.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let formats = try await vtrack.load(.formatDescriptions)
        let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
        let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty

        // Already HEVC → remux passthrough (no re-encode); otherwise hardware transcode to HEVC.
        let alreadyHEVC = (codec == "hvc1" || codec == "hev1")
        let preset = alreadyHEVC ? AVAssetExportPresetPassthrough : AVAssetExportPresetHEVCHighestQuality
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NormalizeError.exportFailed("no export session for preset \(preset)")
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .mp4

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed: cont.resume()
                default: cont.resume(throwing: NormalizeError.exportFailed(
                    export.error?.localizedDescription ?? "status \(export.status.rawValue)"))
                }
            }
        }

        return NormalizeResult(
            sourceCodecID: codec,
            width: Int(abs(size.width).rounded()), height: Int(abs(size.height).rounded()),
            frameCount: Int((duration.seconds * Double(frameRate)).rounded()),
            audioCodecID: hasAudio ? "native" : nil)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }

    // MARK: - Non-native (Matroska/WebM) path

    /// Pure-Swift demux → native decode → native HEVC/AAC encode for non-AVFoundation containers.
    private static func normalizeMatroska(input: URL, output: URL) async throws -> NormalizeResult {
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
