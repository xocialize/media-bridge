//
// NormalizeAudio.swift — MediaBridge
//
// Audio-only normalization: any supported audio input → an audio-only m4a the rest of the fleet can
// rely on (AB-A-0026). The write-side twin of the Layer-A PCM-acquisition conveniences AB-B-0028
// blesses — AVFoundation/AudioToolbox only, MLX-free by boundary.
//
// Two routes, mirroring `normalizeVideoToHEVC`:
//   native containers → AVAssetReader (LPCM, with reader-side sample-rate/channel conversion)
//                       → AVAssetWriter AAC; or a compressed passthrough when the source stream is
//                       already fleet-acceptable and no conversion was requested.
//   Matroska (MKV/WebM/MKA) → MatroskaDemuxer → AudioDecodeSession → PCM sample buffers
//                       → AVAssetWriter AAC. Non-native codecs (Vorbis, …) defer honestly.
//

import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import MatroskaDemux
import MediaImport

extension MediaBridge {

    public struct AudioNormalizeOptions: Sendable {
        public enum ChannelPolicy: Sendable, Equatable {
            /// Keep the source channel count.
            case passthrough
            /// Force 2 channels (downmix >2, upmix mono).
            case stereo
            /// Force 1 channel.
            case mono
        }
        /// Output sample rate; `nil` keeps the source rate. (The LTX world wants 48_000.)
        public var targetSampleRate: Double?
        /// AAC bitrate for the re-encode path. Ignored by passthrough. Clamped into the encoder's
        /// applicable range for the output rate × channels — the range shrinks with the sample rate
        /// (128 kbps is valid at 48 kHz mono and out of range at 24 kHz mono), and an out-of-range
        /// request would otherwise kill the encode outright rather than degrade gracefully.
        public var aacBitrate: Int
        public var channels: ChannelPolicy
        /// Permit the no-re-encode fast path when the source stream is already acceptable
        /// (see `passthroughFormatIDs`). `false` forces an AAC re-encode — callers that need the
        /// output to be *literally AAC* set this, since passthrough may retain MP3/Opus/FLAC.
        public var allowPassthrough: Bool

        public init(targetSampleRate: Double? = nil,
                    aacBitrate: Int = 128_000,
                    channels: ChannelPolicy = .passthrough,
                    allowPassthrough: Bool = true) {
            self.targetSampleRate = targetSampleRate
            self.aacBitrate = aacBitrate
            self.channels = channels
            self.allowPassthrough = allowPassthrough
        }
    }

    public struct NormalizedAudio: Sendable {
        /// Source vocabulary matches `NormalizeResult`: a fourCC on the native path ("aac ", ".mp3",
        /// "lpcm", …), a Matroska CodecID ("A_OPUS", …) on the demux path.
        public let sourceCodecID: String
        /// Duration of the *written* output, in seconds (loaded back from the artifact, not assumed).
        public let duration: Double
        /// Sample rate / channel count actually written.
        public let sampleRate: Double
        public let channels: Int
        /// `true`: the compressed source stream was remuxed byte-identical — no re-encode happened,
        /// and the output codec is the source codec (AAC/MP3/Opus/FLAC), not necessarily AAC.
        public let passthrough: Bool
    }

    /// Normalize any supported input's audio to an audio-only m4a. The output is AAC unless the
    /// passthrough fast path applies (source already an accepted codec in an mp4-family container and
    /// no rate/channel change requested) — see `AudioNormalizeOptions.allowPassthrough`.
    ///
    /// Video tracks in the input are ignored, not an error — "extract + normalize the audio" is the
    /// contract. A file with no audio at all throws `NormalizeError.noAudioTrack`; a Matroska audio
    /// codec outside the native set throws `.deferredCodec` (surfaced, never a silent failure).
    @discardableResult
    public static func normalizeAudio(input: URL, output: URL,
                                      options: AudioNormalizeOptions = .init()) async throws -> NormalizedAudio {
        if matroskaExtensions.contains(input.pathExtension.lowercased()) {
            return try await normalizeMatroskaAudio(input: input, output: output, options: options)
        }
        return try await normalizeNativeAudio(input: input, output: output, options: options)
    }

