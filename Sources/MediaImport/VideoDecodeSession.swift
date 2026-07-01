//
// VideoDecodeSession.swift — MediaImport
//
// VTDecompressionSession wrapper: feeds AVCC length-prefixed packets (as CMSampleBuffers) through
// VideoToolbox and collects decoded BGRA CVPixelBuffers. The demuxer's nanosecond PTS becomes a
// CMTime here (this is the boundary where matroska-swift's CoreMedia-free packets meet Apple's
// media stack). Output is sorted by PTS, since B-frame reorder means decode order ≠ display order.
//

import CoreMedia
import Foundation
import VideoToolbox

public struct DecodedVideoFrame: Sendable {
    public let image: CVPixelBuffer
    public let ptsNanos: Int64

    // Public so an out-of-package `ExternalVideoDecoder` (e.g. vpx-swift) can build frames to hand back
    // through the deferred-codec seam — the synthesized memberwise init is only internal.
    public init(image: CVPixelBuffer, ptsNanos: Int64) {
        self.image = image
        self.ptsNanos = ptsNanos
    }
}

public final class VideoDecodeSession {

    public enum DecodeError: Error { case sessionCreate(OSStatus), sampleBuffer(OSStatus), decode(OSStatus) }

    private let session: VTDecompressionSession
    private let formatDescription: CMFormatDescription

    /// Create a session that emits BGRA pixel buffers for the given video format description.
    public init(formatDescription: CMFormatDescription) throws {
        self.formatDescription = formatDescription
        let imageAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]() as CFDictionary,
        ]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: imageAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &s)
        guard status == noErr, let session = s else { throw DecodeError.sessionCreate(status) }
        self.session = session
    }

    deinit { VTDecompressionSessionInvalidate(session) }

    /// Thread-safe sink for the (possibly async, possibly out-of-order) decode callbacks.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [DecodedVideoFrame] = []
        func append(_ f: DecodedVideoFrame) { lock.lock(); frames.append(f); lock.unlock() }
        func sortedByPTS() -> [DecodedVideoFrame] {
            lock.lock(); defer { lock.unlock() }
            return frames.sorted { $0.ptsNanos < $1.ptsNanos }
        }
        /// Remove and return the lowest-PTS frame only once the buffer exceeds the reorder window —
        /// by then no not-yet-emitted frame can have an earlier PTS, so the min is final.
        func popMinIfOver(_ window: Int) -> DecodedVideoFrame? {
            lock.lock(); defer { lock.unlock() }
            guard frames.count > window else { return nil }
            var mi = 0
            for i in 1..<frames.count where frames[i].ptsNanos < frames[mi].ptsNanos { mi = i }
            return frames.remove(at: mi)
        }
        func drainSortedByPTS() -> [DecodedVideoFrame] {
            lock.lock(); defer { lock.unlock() }
            let out = frames.sorted { $0.ptsNanos < $1.ptsNanos }
            frames.removeAll()
            return out
        }
    }

    /// Decode AVCC packets (`(data, ptsNanos)`) → BGRA frames, sorted by PTS.
    public func decode(_ packets: [(data: Data, ptsNanos: Int64)]) throws -> [DecodedVideoFrame] {
        let sink = Sink()
        for pkt in packets {
            let sample = try makeSampleBuffer(avcc: pkt.data, ptsNanos: pkt.ptsNanos)
            var infoOut = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression], infoFlagsOut: &infoOut
            ) { status, _, imageBuffer, pts, _ in
                guard status == noErr, let img = imageBuffer else { return }
                let ns = pts.isValid ? Int64((pts.seconds * 1_000_000_000).rounded()) : pkt.ptsNanos
                sink.append(DecodedVideoFrame(image: img, ptsNanos: ns))
            }
            guard status == noErr else { throw DecodeError.decode(status) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return sink.sortedByPTS()
    }

    /// Streaming decode: emits each frame in PTS order via `onFrame` while keeping only a bounded
    /// reorder window (`reorderWindow` ≥ the codec's max reorder depth) of pixel buffers live, so
    /// memory stays bounded regardless of clip length. `onFrame` is awaited (back-pressure from the
    /// encoder), and the held frames drain as it consumes them.
    public func decodeStreaming(_ packets: [(data: Data, ptsNanos: Int64)],
                                reorderWindow: Int = 32,
                                onFrame: (DecodedVideoFrame) async throws -> Void) async throws {
        let sink = Sink()
        for pkt in packets {
            let sample = try makeSampleBuffer(avcc: pkt.data, ptsNanos: pkt.ptsNanos)
            var infoOut = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression], infoFlagsOut: &infoOut
            ) { status, _, imageBuffer, pts, _ in
                guard status == noErr, let img = imageBuffer else { return }
                let ns = pts.isValid ? Int64((pts.seconds * 1_000_000_000).rounded()) : pkt.ptsNanos
                sink.append(DecodedVideoFrame(image: img, ptsNanos: ns))
            }
            guard status == noErr else { throw DecodeError.decode(status) }
            while let frame = sink.popMinIfOver(reorderWindow) { try await onFrame(frame) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        for frame in sink.drainSortedByPTS() { try await onFrame(frame) }
    }

    // MARK: - CMSampleBuffer construction

    private func makeSampleBuffer(avcc data: Data, ptsNanos: Int64) throws -> CMSampleBuffer {
        let len = data.count
        // malloc so CMBlockBuffer can free it with kCFAllocatorMalloc.
        let mem = malloc(len)!
        data.copyBytes(to: mem.assumingMemoryBound(to: UInt8.self), count: len)

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: mem, blockLength: len,
            blockAllocator: kCFAllocatorMalloc, customBlockSource: nil,
            offsetToData: 0, dataLength: len, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let bb = blockBuffer else {
            free(mem); throw DecodeError.sampleBuffer(status)
        }

        let pts = CMTime(value: ptsNanos, timescale: 1_000_000_000)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sizeArr = len
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr, sampleBufferOut: &sample)
        guard status == noErr, let s = sample else { throw DecodeError.sampleBuffer(status) }
        return s
    }
}
