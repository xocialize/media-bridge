//
// NativeMP4Writer.swift — MediaBridge
//
// Writes a native mp4: a VideoToolbox-encoded HEVC/BT.709 video track plus an optional
// passthrough audio track (compressed samples muxed without re-encoding). Pure AVFoundation.
// Settings mirror the validated frame-stream-native writer; Phase 4 may extract a shared writer.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public final class NativeMP4Writer {

    public enum WriterError: Error { case cannotAdd, start(Error?), append(Error?), finish(Error?) }

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?

    /// `audioPCM` non-nil adds an **AAC-encoding** audio track fed Int16 PCM sample buffers — the
    /// writer emits a proper esds (passthrough of a hand-built AAC description was AVFoundation-invalid).
    public init(output: URL, width: Int, height: Int,
                audioPCM: (sampleRate: Double, channels: Int)? = nil) throws {
        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(videoInput) else { throw WriterError.cannotAdd }
        writer.add(videoInput)

        if let audioPCM {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioPCM.sampleRate,
                AVNumberOfChannelsKey: audioPCM.channels,
                AVEncoderBitRateKey: 128_000,
            ])
            ai.expectsMediaDataInRealTime = false
            guard writer.canAdd(ai) else { throw WriterError.cannotAdd }
            writer.add(ai)
            audioInput = ai
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else { throw WriterError.start(writer.error) }
        writer.startSession(atSourceTime: .zero)
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, ptsNanos: Int64) async throws {
        try await waitReady(videoInput)
        let t = CMTime(value: max(0, ptsNanos), timescale: 1_000_000_000)
        guard adaptor.append(pixelBuffer, withPresentationTime: t) else {
            throw WriterError.append(writer.error)
        }
    }

    /// Append a (compressed, passthrough) audio sample. No-op if the writer has no audio track.
    public func appendAudio(_ sample: CMSampleBuffer) async throws {
        guard let audioInput else { return }
        try await waitReady(audioInput)
        guard audioInput.append(sample) else { throw WriterError.append(writer.error) }
    }

    public func finish() async throws {
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed { throw WriterError.finish(writer.error) }
    }

    private func waitReady(_ input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 2_000_000)
            try Task.checkCancellation()
        }
    }
}
