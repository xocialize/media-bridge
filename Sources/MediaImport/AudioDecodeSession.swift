//
// AudioDecodeSession.swift — MediaImport
//
// AudioConverter-based decode of compressed audio packets → interleaved Int16 PCM. The output PCM
// is re-encoded to AAC by the writer (AVAssetWriter, which produces a valid esds) — more robust than
// trying to passthrough a hand-built AAC format description, and it generalizes to FLAC/Opus once
// their cookies + frames-per-packet are wired. AAC first (the common case).
//

import AudioToolbox
import CoreMedia
import Foundation

public final class AudioDecodeSession {

    public enum AudioDecodeError: Error { case unsupported(String), converter(OSStatus) }

    /// Decoded interleaved Int16 PCM plus the description the writer needs to re-encode it.
    public struct PCM {
        public let data: Data
        public let sampleRate: Double
        public let channels: Int
        public var frameCount: Int { data.count / (2 * max(1, channels)) }
    }

    private let converter: AudioConverterRef
    private let channels: Int
    private let sampleRate: Double          // the OUTPUT (PCM) sample rate

    /// Matroska audio CodecIDs this session can decode via AudioConverter. AAC + Opus verified; AC-3 /
    /// E-AC-3 / MPEG Layer I-III are first-class AudioToolbox decoders (unlike FLAC, they need no magic
    /// cookie). FLAC is NOT here: AudioConverter rejects FLAC's ASBD ('bada' at AudioConverterNew) —
    /// macOS decodes FLAC only via the file-based AVAudioFile/ExtAudioFile path (a heavier detour).
    public static func isSupported(codecID: String) -> Bool {
        codecID.hasPrefix("A_AAC") || codecID == "A_OPUS"
            || codecID == "A_AC3" || codecID == "A_EAC3"
            || codecID == "A_MPEG/L1" || codecID == "A_MPEG/L2" || codecID == "A_MPEG/L3"
    }

    /// AAC/Opus/FLAC carry a MANDATORY magic cookie in CodecPrivate (AudioSpecificConfig / OpusHead /
    /// STREAMINFO) — AudioConverter can't decode them without it. AC-3/E-AC-3/MPEG Layer I-III are
    /// self-describing and Matroska stores no CodecPrivate for them, so a track selector must not
    /// require one for these.
    public static func requiresCodecPrivate(codecID: String) -> Bool {
        codecID.hasPrefix("A_AAC") || codecID == "A_OPUS" || codecID == "A_FLAC"
    }

    public init(codecID: String, codecPrivate: Data?, sampleRate: Double, channels: Int,
                bitDepth: Int = 16) throws {
        self.channels = max(1, channels)

        // codec → (AudioToolbox formatID, frames/packet hint, decode output sample rate, source bit
        // depth). Opus always decodes at 48 kHz; AAC/FLAC at the track rate. FLAC is lossless, so its
        // decoder needs the source bit depth in the input ASBD (0 → AudioConverterNew fails 'bada').
        let formatID: AudioFormatID
        let framesPerPacket: UInt32
        let inputRate: Double
        var inBits: UInt32 = 0
        switch codecID {
        case let c where c.hasPrefix("A_AAC"): formatID = kAudioFormatMPEG4AAC; framesPerPacket = 1024; inputRate = sampleRate
        case "A_FLAC":                         formatID = kAudioFormatFLAC;      framesPerPacket = 4096; inputRate = sampleRate; inBits = UInt32(bitDepth > 0 ? bitDepth : 16)
        case "A_OPUS":                         formatID = kAudioFormatOpus;      framesPerPacket = 960;  inputRate = 48_000
        // AC-3 / E-AC-3 / MPEG Layer I-III: native AudioToolbox decoders, no magic cookie. framesPerPacket
        // is the nominal samples-per-syncframe hint; AudioConverter derives the true count per packet
        // description (E-AC-3 blocks and MPEG-2 Layer III at 576 vary). AC-3 since macOS 10.2, E-AC-3 10.11.
        case "A_AC3":                          formatID = kAudioFormatAC3;         framesPerPacket = 1536; inputRate = sampleRate
        case "A_EAC3":                         formatID = kAudioFormatEnhancedAC3; framesPerPacket = 1536; inputRate = sampleRate
        case "A_MPEG/L3":                      formatID = kAudioFormatMPEGLayer3;  framesPerPacket = 1152; inputRate = sampleRate
        case "A_MPEG/L2":                      formatID = kAudioFormatMPEGLayer2;  framesPerPacket = 1152; inputRate = sampleRate
        case "A_MPEG/L1":                      formatID = kAudioFormatMPEGLayer1;  framesPerPacket = 384;  inputRate = sampleRate
        default: throw AudioDecodeError.unsupported(codecID)
        }
        self.sampleRate = inputRate

        var inASBD = AudioStreamBasicDescription(
            mSampleRate: inputRate, mFormatID: formatID, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(self.channels), mBitsPerChannel: inBits, mReserved: 0)

        // FLAC's decoder rejects a hand-built input ASBD ('bada'); derive the correct one from the
        // magic cookie (fLaC + STREAMINFO) via the FormatList property.
        if formatID == kAudioFormatFLAC, let cookie = codecPrivate, !cookie.isEmpty {
            var item = AudioFormatListItem()
            var sz = UInt32(MemoryLayout<AudioFormatListItem>.size)
            let st = cookie.withUnsafeBytes {
                AudioFormatGetProperty(kAudioFormatProperty_FormatList,
                                       UInt32(cookie.count), $0.baseAddress, &sz, &item)
            }
            if st == noErr { inASBD = item.mASBD }
        }
        var outASBD = AudioStreamBasicDescription(
            mSampleRate: inputRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * self.channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * self.channels), mChannelsPerFrame: UInt32(self.channels),
            mBitsPerChannel: 16, mReserved: 0)

