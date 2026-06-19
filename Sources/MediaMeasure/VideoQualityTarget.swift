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
        public let width: Int
        public let height: Int
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
        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw EncodeError.noVideoTrack
        }
        let vsize = try await vtrack.load(.naturalSize)
        let vw = Int(abs(vsize.width).rounded()), vh = Int(abs(vsize.height).rounded())
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
                      outputBytes: outBytes, width: vw, height: vh, metTarget: best != nil)
    }

    /// Map a video format description's colour attachments to an `AVVideoColorPropertiesKey` dict,
    /// defaulting each missing axis to BT.709 — the safe signage default (an untagged stream otherwise
    /// gets misread as 601, drifting saturated brand colours). Preserves HDR/BT.2020 tags when present.
    static func colorProperties(from format: CMFormatDescription?) -> [String: Any] {
        func ext(_ key: CFString, _ fallback: String) -> String {
            guard let format,
                  let v = CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
            else { return fallback }
            return v
        }
        return [
            AVVideoColorPrimariesKey: ext(kCMFormatDescriptionExtension_ColorPrimaries,
                                          AVVideoColorPrimaries_ITU_R_709_2),
            AVVideoTransferFunctionKey: ext(kCMFormatDescriptionExtension_TransferFunction,
                                            AVVideoTransferFunction_ITU_R_709_2),
            AVVideoYCbCrMatrixKey: ext(kCMFormatDescriptionExtension_YCbCrMatrix,
                                       AVVideoYCbCrMatrix_ITU_R_709_2),
        ]
    }

    /// Transcode the video track to HEVC at a target average bitrate; **passthrough-mux the audio** if
    /// present (no re-encode → no audio quality loss). No-audio sources produce a video-only output.
    /// Colour primaries/transfer/matrix are preserved from the source (BT.709 default) for brand fidelity.
    static func reencodeVideo(input: URL, output: URL, bitrate: Int) async throws {
        let asset = AVURLAsset(url: input)
        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw EncodeError.noVideoTrack
        }
        let size = try await vtrack.load(.naturalSize)
        let transform = try await vtrack.load(.preferredTransform)
        let w = Int(abs(size.width).rounded()), h = Int(abs(size.height).rounded())
        let atrack = try await asset.loadTracks(withMediaType: .audio).first
        // Passthrough audio needs the source format up front, else the writer can't add the input.
        let audioFormat = try await atrack?.load(.formatDescriptions).first
        // Preserve the source's colour tags; default to BT.709 when untagged. Decoding to BGRA drops
        // the matrix, so an untagged re-encode can get misread as 601 → saturated brand colours drift
        // while white stays put (the signage-playbook colour-fidelity gate). Pin primaries/transfer/matrix.
        let videoFormat = try await vtrack.load(.formatDescriptions).first
        let colorProperties = Self.colorProperties(from: videoFormat)

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(
            track: vtrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let atrack {
            let ao = AVAssetReaderTrackOutput(track: atrack, outputSettings: nil)   // stored format → passthrough
            ao.alwaysCopiesSampleData = false
            if reader.canAdd(ao) { reader.add(ao); audioOut = ao }
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: colorProperties,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ])
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,     // passthrough mux
                                       sourceFormatHint: audioFormat)
            ai.expectsMediaDataInRealTime = false
            if writer.canAdd(ai) { writer.add(ai); audioIn = ai }
        }

        guard reader.startReading() else { throw EncodeError.readFailed }
        guard writer.startWriting() else { throw EncodeError.encodeFailed }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        func pump(_ input: AVAssetWriterInput, _ out: AVAssetReaderTrackOutput, _ label: String) {
            group.enter()
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "vqt.\(label)")) {
                while input.isReadyForMoreMediaData {
                    if let s = out.copyNextSampleBuffer() {
                        if !input.append(s) {
                            FileHandle.standardError.write(Data("vqt: \(label) append failed: \(String(describing: writer.error))\n".utf8))
                            input.markAsFinished(); group.leave(); return
                        }
                    } else { input.markAsFinished(); group.leave(); return }
                }
            }
        }
        pump(videoIn, videoOut, "video")
        if let audioIn, let audioOut { pump(audioIn, audioOut, "audio") }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.notify(queue: DispatchQueue(label: "vqt.done")) { cont.resume() }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if writer.status == .failed { throw EncodeError.encodeFailed }
    }
}
