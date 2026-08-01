//
// Probe.swift — MediaBridge
//
// Inspect a media file's container + streams without decoding it. Routes like the normalizer:
// AVFoundation-readable native containers (mp4/mov) are probed via AVAsset; non-native (MKV/WebM)
// via the pure-Swift MatroskaDemuxer header parse. Reports a unified codec vocabulary (Matroska
// CodecIDs) and whether each stream is natively decodable, so a consumer can decide whether a file
// needs normalization. This is the FFmpeg-free replacement for format-bridge's FFmpegFormatProbe.
//

import AVFoundation
import CoreMedia
import Foundation
import MatroskaDemux
import MediaImport

public struct MediaInfo: Sendable, Equatable {
    public enum Container: String, Sendable {
        case matroska, webm, mp4, mov, unknown
        public var isNativeApple: Bool { self == .mp4 || self == .mov }
    }
    public let container: Container
    public let durationSeconds: Double
    public let videoStreams: [VideoStreamInfo]
    public let audioStreams: [AudioStreamInfo]
}

public struct VideoStreamInfo: Sendable, Equatable {
    public let codecID: String          // unified Matroska vocabulary (V_MPEG4/ISO/AVC, V_AV1, …)
    public let width: Int
    public let height: Int
    public let frameRate: Double         // 0 if unknown (Matroska without DefaultDuration)
    public let nativelyDecodable: Bool
    /// Estimated video-stream data rate in bits/second; 0 when the container doesn't say
    /// (Matroska has no per-track rate — derive a coarse bound from file size if you must, and
    /// say so). 🔑 This is the field the enhance classifier's bits-per-pixel axis reads
    /// (`MediaMeasure.SourceProfile`): C7 measured that RESOLUTION is the wrong degradation
    /// axis — bits per pixel per frame is what separates "detail missing" from "detail damaged".
    public let estimatedDataRateBPS: Double

    public init(codecID: String, width: Int, height: Int, frameRate: Double,
                nativelyDecodable: Bool, estimatedDataRateBPS: Double = 0) {
        self.codecID = codecID
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.nativelyDecodable = nativelyDecodable
        self.estimatedDataRateBPS = estimatedDataRateBPS
    }
}

public struct AudioStreamInfo: Sendable, Equatable {
    public let codecID: String
    public let channels: Int
    public let sampleRate: Double
    public let nativelyDecodable: Bool
}

public extension MediaBridge {

    /// Probe a media file. Never decodes; routes native containers through AVFoundation and
    /// non-native (MKV/WebM) through the pure-Swift demuxer.
    static func probe(url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        if let videoTracks = try? await asset.loadTracks(withMediaType: .video), !videoTracks.isEmpty {
            return try await probeNative(url: url, asset: asset, videoTracks: videoTracks)
        }
        return try probeMatroska(url: url)
    }

    // MARK: - Native (AVFoundation)

    private static func probeNative(url: URL, asset: AVURLAsset,
                                    videoTracks: [AVAssetTrack]) async throws -> MediaInfo {
        let duration = try await asset.load(.duration).seconds
        let container: MediaInfo.Container = url.pathExtension.lowercased() == "mov" ? .mov : .mp4

        var videos: [VideoStreamInfo] = []
        for t in videoTracks {
            let size = try await t.load(.naturalSize)
            let fps = try await t.load(.nominalFrameRate)
            let dataRate = (try? await t.load(.estimatedDataRate)) ?? 0
            let codec = (try await t.load(.formatDescriptions)).first
                .map { unifiedCodecID(fourCC: fourCC(CMFormatDescriptionGetMediaSubType($0))) } ?? "?"
            videos.append(VideoStreamInfo(
                codecID: codec, width: Int(abs(size.width).rounded()),
                height: Int(abs(size.height).rounded()), frameRate: Double(fps),
                nativelyDecodable: true,    // AVFoundation read it → decodable
                estimatedDataRateBPS: Double(dataRate)))
        }

        var audios: [AudioStreamInfo] = []
        for t in (try? await asset.loadTracks(withMediaType: .audio)) ?? [] {
            var channels = 0
            var rate = 0.0
            var codec = "?"
            if let fd = (try await t.load(.formatDescriptions)).first {
                codec = unifiedCodecID(fourCC: fourCC(CMFormatDescriptionGetMediaSubType(fd)))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                    channels = Int(asbd.pointee.mChannelsPerFrame)
                    rate = asbd.pointee.mSampleRate
                }
            }
            audios.append(AudioStreamInfo(codecID: codec, channels: channels,
                                          sampleRate: rate, nativelyDecodable: true))
        }

        return MediaInfo(container: container, durationSeconds: duration,
                         videoStreams: videos, audioStreams: audios)
    }

    // MARK: - Matroska / WebM

    private static func probeMatroska(url: URL) throws -> MediaInfo {
        let demuxer = MatroskaDemuxer(data: try Data(contentsOf: url))
        try demuxer.parseHeaders()
        let container: MediaInfo.Container = demuxer.docType == "webm" ? .webm : .matroska

        let videos = demuxer.tracks.filter { $0.type == .video }.map { t in
            VideoStreamInfo(
                codecID: t.codecID, width: t.video?.pixelWidth ?? 0, height: t.video?.pixelHeight ?? 0,
                frameRate: t.defaultDurationNanos.map { 1_000_000_000.0 / Double($0) } ?? 0,
                nativelyDecodable: SupportGate.status(forCodecID: t.codecID) == .nativeVideo)
        }
        let audios = demuxer.tracks.filter { $0.type == .audio }.map { t in
            AudioStreamInfo(
                codecID: t.codecID, channels: t.audio?.channels ?? 0,
                sampleRate: t.audio?.samplingFrequency ?? 0,
                nativelyDecodable: SupportGate.status(forCodecID: t.codecID) == .nativeAudio)
        }
        return MediaInfo(container: container, durationSeconds: demuxer.info.durationNanos > 0
                            ? Double(demuxer.info.durationNanos) / 1_000_000_000.0 : 0,
                         videoStreams: videos, audioStreams: audios)
    }

    // MARK: - Codec vocabulary

    /// Map an mp4/mov fourCC to the unified Matroska CodecID vocabulary the rest of the stack uses.
    /// FourCCs may be space-padded (e.g. AAC is `"aac "`), so trim before matching.
    private static func unifiedCodecID(fourCC raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "avc1", "avc3":  return "V_MPEG4/ISO/AVC"
        case "hvc1", "hev1":  return "V_MPEGH/ISO/HEVC"
        case "av01":          return "V_AV1"
        case "vp09":          return "V_VP9"
        case "mp4a", "aac":   return "A_AAC"
        case "alac":          return "A_ALAC"
        case "opus", "Opus":  return "A_OPUS"
        case "fLaC", "flac":  return "A_FLAC"
        default:              return raw.trimmingCharacters(in: .whitespaces)
        }
    }
}


import MediaMeasure

public extension MediaInfo {
    /// The first video stream as an enhance-classifier profile (`MediaMeasure.SourceProfile`) —
    /// the probe half of the T4 decision layer. `nil` when the file has no video stream.
    /// Multi-stream files: pick the stream yourself and use `SourceProfile`'s memberwise init.
    var sourceProfile: SourceProfile? {
        guard let v = videoStreams.first else { return nil }
        return SourceProfile(width: v.width, height: v.height, frameRate: v.frameRate,
                             videoBitsPerSecond: v.estimatedDataRateBPS)
    }
}
