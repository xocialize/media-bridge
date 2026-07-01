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

    /// Native containers AVFoundation both demuxes AND reliably transcodes via AVAssetExportSession.
    /// NOT keyed on `loadTracks` success alone: modern macOS can *read* a WebM/VP9 track (so loadTracks
    /// returns non-nil), but AVAssetExportSession then fails to process it — those must take the
    /// pure-Swift demux → native-decode path instead. Mirrors frame-stream-native's `nativeExtensions`.
    private static let nativeContainerExtensions: Set<String> = ["mp4", "mov", "m4v", "qt"]

    /// Returns nil if the input isn't a native container (→ caller falls back to the Matroska path).
    private static func normalizeNativeContainer(input: URL, output: URL) async throws -> NormalizeResult? {
        guard nativeContainerExtensions.contains(input.pathExtension.lowercased()) else {
            return nil                                   // MKV/WebM/etc. → pure-Swift demux path
        }
        let asset = AVURLAsset(url: input)
        guard let vtrack = (try? await asset.loadTracks(withMediaType: .video))?.first else {
            return nil                                   // native extension but unreadable → Matroska path
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

    static func fourCC(_ code: FourCharCode) -> String {
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

        // Optional audio: decode a natively-supported track (AAC/Opus) to PCM up front, then AAC-
        // re-encode into the mp4. Best-effort — a problematic audio track degrades to video-only.
        // AAC/Opus/FLAC need their CodecPrivate cookie; AC-3/E-AC-3/MPEG audio are cookie-less and
        // Matroska stores none — only require CodecPrivate for the codecs that actually need it.
        let audioTrack = demuxer.tracks.first {
            $0.type == .audio && AudioDecodeSession.isSupported(codecID: $0.codecID)
                && SupportGate.status(forCodecID: $0.codecID) == .nativeAudio
                && (!AudioDecodeSession.requiresCodecPrivate(codecID: $0.codecID) || $0.codecPrivate != nil)
        }
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

        // Stream decode → encode: the writer is created lazily on the first frame (so it gets the
        // real dimensions), and only a bounded reorder window of pixel buffers is ever live.
        var writer: NativeMP4Writer?
        var basePTS: Int64?
        var outW = 0, outH = 0, frameCount = 0
        // Creating the session is the true runtime capability probe: a host that can't actually decode
        // the codec (VideoToolbox returns no decoder) fails here → surface as a clean deferral, not a
        // crash. Guards codecs whose availability is machine-dependent (e.g. MPEG-2 on Apple Silicon).
        let decodeSession: VideoDecodeSession
        do {
            decodeSession = try VideoDecodeSession(formatDescription: formatDesc)
        } catch VideoDecodeSession.DecodeError.sessionCreate {
            throw NormalizeError.deferredCodec(track.codecID)
        }
        try await decodeSession
            .decodeStreaming(videoPackets) { frame in
                if writer == nil {
                    outW = CVPixelBufferGetWidth(frame.image)
                    outH = CVPixelBufferGetHeight(frame.image)
                    basePTS = frame.ptsNanos          // first emitted frame = lowest PTS
                    writer = try NativeMP4Writer(
                        output: output, width: outW, height: outH,
                        audioPCM: audioPCM.map { ($0.sampleRate, $0.channels) })
                }
                try await writer!.appendVideo(frame.image, ptsNanos: frame.ptsNanos - (basePTS ?? 0))
                frameCount += 1
            }
        guard let writer else { throw NormalizeError.noFramesDecoded }

        if let pcm = audioPCM, pcm.frameCount > 0 {
            try await writer.appendAudio(pcm.makeSampleBuffer(ptsNanos: 0))
        }
        try await writer.finish()

        return NormalizeResult(sourceCodecID: track.codecID, width: outW, height: outH,
                               frameCount: frameCount, audioCodecID: muxedAudioCodec)
    }
}
