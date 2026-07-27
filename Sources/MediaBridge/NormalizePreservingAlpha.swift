//
// NormalizePreservingAlpha.swift — MediaBridge
//
// The alpha-preserving sibling of `normalizeVideoToHEVC`.
//
// It is a separate entry point rather than a flag because it cannot honour the other one's contract:
// **no mp4 configuration carries an alpha channel**, `AVVideoCodecType.hevcWithAlpha` included — that
// codec writes only `.mov`. So preserving transparency necessarily changes the container, and
// `normalizeVideoToHEVC` promises mp4 in its name, its docs, and its tests.
//
// What it does NOT change is the codec. ProRes 4444 is an intermediate — measured ~23x larger than
// HEVC-with-alpha for the same content — so treating it as the only alpha-capable option would make
// transparency look like it costs the whole compression story. It doesn't. It costs a container.
//

import AVFoundation
import CoreVideo
import Foundation
import MatroskaDemux
import MediaImport
import MediaMeasure

public extension MediaBridge {

    struct AlphaNormalizeResult: Sendable {
        public let sourceCodecID: String
        public let width: Int
        public let height: Int
        public let frameCount: Int
        /// What was actually written. A caller that asked for transparency can confirm it got it,
        /// rather than inferring from a file extension.
        public let outputFormat: TransparentVideoFormat
        /// Whether the SOURCE declared alpha. `false` means a valid but pointlessly opaque `.mov` —
        /// the operation succeeded and the caller probably wanted `normalizeVideoToHEVC` instead.
        public let sourceHadAlpha: Bool
    }

    enum AlphaNormalizeError: Error, Equatable {
        /// The source codec has no decoder that can read its alpha stream. Raised **instead of**
        /// writing a flattened file, because a silently-opaque result is indistinguishable from
        /// success: the frames decode, the file plays, and the transparency is simply gone.
        case decoderCannotReadAlpha(codecID: String)
        /// The requested output format needs an encoder nobody registered (today: WebM).
        case noEncoderFor(TransparentVideoFormat)
        case noVideoTrack
        case deferredCodec(String)
        case noFramesDecoded
    }

    /// Normalize a container to an alpha-bearing `.mov`, keeping transparency.
    ///
    /// - Parameter format: `.movHEVCAlpha` (delivery, the default) or `.movProRes4444` (intermediate).
    ///   `.webmVP9Alpha` routes to a registered external encoder if one exists.
    @discardableResult
    static func normalizeVideoPreservingAlpha(
        input: URL,
        output: URL,
        format: TransparentVideoFormat = .movHEVCAlpha
    ) async throws -> AlphaNormalizeResult {

        let demuxer = MatroskaDemuxer(data: try Data(contentsOf: input))
        try demuxer.parseHeaders()
        guard let track = demuxer.tracks.first(where: { $0.type == .video }) else {
            throw AlphaNormalizeError.noVideoTrack
        }

        let status = SupportGate.status(forCodecID: track.codecID)
        let external = (status == .deferred) ? externalDecoder(for: track.codecID) : nil
        guard status == .nativeVideo || external != nil else {
            throw AlphaNormalizeError.deferredCodec(track.codecID)
        }

        let sourceHadAlpha = track.video?.hasAlpha ?? false

        // Refuse rather than flatten. A decoder that ignores the alpha stream returns complete,
        // plausible, fully opaque frames — so if we wrote them the caller would get a file that looks
        // right and has silently lost the one property they asked to preserve. `decodesAlpha` defaults
        // to false precisely so an un-updated decoder lands here instead of succeeding wrongly.
        if sourceHadAlpha {
            let canReadAlpha = external?.decodesAlpha ?? false
            guard canReadAlpha else {
                throw AlphaNormalizeError.decoderCannotReadAlpha(codecID: track.codecID)
            }
        }

        guard canWriteTransparent(format) else { throw AlphaNormalizeError.noEncoderFor(format) }

        let allPackets = try demuxer.readAllPackets().filter { $0.trackNumber == track.number }
        let packets = allPackets.map {
            ExternalVideoPacket(data: $0.data, ptsNanos: $0.ptsNanos, alpha: $0.blockAdditional)
        }

        // Decode fully before writing: both writers are pull-based (`nextFrame()`), which cannot be
        // driven from a push-style `onFrame` callback without a buffering hand-off. Bounded by clip
        // length, and the transparent assets this path exists for are short.
        var frames: [(buffer: CVPixelBuffer, ptsNanos: Int64?)] = []
        if let external {
            try await external.decodeStreaming(codecID: track.codecID, codecPrivate: track.codecPrivate,
                                               packets: packets) { frame in
                frames.append((frame.image, frame.ptsNanos))
            }
        } else {
            let formatDesc = try FormatDescriptionFactory.makeVideo(
                codecID: track.codecID, codecPrivate: track.codecPrivate,
                width: track.video?.pixelWidth ?? 0, height: track.video?.pixelHeight ?? 0)
            let session = try VideoDecodeSession(formatDescription: formatDesc)
            try await session.decodeStreaming(allPackets.map { (data: $0.data, ptsNanos: $0.ptsNanos) }) {
                frames.append(($0.image, $0.ptsNanos))
            }
        }
        guard let first = frames.first else { throw AlphaNormalizeError.noFramesDecoded }

        let width = CVPixelBufferGetWidth(first.buffer)
        let height = CVPixelBufferGetHeight(first.buffer)
        let basePTS = first.ptsNanos ?? 0
        let frameRate = Self.estimateFrameRate(frames.map(\.ptsNanos)) ?? 30

        var index = 0
        let written: Int
        if let encoder = externalAlphaEncoder(for: format) {
            written = try await encoder.write(to: output, format: format, width: width, height: height,
                                              frameRate: frameRate) {
                guard index < frames.count else { return nil }
                defer { index += 1 }
                let f = frames[index]
                return (f.buffer, f.ptsNanos.map { $0 - basePTS })
            }
        } else {
            let codec: AlphaVideoWriter.Codec = format == .movProRes4444 ? .proRes4444 : .hevcWithAlpha
            written = try await AlphaVideoWriter.write(to: output, codec: codec, width: width,
                                                       height: height, frameRate: frameRate) {
                guard index < frames.count else { return nil }
                defer { index += 1 }
                let f = frames[index]
                return (f.buffer, f.ptsNanos.map { $0 - basePTS })
            }
        }

        return AlphaNormalizeResult(sourceCodecID: track.codecID, width: width, height: height,
                                    frameCount: written, outputFormat: format,
                                    sourceHadAlpha: sourceHadAlpha)
    }

    /// Median inter-frame delta → fps. Median rather than mean so one long gap (a dropped frame, a
    /// still-frame hold) doesn't drag the whole clip's rate down.
    private static func estimateFrameRate(_ pts: [Int64?]) -> Double? {
        let stamps = pts.compactMap { $0 }.sorted()
        guard stamps.count > 1 else { return nil }
        let deltas = zip(stamps.dropFirst(), stamps).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        guard let median = deltas[safe: deltas.count / 2], median > 0 else { return nil }
        return 1_000_000_000.0 / Double(median)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