    /// `normalizeAudio` + the bytes, for callers whose destination is a request body rather than a
    /// file (the LTX cloud lane). Writes to a temporary m4a and reads it back — fine for the clips
    /// this lane carries; anything feature-length should stay on the URL form.
    public static func normalizeAudioData(input: URL,
                                          options: AudioNormalizeOptions = .init()) async throws -> (result: NormalizedAudio, data: Data) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = try await normalizeAudio(input: input, output: tmp, options: options)
        return (result, try Data(contentsOf: tmp))
    }

    // MARK: - Routing / passthrough policy

    /// Containers that take the pure-Swift demux path. Everything else is offered to AVFoundation —
    /// same split as the video normalizer, extended with Matroska's audio-only extension.
    private static let matroskaExtensions: Set<String> = ["mkv", "webm", "mka"]

    /// mp4-family containers whose audio stream can be passthrough-remuxed into m4a.
    private static let mp4FamilyExtensions: Set<String> = ["mp4", "m4a", "m4v", "mov", "qt"]

    /// Compressed formats acceptable *as-is* in the normalized m4a: the intersection of what the
    /// fleet's consumers take (the LTX cloud set) and what mp4 carries + AVFoundation decodes.
    /// Deliberately the base formats only — exotic AAC profiles re-encode rather than passing through.
    private static let passthroughFormatIDs: Set<AudioFormatID> = [
        kAudioFormatMPEG4AAC, kAudioFormatMPEGLayer3, kAudioFormatOpus, kAudioFormatFLAC,
    ]

    private static func resolvedChannels(_ policy: AudioNormalizeOptions.ChannelPolicy,
                                         source: Int) -> Int {
        switch policy {
        case .passthrough: return max(1, source)
        case .stereo: return 2
        case .mono: return 1
        }
    }

    /// The AAC encoder accepts a bitrate SET that depends on sample rate × channels — 128 kbps is
    /// valid at 48 kHz mono and out of range at 24 kHz mono (which tops out at 64 kbps), where the
    /// writer's converter refuses the very first append ("Cannot Encode Media"). Ask AudioToolbox
    /// for the applicable rates at the actual output shape and snap the request onto them, so a
    /// default tuned for 48 kHz cannot sink a low-rate encode. Two measured traits of the answer:
    /// the entries are DISCRETE points (min == max, e.g. 16k/20k/…/64k at 24 kHz mono), and the
    /// array is padded with 0–0 entries that must be ignored or they poison a naive min(). Any
    /// failure to answer leaves the request unchanged — no worse than not asking. (Found by LTX
    /// Studio on the MLXCompanion 24 kHz voice WAVs; AB-A-0026 thread.)
    private static func clampedAACBitrate(_ requested: Int, sampleRate: Double, channels: Int) -> Int {
        guard sampleRate > 0, channels > 0 else { return requested }
        var inASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16, mReserved: 0)
        var outASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var conv: AudioConverterRef?
        guard AudioConverterNew(&inASBD, &outASBD, &conv) == noErr, let c = conv else { return requested }
        defer { AudioConverterDispose(c) }
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(c, kAudioConverterApplicableEncodeBitRates,
                                            &size, nil) == noErr, size > 0 else { return requested }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioConverterGetProperty(c, kAudioConverterApplicableEncodeBitRates,
                                        &size, &ranges) == noErr else { return requested }
        let spans = ranges.filter { $0.mMaximum > 0 }
        guard !spans.isEmpty else { return requested }
        let r = Double(requested)
        if spans.contains(where: { r >= $0.mMinimum && r <= $0.mMaximum }) { return requested }
        var best = spans[0].mMinimum
        for span in spans {
            for edge in [span.mMinimum, span.mMaximum] where abs(edge - r) < abs(best - r) {
                best = edge
            }
        }
        return Int(best)
    }

    // MARK: - Native-container path (AVFoundation)

    private static func normalizeNativeAudio(input: URL, output: URL,
                                             options: AudioNormalizeOptions) async throws -> NormalizedAudio {
        let asset = AVURLAsset(url: input)
        // "Couldn't read the file" and "the file has no audio" are different failures with different
        // fixes — don't collapse the first into the second by swallowing the load error.
        let audioTracks: [AVAssetTrack]
        do { audioTracks = try await asset.loadTracks(withMediaType: .audio) }
        catch { throw NormalizeError.unreadableInput(error.localizedDescription) }
        guard let track = audioTracks.first else { throw NormalizeError.noAudioTrack }
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first else { throw NormalizeError.noAudioTrack }
        let sourceFourCC = fourCC(CMFormatDescriptionGetMediaSubType(format))
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        let sourceRate = asbd?.mSampleRate ?? 0
        let sourceChannels = Int(asbd?.mChannelsPerFrame ?? 0)

        let outChannels = resolvedChannels(options.channels, source: sourceChannels)
        let outRate = options.targetSampleRate ?? sourceRate
        let wantsConversion = outRate != sourceRate || outChannels != sourceChannels

        // Passthrough is *opportunistic*: eligibility is checked up front, but AVFoundation gets the
        // final word — a stream it won't mux into m4a (writer refuses the input) falls back to the
        // AAC re-encode instead of failing the normalize.
        if options.allowPassthrough, !wantsConversion,
           mp4FamilyExtensions.contains(input.pathExtension.lowercased()),
           passthroughFormatIDs.contains(CMFormatDescriptionGetMediaSubType(format)) {
            do {
                try await transferNativeAudio(asset: asset, track: track, output: output,
                                              readerSettings: nil, writerSettings: nil,
                                              sourceFormatHint: format)
                return try await loadResult(output: output, sourceCodecID: sourceFourCC, passthrough: true)
            } catch {
                // fall through to the re-encode
            }
        }

        // Reader-side conversion: AVAssetReaderTrackOutput performs the sample-rate/channel
        // conversion (AudioConverter under the hood), so the writer always receives LPCM already in
        // the output shape — one conversion, in one place.
        var readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: outChannels,
        ]
        if outRate > 0 { readerSettings[AVSampleRateKey] = outRate }
        let effectiveRate = outRate > 0 ? outRate : 48_000
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: effectiveRate,
            AVNumberOfChannelsKey: outChannels,
            AVEncoderBitRateKey: clampedAACBitrate(options.aacBitrate,
                                                   sampleRate: effectiveRate, channels: outChannels),
        ]
        try await transferNativeAudio(asset: asset, track: track, output: output,
                                      readerSettings: readerSettings, writerSettings: writerSettings,
                                      sourceFormatHint: nil)
        return try await loadResult(output: output, sourceCodecID: sourceFourCC, passthrough: false)
    }

    /// One reader→writer pump serves both native modes: `nil` settings on both sides is the
    /// compressed passthrough (the writer needs the `sourceFormatHint`); LPCM reader settings + AAC
    /// writer settings is the re-encode. Single audio input, so none of the multi-track interleave
    /// throttling `NativeMP4Writer.finishAudio` exists for can arise here.
    private static func transferNativeAudio(asset: AVURLAsset, track: AVAssetTrack, output: URL,
                                            readerSettings: [String: Any]?,
                                            writerSettings: [String: Any]?,
                                            sourceFormatHint: CMFormatDescription?) async throws {
        let reader = try AVAssetReader(asset: asset)
        let trackOut = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        trackOut.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOut) else { throw NormalizeError.exportFailed("reader rejected audio track") }
        reader.add(trackOut)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings,
                                       sourceFormatHint: sourceFormatHint)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw NormalizeError.exportFailed("writer rejected audio input") }
        writer.add(input)

        // Failure messages carry the encode shape — "Cannot Encode Media" alone says nothing about
        // which rate × channels × bitrate the converter refused.
        let mode: String
        if let ws = writerSettings {
            mode = "AAC \(Int(ws[AVSampleRateKey] as? Double ?? 0)) Hz ×\(ws[AVNumberOfChannelsKey] as? Int ?? 0)"
                 + " @ \(ws[AVEncoderBitRateKey] as? Int ?? 0) bps"
        } else {
            mode = "passthrough"
        }

        do {
            guard reader.startReading() else {
                throw NormalizeError.exportFailed("reader: \(reader.error?.localizedDescription ?? "startReading failed")")
            }
            guard writer.startWriting() else {
                throw NormalizeError.exportFailed("writer: \(writer.error?.localizedDescription ?? "startWriting failed")")
            }
            writer.startSession(atSourceTime: .zero)

            while let sample = trackOut.copyNextSampleBuffer() {
                try await waitReady(input)
                guard input.append(sample) else {
                    throw NormalizeError.exportFailed("append [\(mode)]: \(writer.error?.localizedDescription ?? "unknown")")
                }
            }
            guard reader.status == .completed else {
                throw NormalizeError.exportFailed("reader: \(reader.error?.localizedDescription ?? "status \(reader.status.rawValue)")")
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw NormalizeError.exportFailed("writer [\(mode)]: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
            }
        } catch {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            // A failed write must not leave a half-written artifact behind — a downstream probe of
            // the leftover reads as a fresh mystery ("no audio track") far from the actual failure.
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // MARK: - Matroska path (pure-Swift demux → AudioConverter decode → AAC)

    private static func normalizeMatroskaAudio(input: URL, output: URL,
                                               options: AudioNormalizeOptions) async throws -> NormalizedAudio {
        let demuxer = MatroskaDemuxer(data: try Data(contentsOf: input))
        try demuxer.parseHeaders()

        let audioTracks = demuxer.tracks.filter { $0.type == .audio }
        guard let track = audioTracks.first(where: {
            AudioDecodeSession.isSupported(codecID: $0.codecID)
                && SupportGate.status(forCodecID: $0.codecID) == .nativeAudio
                && (!AudioDecodeSession.requiresCodecPrivate(codecID: $0.codecID) || $0.codecPrivate != nil)
        }) else {
            // An audio track exists but none is natively decodable → defer with its name; no audio
            // at all → say that instead. (Unlike the A/V normalize, audio IS the deliverable here,
            // so a bad track cannot "degrade to video-only" — it has to surface.)
            if let undecodable = audioTracks.first {
                throw NormalizeError.deferredCodec(undecodable.codecID)
            }
            throw NormalizeError.noAudioTrack
        }

        let packets = try demuxer.readAllPackets()
            .filter { $0.trackNumber == track.number }.map(\.data)
        let decoder = try AudioDecodeSession(
            codecID: track.codecID, codecPrivate: track.codecPrivate,
            sampleRate: track.audio?.samplingFrequency ?? 48_000,
            channels: track.audio?.channels ?? 2, bitDepth: track.audio?.bitDepth ?? 16)
        let pcm = try decoder.decode(packets)
        guard pcm.frameCount > 0 else { throw NormalizeError.noAudioTrack }

        // The writer converts: the appended LPCM is at the decode rate/channel shape, and the AAC
        // output settings carry the requested shape — AVAssetWriterInput's converter bridges the two
        // (verified by test; Opus in particular always decodes at 48 kHz regardless of track rate).
        let outChannels = resolvedChannels(options.channels, source: pcm.channels)
        let outRate = options.targetSampleRate ?? pcm.sampleRate

        let bitrate = clampedAACBitrate(options.aacBitrate, sampleRate: outRate, channels: outChannels)
        let mode = "AAC \(Int(outRate)) Hz ×\(outChannels) @ \(bitrate) bps"
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outRate,
            AVNumberOfChannelsKey: outChannels,
            AVEncoderBitRateKey: bitrate,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw NormalizeError.exportFailed("writer rejected audio input") }
        writer.add(input)
        do {
            guard writer.startWriting() else {
                throw NormalizeError.exportFailed("writer: \(writer.error?.localizedDescription ?? "startWriting failed")")
            }
            writer.startSession(atSourceTime: .zero)

            for chunk in try pcm.makeSampleBuffers() {
                try await waitReady(input)
                guard input.append(chunk) else {
                    throw NormalizeError.exportFailed("append [\(mode)]: \(writer.error?.localizedDescription ?? "unknown")")
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw NormalizeError.exportFailed("writer [\(mode)]: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
            }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return try await loadResult(output: output, sourceCodecID: track.codecID, passthrough: false)
    }

    // MARK: - Shared

    /// The result is read back from the artifact, not assumed from the request — the same "a
    /// completed export that wrote nothing must not masquerade as a deliverable" stance as
    /// `remuxToMP4`, extended to the format facts.
    private static func loadResult(output: URL, sourceCodecID: String,
                                   passthrough: Bool) async throws -> NormalizedAudio {
        let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > 0 else { throw NormalizeError.exportFailed("normalize produced no bytes") }
        let asset = AVURLAsset(url: output)
        let outputTracks: [AVAssetTrack]
        do { outputTracks = try await asset.loadTracks(withMediaType: .audio) }
        catch { throw NormalizeError.exportFailed("output unreadable: \(error.localizedDescription)") }
        guard let track = outputTracks.first,
              let format = (try? await track.load(.formatDescriptions))?.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            throw NormalizeError.exportFailed("output has no readable audio track")
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        return NormalizedAudio(sourceCodecID: sourceCodecID,
                               duration: duration,
                               sampleRate: asbd.mSampleRate,
                               channels: Int(asbd.mChannelsPerFrame),
                               passthrough: passthrough)
    }

    /// Same bounded readiness wait as `NativeMP4Writer.waitReady`, minus the HEVC-stall diagnostics:
    /// a single audio input has no sibling to throttle against, so a stuck `isReadyForMoreMediaData`
    /// here is an encoder fault worth a loud error, not a hang.
    private static func waitReady(_ input: AVAssetWriterInput) async throws {
        var waited: TimeInterval = 0
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 2_000_000)
            waited += 0.002
            try Task.checkCancellation()
            if waited > 90 {
                throw NormalizeError.exportFailed("audio input not draining (90 s)")
            }
        }
    }
}
