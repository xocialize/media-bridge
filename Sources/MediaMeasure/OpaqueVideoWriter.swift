import Foundation
import AVFoundation
import CoreVideo

/// Writes an **opaque HEVC `.mp4`** from BGRA frames — the deliverable container for upscaled / enhanced video
/// (no alpha, unlike `AlphaVideoWriter`'s ProRes 4444 matting output). HEVC keeps a 4K upscale a reasonable
/// size; the faithful-intermediate path (feed the optimize quality-target encoder) can re-encode from this.
///
/// Pull-based: `nextFrame()` returns the next BGRA `CVPixelBuffer` in order, or `nil` at end. Net-clean
/// (AVFoundation only) — the SR/flow models stay at the app boundary.
public enum OpaqueVideoWriter {
    public enum WriteError: Error { case setupFailed, appendFailed(Int), finalizeFailed(Error?) }

    /// Encode `width × height` BGRA frames at `frameRate` fps to an HEVC `.mp4` at `output`. `quality` ∈ 0…1
    /// (VideoToolbox constant-quality hint; higher = better/larger). Returns the number of frames written.
    @discardableResult
    public static func writeHEVC(to output: URL, width: Int, height: Int, frameRate: Double, quality: Float = 0.9,
                                 nextFrame: () async throws -> CVPixelBuffer?) async throws -> Int {
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: quality],
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
