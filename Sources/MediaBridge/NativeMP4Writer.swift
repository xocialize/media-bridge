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

    public enum WriterError: Error {
        case cannotAdd, start(Error?), append(Error?), finish(Error?)
        /// The encoder stopped draining (`isReadyForMoreMediaData` stayed false past the timeout) —
        /// the post-MLX hardware-VideoToolbox stall. Raised instead of hanging forever.
        case encoderStalled(String)
    }

    /// How long `waitReady` waits for `isReadyForMoreMediaData` before declaring the encoder stalled.
    /// A real drain resumes in milliseconds; a stall never recovers, so this bounds the "looks like a
    /// hang" spin-wait into a loud, localized error. Mirrors frame-stream-native `NativeFrameStream`.
    private static let encoderStallTimeout: TimeInterval = 90

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let usingSoftwareEncoder: Bool

    /// `audioPCM` non-nil adds an **AAC-encoding** audio track fed Int16 PCM sample buffers — the
    /// writer emits a proper esds (passthrough of a hand-built AAC description was AVFoundation-invalid).
    /// `software` (default true) requires a SOFTWARE-only HEVC encoder — the hardware VideoToolbox
    /// media engine STALLS when it encodes right after heavy MLX GPU compute (`isReadyForMoreMediaData`
    /// never recovers), which this writer's primary consumer (ForgeOptimizer, encoding post-inference)
    /// triggers. ~3× slower but reliable. Pass `software: false` — or set `MEDIABRIDGE_ENCODE=hardware`
    /// — to opt into the hardware path for callers that don't encode right after Metal work.
    /// `MEDIABRIDGE_ENCODE=software` forces software regardless of the argument. Mirrors
    /// frame-stream-native's `NativeFrameStream.run(software:)`.
    public init(output: URL, width: Int, height: Int,
                audioPCM: (sampleRate: Double, channels: Int)? = nil,
                software: Bool = true) throws {
        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)

        // env overrides the param: MEDIABRIDGE_ENCODE = "hardware" | "software" | (unset → `software`).
        let encEnv = ProcessInfo.processInfo.environment["MEDIABRIDGE_ENCODE"]
        let forceSoftware = encEnv == "software" || (encEnv != "hardware" && software)
        usingSoftwareEncoder = forceSoftware

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if forceSoftware {
            // VideoToolbox encoder-specification keys in STRING form (no VideoToolbox import needed):
            // require a software-only encoder so the hardware media engine — which stalls after heavy
            // MLX compute — is never selected. BT.709 tagging above is preserved either way.
            videoSettings[AVVideoEncoderSpecificationKey] = [
                "EnableHardwareAcceleratedVideoEncoder": false,
                "RequireSoftwareOnlyVideoEncoder": true,
            ] as [String: Any]
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
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

    /// Bound the readiness spin-wait: if the encoder stops draining (`isReadyForMoreMediaData` stuck
    /// false — the post-MLX hardware-VideoToolbox stall) this loop would otherwise spin at ~0% CPU
    /// forever and look like a hang. Time it out into a clear `encoderStalled` error instead.
    private func waitReady(_ input: AVAssetWriterInput) async throws {
        var waited: TimeInterval = 0
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 2_000_000)
            waited += 0.002
            try Task.checkCancellation()
            if waited > Self.encoderStallTimeout {
                throw WriterError.encoderStalled(
                    "video/audio encoder not draining: isReadyForMoreMediaData=false for "
                    + "\(Int(Self.encoderStallTimeout))s (\(usingSoftwareEncoder ? "software" : "hardware") HEVC). "
                    + (usingSoftwareEncoder
                        ? "Unexpected for the software encoder — check for a downstream deadlock."
                        : "This is the hardware-VideoToolbox stall after heavy MLX compute; use the "
                          + "default software path (drop software:false / unset MEDIABRIDGE_ENCODE=hardware)."))
            }
        }
    }
}
