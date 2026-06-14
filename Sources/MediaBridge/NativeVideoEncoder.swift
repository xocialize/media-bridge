//
// NativeVideoEncoder.swift — MediaBridge
//
// BGRA CVPixelBuffer + nanosecond PTS → HEVC/BT.709 mp4 via AVAssetWriter. Pure VideoToolbox
// (AVAssetWriter drives the media-engine encoder). Settings mirror the validated frame-stream-native
// writer; Phase 4 may extract a shared `NativeVideoWriter` between the two packages.
//

import AVFoundation
import CoreVideo
import Foundation

public final class NativeVideoEncoder {

    public enum EncodeError: Error { case cannotAdd, start(Error?), append(Error?), finish(Error?) }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    public init(output: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // BT.709, always tagged (parity with frame-stream-native / format-bridge encode tier).
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw EncodeError.cannotAdd }
        writer.add(input)
        guard writer.startWriting() else { throw EncodeError.start(writer.error) }
        writer.startSession(atSourceTime: .zero)
    }

    /// Append one frame. `ptsNanos` should be normalized so the first frame is at (or near) 0.
    public func append(_ pixelBuffer: CVPixelBuffer, ptsNanos: Int64) async throws {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 2_000_000)
            try Task.checkCancellation()
        }
        let t = CMTime(value: max(0, ptsNanos), timescale: 1_000_000_000)
        guard adaptor.append(pixelBuffer, withPresentationTime: t) else {
            throw EncodeError.append(writer.error)
        }
    }

    public func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed { throw EncodeError.finish(writer.error) }
    }
}