        var conv: AudioConverterRef?
        let st = AudioConverterNew(&inASBD, &outASBD, &conv)
        guard st == noErr, let c = conv else { throw AudioDecodeError.converter(st) }
        converter = c
        // Magic cookie: AAC = AudioSpecificConfig; FLAC = fLaC marker + STREAMINFO; Opus = OpusHead.
        // In Matroska, each is exactly the track CodecPrivate.
        if let cookie = codecPrivate, !cookie.isEmpty {
            _ = cookie.withUnsafeBytes {
                AudioConverterSetProperty(c, kAudioConverterDecompressionMagicCookie,
                                          UInt32(cookie.count), $0.baseAddress!)
            }
        }
    }

    deinit { AudioConverterDispose(converter) }

    /// Pull context handed to the C input callback: supplies one compressed packet per call.
    private final class Pull {
        let packets: [Data]
        let channels: Int
        var index = 0
        var current = [UInt8]()
        var aspd = AudioStreamPacketDescription()
        init(_ p: [Data], channels: Int) { packets = p; self.channels = channels }
    }

    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, outPacketDescription, inUserData in
        let ctx = Unmanaged<Pull>.fromOpaque(inUserData!).takeUnretainedValue()
        guard ctx.index < ctx.packets.count else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        let pkt = ctx.packets[ctx.index]; ctx.index += 1
        ctx.current = [UInt8](pkt)
        ctx.current.withUnsafeMutableBufferPointer { buf in
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mNumberChannels = UInt32(ctx.channels)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(buf.count)
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(buf.baseAddress)
        }
        ctx.aspd = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                mDataByteSize: UInt32(pkt.count))
        outPacketDescription?.pointee = withUnsafeMutablePointer(to: &ctx.aspd) { $0 }
        ioNumberDataPackets.pointee = 1
        return noErr
    }

    /// Decode all packets → interleaved Int16 PCM.
    public func decode(_ packets: [Data]) throws -> PCM {
        let pull = Pull(packets, channels: channels)
        let ctxPtr = Unmanaged.passUnretained(pull).toOpaque()
        let bytesPerFrame = 2 * channels
        let framesPerCall: UInt32 = 8192

        var pcm = Data()
        var scratch = [UInt8](repeating: 0, count: Int(framesPerCall) * bytesPerFrame)

        while true {
            var ioPackets = framesPerCall
            let produced: Int = try scratch.withUnsafeMutableBytes { raw in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                          mDataByteSize: UInt32(raw.count),
                                          mData: raw.baseAddress))
                let st = AudioConverterFillComplexBuffer(
                    converter, Self.inputProc, ctxPtr, &ioPackets, &abl, nil)
                guard st == noErr || st == kAudioConverterErr_UnspecifiedError else {
                    throw AudioDecodeError.converter(st)
                }
                return Int(ioPackets) * bytesPerFrame
            }
            if produced == 0 { break }
            pcm.append(contentsOf: scratch[0..<produced])
        }
        return PCM(data: pcm, sampleRate: sampleRate, channels: channels)
    }
}

public extension AudioDecodeSession.PCM {
    /// Wrap the decoded interleaved Int16 PCM as one CMSampleBuffer for an AAC-encoding writer input.
    func makeSampleBuffer(ptsNanos: Int64) throws -> CMSampleBuffer {
        let ch = max(1, channels)
        let bytesPerFrame = 2 * ch
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame), mChannelsPerFrame: UInt32(ch),
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        var st = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard st == noErr, let fmt = format else { throw FormatDescriptionError.vt(st) }

        let len = data.count
        let mem = malloc(len)!
        data.copyBytes(to: mem.assumingMemoryBound(to: UInt8.self), count: len)
        var block: CMBlockBuffer?
        st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: mem, blockLength: len,
            blockAllocator: kCFAllocatorMalloc, customBlockSource: nil,
            offsetToData: 0, dataLength: len, flags: 0, blockBufferOut: &block)
        guard st == noErr, let bb = block else { free(mem); throw FormatDescriptionError.vt(st) }

        let pts = CMTime(value: ptsNanos, timescale: 1_000_000_000)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(max(1, sampleRate))),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = bytesPerFrame
        var sample: CMSampleBuffer?
        st = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fmt,
            sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        guard st == noErr, let s = sample else { throw FormatDescriptionError.vt(st) }
        return s
    }
}
