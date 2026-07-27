import Foundation
import AVFoundation
import CoreVideo
import VideoToolbox

/// Writes a **ProRes 4444 `.mov` with a real alpha channel** from premultiplied-BGRA frames — the deliverable
/// container for video matting (the cutout: foreground colour over transparent, alpha = the matte). ProRes
/// 4444 carries alpha natively (unlike the HEVC path in `frame-stream-native`/`VideoQualityTarget`), so a
/// BGRA source whose A channel is the matte round-trips as a transparent-background clip.
///
/// Pull-based: `nextFrame()` returns the next premultiplied-BGRA `CVPixelBuffer` (the composited cutout) in
/// order, or `nil` at end. Net-clean (AVFoundation only) — the matte/flow models stay at the app boundary.
public enum AlphaVideoWriter {
    public enum WriteError: Error { case setupFailed, appendFailed(Int), finalizeFailed(Error?) }

    /// Which alpha-capable codec to write. Both live in `.mov` — **no mp4 configuration carries alpha**,
    /// which is the whole reason an alpha-preserving path changes container.
    public enum Codec: Sendable {
        /// HEVC with an alpha channel. The **delivery** choice: same codec family as the opaque path, so
        /// preserving transparency does not throw away the compression story.
        case hevcWithAlpha
        /// ProRes 4444. The **intermediate** choice — visually lossless, and very large.
        case proRes4444

        var avCodec: AVVideoCodecType { self == .hevcWithAlpha ? .hevcWithAlpha : .proRes4444 }
    }

    /// Encode premultiplied-BGRA frames to an alpha-bearing `.mov`.
    ///
    /// `frameRate` is used only when a frame supplies no PTS. Prefer `ptsNanos` on the frame: synthesizing
    /// `index × step` silently retimes variable-frame-rate sources, which is common in screen and browser
    /// capture.
    @discardableResult
    public static func write(to output: URL, codec: Codec, width: Int, height: Int, frameRate: Double,
                             nextFrame: () async throws -> (buffer: CVPixelBuffer, ptsNanos: Int64?)?
    ) async throws -> Int {
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ]
        if codec == .hevcWithAlpha {
            // Without this the encoder assumes straight alpha and the composite darkens at soft edges —
            // the frames arriving here are premultiplied, matching the matting path's contract.
            settings[AVVideoCompressionPropertiesKey] = [
                kVTCompressionPropertyKey_AlphaChannelMode as String:
                    kVTAlphaChannelMode_PremultipliedAlpha as String,
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw WriteError.setupFailed }
        writer.add(input)
        guard writer.startWriting() else { throw WriteError.setupFailed }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        let step = CMTimeValue((Double(timescale) / frameRate).rounded())
        var index = 0
        var basePTS: Int64?
        while let frame = try await nextFrame() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 500_000) }
            let pts: CMTime
            if let ns = frame.ptsNanos {
                if basePTS == nil { basePTS = ns }
                pts = CMTime(value: max(0, ns - (basePTS ?? 0)), timescale: 1_000_000_000)
            } else {
                pts = CMTime(value: CMTimeValue(index) * step, timescale: timescale)
            }
            guard adaptor.append(frame.buffer, withPresentationTime: pts) else {
                writer.cancelWriting(); throw WriteError.appendFailed(index)
            }
            index += 1
        }
        input.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        if writer.status == .failed { throw WriteError.finalizeFailed(writer.error) }
        return index
    }

    /// Encode `width × height` premultiplied-BGRA frames at `frameRate` fps to a ProRes 4444 `.mov` at
    /// `output`. Returns the number of frames written.
    @discardableResult
    public static func writeProRes4444(to output: URL, width: Int, height: Int, frameRate: Double,
                                       nextFrame: () async throws -> CVPixelBuffer?) async throws -> Int {
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw WriteError.setupFailed }
        writer.add(input)
        guard writer.startWriting() else { throw WriteError.setupFailed }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        let step = CMTimeValue((Double(timescale) / frameRate).rounded())
        var index = 0
        while let pb = try await nextFrame() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 500_000) }
            let pts = CMTime(value: CMTimeValue(index) * step, timescale: timescale)
            guard adaptor.append(pb, withPresentationTime: pts) else {
                writer.cancelWriting(); throw WriteError.appendFailed(index)
            }
            index += 1
        }
        input.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        if writer.status == .failed { throw WriteError.finalizeFailed(writer.error) }
        return index
    }
}
