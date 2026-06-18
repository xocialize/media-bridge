import Foundation
import AVFoundation
import CoreMedia

/// Video analog of `ImageQualityTarget`: re-encode a clip to the **lowest HEVC bitrate whose per-frame
/// SSIMULACRA2 (p10) still clears the floor** → smaller file, perceptually equivalent, same resolution.
/// The lever is target *bitrate* (not constant-quality, which inflates an already-compressed source).
/// Video-only (audio passthrough/mux is the V3 wiring step); per-frame scoring is GPU-accelerated.
public enum VideoQualityTarget {

    public struct Result: Sendable {
        public let bitrate: Int           // AVVideoAverageBitRateKey chosen (bits/s)
        public let score: Double          // achieved p10 per-frame SSIMULACRA2
        public let inputBytes: Int
        public let outputBytes: Int
        public let metTarget: Bool
        public var savedFraction: Double {
            inputBytes > 0 ? Double(max(0, inputBytes - outputBytes)) / Double(inputBytes) : 0
        }
    }

    public enum EncodeError: Error { case noVideoTrack, encodeFailed, readFailed }

    /// Binary-search the target bitrate (down from the source bitrate); gate on the p10 frame so one bad
    /// frame can't pass. Smallest output whose p10 ≥ `targetScore` wins.
    public static func encode(input: URL, output: URL, targetScore: Double,
                              iterations: Int = 6, searchStride: Int = 20) async throws -> Result {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        let inBytes = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sourceBitrate = duration > 0 ? Double(inBytes) * 8 / duration : 8_000_000

        let tmpDir = FileManager.default.temporaryDirectory
        var lo = sourceBitrate * 0.04, hi = sourceBitrate    // never exceed the source bitrate
        var best: (bitrate: Int, score: Double, url: URL)?
        var temps: [URL] = []

        for _ in 0..<iterations {
            let b = (lo + hi) / 2
            let tmp = tmpDir.appendingPathComponent("vqt-\(UUID().uuidString).mp4")
            temps.append(tmp)
            try await reencodeVideo(input: input, output: tmp, bitrate: Int(b))
            let vs = try VideoQuality.videoScore(reference: input, distorted: tmp, sampleStride: searchStride)
            if vs.p10 >= targetScore {
                best = (Int(b), vs.p10, tmp); hi = b     // clears → try smaller (lower bitrate)
            } else {
                lo = b                                    // below floor → need more bitrate
            }
        }

        let chosen: (bitrate: Int, score: Double, url: URL)
        if let best {
            chosen = best
        } else {
            let tmp = tmpDir.appendingPathComponent("vqt-final-\(UUID().uuidString).mp4")
            temps.append(tmp)
            try await reencodeVideo(input: input, output: tmp, bitrate: Int(hi))
            let s = (try VideoQuality.videoScore(reference: input, distorted: tmp, sampleStride: searchStride)).p10
            chosen = (Int(hi), s, tmp)
        }

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: chosen.url, to: output)
        for t in temps { try? FileManager.default.removeItem(at: t) }

        let outBytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Result(bitrate: chosen.bitrate, score: chosen.score, inputBytes: inBytes,
                      outputBytes: outBytes, metTarget: best != nil)
    }

    /// Transcode the video track to HEVC at a target average bitrate. Video-only.
    static func reencodeVideo(input: URL, output: URL, bitrate: Int) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw EncodeError.noVideoTrack
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let w = Int(abs(size.width).rounded()), h = Int(abs(size.height).rounded())

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ])
        writerInput.transform = transform
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        guard reader.startReading() else { throw EncodeError.readFailed }
        guard writer.startWriting() else { throw EncodeError.encodeFailed }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "vqt.reencode")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sample)
                    } else {
                        writerInput.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if writer.status == .failed { throw EncodeError.encodeFailed }
    }
}
