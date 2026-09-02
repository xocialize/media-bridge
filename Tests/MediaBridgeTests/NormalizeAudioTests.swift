import AVFoundation
import CoreVideo
import XCTest
@testable import MediaBridge
@testable import MediaImport

/// `MediaBridge.normalizeAudio` (AB-A-0026): any supported audio input → audio-only AAC m4a, with an
/// opportunistic no-re-encode passthrough. The pure-Swift fixtures (WAV via AVAudioFile, video-only
/// mp4 via NativeMP4Writer) keep the core cases running everywhere; the Matroska cases synthesize
/// Opus/Vorbis WebM with ffmpeg and skip where it isn't installed — same convention as AudioMuxTests.
final class NormalizeAudioTests: XCTestCase {

    // MARK: - Fixtures

    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        super.tearDown()
    }

    private func scratchURL(_ ext: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        scratch.append(url)
        return url
    }

    /// Sine-tone WAV synthesized with AVAudioFile — no external tooling, exact rate/channel control.
    /// 24 kHz mono is the MLXCompanion voice-file shape that motivated the surface.
    private func makeWAV(rate: Double, channels: Int, seconds: Double) throws -> URL {
        let url = scratchURL("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate,
                                   channels: AVAudioChannelCount(channels))!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<channels {
            let samples = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                samples[i] = sinf(2 * .pi * 440 * Float(i) / Float(rate)) * 0.5
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// Int16 mono sine (amplitude 0.5) in the decode layer's own `PCM` shape — what NativeMP4Writer's
    /// AAC audio input takes, and the same construction the pad uses for its silence.
    private func tonePCM(rate: Double, seconds: Double) -> AudioDecodeSession.PCM {
        let frames = Int(rate * seconds)
        var data = Data(count: frames * 2)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { p[i] = Int16(16_000 * sin(2 * .pi * 440 * Double(i) / rate)) }
        }
        return AudioDecodeSession.PCM(data: data, sampleRate: rate, channels: 1)
    }

    /// An mp4 through NativeMP4Writer: `videoSeconds` of 25 fps black frames plus, when
    /// `audioSeconds > 0`, an AAC track of that length — the A/V shape where the container's duration
    /// and the audio track's disagree. Audio goes first and is closed (the writer's throttle rule).
    private func makeAVMP4(videoSeconds: Double, audioSeconds: Double,
                           rate: Double = 48_000) async throws -> URL {
        let url = scratchURL("mp4")
        let writer = try NativeMP4Writer(
            output: url, width: 64, height: 64,
            audioPCM: audioSeconds > 0 ? (sampleRate: rate, channels: 1) : nil)
        if audioSeconds > 0 {
            for chunk in try tonePCM(rate: rate, seconds: audioSeconds).makeSampleBuffers() {
                try await writer.appendAudio(chunk)
            }
            writer.finishAudio()
        }
        for i in 0..<Int((videoSeconds * 25).rounded()) {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
            let buffer = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0,
                   CVPixelBufferGetBytesPerRow(buffer) * 64)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try await writer.appendVideo(buffer, ptsNanos: Int64(i) * 40_000_000)
        }
        try await writer.finish()
        return url
    }

    /// Video-only mp4 (3 black frames) — the `.noAudioTrack` shape.
    private func makeVideoOnlyMP4() async throws -> URL {
        try await makeAVMP4(videoSeconds: 0.12, audioSeconds: 0)
    }

    private func tool(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] {
            let p = dir + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func makeWebM(codecArgs: [String], seconds: Double = 2) throws -> URL {
        guard let ffmpeg = tool("ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        let url = scratchURL("webm")
        try run(ffmpeg, ["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"]
                        + codecArgs + [url.path])
        // A missing encoder in this ffmpeg build produces no file — that's a fixture gap, not a defect.
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > 0 else { throw XCTSkip("ffmpeg could not synthesize \(codecArgs.joined(separator: " "))") }
        return url
    }

    /// The output's format facts, read the way a consumer would (AVFoundation, not our own result).
    private func audioFacts(_ url: URL) async throws -> (codec: FourCharCode, rate: Double,
                                                         channels: Int, duration: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        let duration = try await asset.load(.duration).seconds
        return (CMFormatDescriptionGetMediaSubType(format), asbd.mSampleRate,
                Int(asbd.mChannelsPerFrame), duration)
    }

    /// The output decoded to interleaved Int16 the way a consumer would (AVAssetReader) — the samples
    /// themselves, for the assertions a header cannot make (tone vs silence, exact length).
    private func decodedPCM(_ url: URL) async throws -> (rate: Double, channels: Int, samples: [Int16]) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var rate = 0.0, channels = 1
        var samples: [Int16] = []
        while let s = out.copyNextSampleBuffer() {
            if let fmt = CMSampleBufferGetFormatDescription(s),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                rate = asbd.mSampleRate
                channels = Int(asbd.mChannelsPerFrame)
            }
            guard let block = CMSampleBufferGetDataBuffer(s) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { p in
                samples.append(contentsOf: UnsafeBufferPointer(start: p, count: length / 2))
            }
        }
        return (rate, channels, samples)
    }

    /// Mean |x| in [0, 1] over the frames in [from, to) seconds: a 0.5-amplitude sine ≈ 0.32,
    /// digital silence ≈ 0.
    private func meanAbs(_ pcm: (rate: Double, channels: Int, samples: [Int16]),
                         from: Double, to: Double) -> Double {
        let lo = Int(from * pcm.rate) * pcm.channels
        let hi = min(pcm.samples.count, Int(to * pcm.rate) * pcm.channels)
        guard hi > lo else { return 0 }
        var sum = 0.0
        for i in lo..<hi { sum += Double(abs(Int32(pcm.samples[i]))) }
        return sum / (Double(hi - lo) * 32768)
    }

    // MARK: - Native path

    func testWAV24kMonoTo48kAAC() async throws {
        let src = try makeWAV(rate: 24_000, channels: 1, seconds: 2)
        let dst = scratchURL("m4a")
        let result = try await MediaBridge.normalizeAudio(
            input: src, output: dst,
            options: .init(targetSampleRate: 48_000))
        XCTAssertFalse(result.passthrough)
        XCTAssertEqual(result.sampleRate, 48_000)
        XCTAssertEqual(result.channels, 1)
        let facts = try await audioFacts(dst)
        XCTAssertEqual(facts.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(facts.rate, 48_000)
        XCTAssertEqual(facts.channels, 1)
        XCTAssertEqual(facts.duration, 2, accuracy: 0.25)
    }

    func testPreservesSourceRateAndChannelsByDefault() async throws {
        let src = try makeWAV(rate: 44_100, channels: 2, seconds: 1)
        let dst = scratchURL("m4a")
        let result = try await MediaBridge.normalizeAudio(input: src, output: dst)
        XCTAssertFalse(result.passthrough)
        let facts = try await audioFacts(dst)
        XCTAssertEqual(facts.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(facts.rate, 44_100)
        XCTAssertEqual(facts.channels, 2)
    }

    func testDownmixToMono() async throws {
        let src = try makeWAV(rate: 48_000, channels: 2, seconds: 1)
        let dst = scratchURL("m4a")
        let result = try await MediaBridge.normalizeAudio(
            input: src, output: dst, options: .init(channels: .mono))
        XCTAssertEqual(result.channels, 1)
        let facts = try await audioFacts(dst)
        XCTAssertEqual(facts.channels, 1)
    }

    /// Normalizing an already-normalized m4a must take the no-re-encode path: same codec, and a
    /// stream so close in size that an accidental re-encode (whose size tracks bitrate, not source)
    /// would be caught.
    func testSecondPassIsPassthrough() async throws {
        let wav = try makeWAV(rate: 48_000, channels: 2, seconds: 2)
        let first = scratchURL("m4a")
        _ = try await MediaBridge.normalizeAudio(input: wav, output: first)
        let firstBytes = try XCTUnwrap(first.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        let second = scratchURL("m4a")
        let result = try await MediaBridge.normalizeAudio(input: first, output: second)
        XCTAssertTrue(result.passthrough)
        let secondBytes = try XCTUnwrap(second.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(Double(secondBytes), Double(firstBytes),
                       accuracy: Double(firstBytes) * 0.05, "passthrough must not re-encode")
        let facts = try await audioFacts(second)
        XCTAssertEqual(facts.codec, kAudioFormatMPEG4AAC)
    }

    func testAllowPassthroughFalseForcesReencode() async throws {
        let wav = try makeWAV(rate: 48_000, channels: 1, seconds: 1)
        let first = scratchURL("m4a")
        _ = try await MediaBridge.normalizeAudio(input: wav, output: first)
        let second = scratchURL("m4a")
        let result = try await MediaBridge.normalizeAudio(
            input: first, output: second, options: .init(allowPassthrough: false))
        XCTAssertFalse(result.passthrough)
        let facts = try await audioFacts(second)
        XCTAssertEqual(facts.codec, kAudioFormatMPEG4AAC)
    }

    /// The LTX Studio field bug (AB-A-0026 thread): `targetSampleRate: nil` on a 24 kHz mono WAV
    /// failed while 48 kHz worked — the default 128 kbps sits outside the AAC encoder's applicable
    /// range at 24 kHz mono, so the writer refused the first append and left a broken artifact.
    /// The bitrate must clamp to the encoder's range for the OUTPUT shape, not assume 48 kHz's.
    func testLowRateSourcePreservedByDefault() async throws {
        let src = try makeWAV(rate: 24_000, channels: 1, seconds: 2)
        let dst = scratchURL("m4a")
        let result = try await MediaBridge.normalizeAudio(input: src, output: dst)
        XCTAssertFalse(result.passthrough)
        let facts = try await audioFacts(dst)
        XCTAssertEqual(facts.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(facts.rate, 24_000, "nil target must preserve the source rate")
        XCTAssertEqual(facts.duration, 2, accuracy: 0.25)
    }

    /// The encoder's applicable bitrates are DISCRETE points (and the SDK pads the list with 0–0
    /// entries): a request between points must snap to the nearest valid one, and a request below
    /// the lowest must snap UP — the padding entries must never read as "0 is allowed".
    func testOffMenuBitratesSnapToValidPoints() async throws {
        let src = try makeWAV(rate: 24_000, channels: 1, seconds: 1)
        for requested in [50_000, 4_000] {
            let dst = scratchURL("m4a")
            _ = try await MediaBridge.normalizeAudio(
                input: src, output: dst, options: .init(aacBitrate: requested))
            let facts = try await audioFacts(dst)
            XCTAssertEqual(facts.codec, kAudioFormatMPEG4AAC, "requested \(requested)")
            XCTAssertEqual(facts.rate, 24_000, "requested \(requested)")
        }
    }

    func testTelephonyRatePreservedByDefault() async throws {
        let src = try makeWAV(rate: 8_000, channels: 1, seconds: 1)
        let dst = scratchURL("m4a")
        _ = try await MediaBridge.normalizeAudio(input: src, output: dst)
        let facts = try await audioFacts(dst)
        XCTAssertEqual(facts.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(facts.rate, 8_000)
    }

    /// A failed encode must not leave a half-written artifact for a downstream probe to trip on,
    /// and an unreadable INPUT must say so — not masquerade as "no audio track". Both halves of
    /// the diagnosis the Studio thread paid four extra probes for.
    func testUnreadableInputSurfacesUnderlyingError() async throws {
        let src = scratchURL("m4a")
        try Data().write(to: src)     // zero-byte "m4a"
        let dst = scratchURL("m4a")
        do {
            _ = try await MediaBridge.normalizeAudio(input: src, output: dst)
            XCTFail("expected a throw")
        } catch let error as MediaBridge.NormalizeError {
            guard case .unreadableInput = error else {
                return XCTFail("expected unreadableInput, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.path),
                       "no output artifact may exist after a failed normalize")
    }

    // MARK: - padToDuration (AB-A-0028: grid-fit silence pad, single generation)

    /// The consumer's grid tolerance (LTX Studio's AudioIngest, ~11 ms): a padded artifact must land
    /// on the grid at least that precisely, or the caller spends the second generation anyway. The
    /// old ±0.1 s window was 2.4 frames at 24 fps — wider than the drift the feature exists to remove.
    private let gridAccuracy = 0.011

    /// Short content pads UP with trailing silence to the requested duration — in the same encode
    /// generation, at a fractional (frame-grid-shaped) target, with the source rate preserved.
    func testPadToDurationExtendsShortContent() async throws {
        let src = try makeWAV(rate: 24_000, channels: 1, seconds: 1)
        let dst = scratchURL("m4a")
        let result = try await MediaBridge.normalizeAudio(
            input: src, output: dst, options: .init(padToDuration: 2.52))
        XCTAssertFalse(result.passthrough)
        XCTAssertEqual(result.duration, 2.52, accuracy: gridAccuracy)
        let facts = try await audioFacts(dst)
        XCTAssertEqual(facts.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(facts.rate, 24_000)
    }

    /// The README's advertised shape — resample AND pad in one call — checked on the samples, not
    /// just the header: the head still carries the tone, the tail is digital silence, and the decoded
    /// length lands on the grid. A pad that wrote garbage, overlapped the content, or arrived in the
    /// wrong shape would keep the header duration intact and fail here.
    func testPadTailIsSilentAndContentIntact() async throws {
        let src = try makeWAV(rate: 24_000, channels: 1, seconds: 1)
        let dst = scratchURL("m4a")
        let result = try await MediaBridge.normalizeAudio(
            input: src, output: dst, options: .init(targetSampleRate: 48_000, padToDuration: 2.52))
        XCTAssertEqual(result.sampleRate, 48_000)
        XCTAssertEqual(result.duration, 2.52, accuracy: gridAccuracy)
        let pcm = try await decodedPCM(dst)
        XCTAssertEqual(pcm.rate, 48_000)
        XCTAssertEqual(Double(pcm.samples.count / pcm.channels) / pcm.rate, 2.52, accuracy: gridAccuracy)
        XCTAssertGreaterThan(meanAbs(pcm, from: 0.1, to: 0.9), 0.2, "the tone must survive the pad")
        XCTAssertLessThan(meanAbs(pcm, from: 1.05, to: 2.5), 0.005, "the pad must be digital silence")
    }

    /// The operator policy the option encodes: pad up, NEVER trim — a target shorter than the
    /// content leaves the content whole.
    func testPadNeverTrims() async throws {
        let src = try makeWAV(rate: 48_000, channels: 1, seconds: 2)
        let dst = scratchURL("m4a")
        let result = try await MediaBridge.normalizeAudio(
            input: src, output: dst, options: .init(padToDuration: 0.5))
        XCTAssertEqual(result.duration, 2, accuracy: gridAccuracy)
    }

    /// Padding forces the re-encode only when it would actually happen: a passthrough-eligible
    /// source shorter than the target re-encodes (silence cannot splice into a compressed stream),
    /// while one already at/over the target passes through untouched.
    func testPadDisablesPassthroughOnlyWhenNeeded() async throws {
        let wav = try makeWAV(rate: 48_000, channels: 2, seconds: 2)
        let aac = scratchURL("m4a")
        _ = try await MediaBridge.normalizeAudio(input: wav, output: aac)

        let padded = scratchURL("m4a")
        let needsPad = try await MediaBridge.normalizeAudio(
            input: aac, output: padded, options: .init(padToDuration: 3.0))
        XCTAssertFalse(needsPad.passthrough, "a pad that must happen requires the re-encode")
        XCTAssertEqual(needsPad.duration, 3.0, accuracy: gridAccuracy)

        let untouched = scratchURL("m4a")
        let noPad = try await MediaBridge.normalizeAudio(
            input: aac, output: untouched, options: .init(padToDuration: 1.0))
        XCTAssertTrue(noPad.passthrough, "a no-op pad must not cost the passthrough")
        XCTAssertEqual(noPad.duration, 2, accuracy: gridAccuracy)
    }

    /// "Already at the target" is judged on the AUDIO track, never the container: an mp4 whose video
    /// outlasts its audio used to read as long enough and pass the short audio through unpadded.
    func testPadJudgesTheAudioTrackNotTheContainer() async throws {
        let src = try await makeAVMP4(videoSeconds: 3, audioSeconds: 1)

        let padded = scratchURL("m4a")
        let needsPad = try await MediaBridge.normalizeAudio(
            input: src, output: padded, options: .init(padToDuration: 2.0))
        XCTAssertFalse(needsPad.passthrough, "1 s of audio under 3 s of video is still 1 s of audio")
        XCTAssertEqual(needsPad.duration, 2.0, accuracy: gridAccuracy)

        let untouched = scratchURL("m4a")
        let noPad = try await MediaBridge.normalizeAudio(
            input: src, output: untouched, options: .init(padToDuration: 0.5))
        XCTAssertTrue(noPad.passthrough, "a no-op pad must not cost the passthrough")
        XCTAssertEqual(noPad.duration, 1.0, accuracy: gridAccuracy)
    }

    /// One definition of "at the target" on both routes: a shortfall inside `padTolerance` neither
    /// costs a passthrough source its remux nor adds a sliver of silence on the re-encode route.
    func testSubToleranceShortfallCountsAsAtTheTarget() async throws {
        let wav = try makeWAV(rate: 48_000, channels: 1, seconds: 2)
        let target = 2.0 + MediaBridge.padTolerance / 2

        let aac = scratchURL("m4a")
        _ = try await MediaBridge.normalizeAudio(input: wav, output: aac)
        let remuxed = scratchURL("m4a")
        let viaPassthrough = try await MediaBridge.normalizeAudio(
            input: aac, output: remuxed, options: .init(padToDuration: target))
        XCTAssertTrue(viaPassthrough.passthrough)

        let control = scratchURL("m4a")
        _ = try await MediaBridge.normalizeAudio(input: wav, output: control)
        let reencoded = scratchURL("m4a")
        _ = try await MediaBridge.normalizeAudio(
            input: wav, output: reencoded, options: .init(padToDuration: target))
        let padFrames = try await decodedPCM(reencoded).samples.count
        let controlFrames = try await decodedPCM(control).samples.count
        XCTAssertEqual(padFrames, controlFrames, "no sub-tolerance sliver of silence")
    }

    /// A non-finite target (a grid computed against a zero frame rate) is refused before any file is
    /// touched — it used to trap at the frame-count conversion mid-encode and leave the artifact.
    func testNonFinitePadThrowsUpFront() async throws {
        let src = try makeWAV(rate: 48_000, channels: 1, seconds: 1)
        for bad in [Double.infinity, -.infinity, .nan] {
            let dst = scratchURL("m4a")
            do {
                _ = try await MediaBridge.normalizeAudio(
                    input: src, output: dst, options: .init(padToDuration: bad))
                XCTFail("expected a throw for padToDuration \(bad)")
            } catch let error as MediaBridge.NormalizeError {
                guard case .exportFailed = error else {
                    return XCTFail("expected exportFailed, got \(error)")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: dst.path), "\(bad)")
        }
    }

    func testMatroskaPadToDuration() async throws {
        let src = try makeWebM(codecArgs: ["-c:a", "libopus"])
        let dst = scratchURL("m4a")
        let result = try await MediaBridge.normalizeAudio(
            input: src, output: dst, options: .init(padToDuration: 3.0))
        XCTAssertFalse(result.passthrough)
        XCTAssertEqual(result.duration, 3.0, accuracy: gridAccuracy)
        let facts = try await audioFacts(dst)
        XCTAssertEqual(facts.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(facts.duration, 3.0, accuracy: gridAccuracy)
    }

    func testVideoOnlyInputThrowsNoAudioTrack() async throws {
        let src = try await makeVideoOnlyMP4()
        let dst = scratchURL("m4a")
        do {
            _ = try await MediaBridge.normalizeAudio(input: src, output: dst)
            XCTFail("expected noAudioTrack")
        } catch let error as MediaBridge.NormalizeError {
            XCTAssertEqual(error, .noAudioTrack)
        }
    }

    func testNormalizeAudioDataReturnsPlayableBytes() async throws {
        let src = try makeWAV(rate: 24_000, channels: 1, seconds: 1)
        let (result, data) = try await MediaBridge.normalizeAudioData(
            input: src, options: .init(targetSampleRate: 48_000))
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(result.sampleRate, 48_000)
        // m4a magic: 'ftyp' at byte 4 — enough to prove these are container bytes, not raw PCM.
        XCTAssertEqual(data.subdata(in: 4..<8), Data("ftyp".utf8))
    }

    // MARK: - Matroska path (ffmpeg-synthesized fixtures)

    func testWebMOpusBecomesAACM4A() async throws {
        let src = try makeWebM(codecArgs: ["-c:a", "libopus"])
        let dst = scratchURL("m4a")
        let result = try await MediaBridge.normalizeAudio(input: src, output: dst)
        XCTAssertEqual(result.sourceCodecID, "A_OPUS")
        XCTAssertFalse(result.passthrough)
        let facts = try await audioFacts(dst)
        XCTAssertEqual(facts.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(facts.rate, 48_000, "Opus decodes at 48 kHz; no rate was requested")
        XCTAssertEqual(facts.duration, 2, accuracy: 0.25)
    }

    /// The Matroska route claims AVAssetWriterInput bridges a decode-rate LPCM stream to different
    /// AAC output settings — this is that claim's test (48 kHz Opus decode → 44.1 kHz AAC).
    func testMatroskaHonorsTargetSampleRate() async throws {
        let src = try makeWebM(codecArgs: ["-c:a", "libopus"])
        let dst = scratchURL("m4a")
        let result = try await MediaBridge.normalizeAudio(
            input: src, output: dst, options: .init(targetSampleRate: 44_100))
        XCTAssertEqual(result.sampleRate, 44_100)
        let facts = try await audioFacts(dst)
        XCTAssertEqual(facts.rate, 44_100)
    }

    func testVorbisDefersHonestly() async throws {
        // Homebrew ffmpeg ships without libvorbis; the built-in experimental encoder needs stereo.
        let src = try makeWebM(codecArgs: ["-ac", "2", "-c:a", "vorbis", "-strict", "-2"])
        let dst = scratchURL("m4a")
        do {
            _ = try await MediaBridge.normalizeAudio(input: src, output: dst)
            XCTFail("expected deferredCodec")
        } catch let error as MediaBridge.NormalizeError {
            XCTAssertEqual(error, .deferredCodec("A_VORBIS"))
        }
    }
}
