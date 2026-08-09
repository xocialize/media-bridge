//
// GIFVideo.swift — MediaMeasure
//
// Animated-GIF → H.264 mezzanine: the ingest half of the consumer GIF→mp4 rung. The mezzanine is
// near-lossless and honors per-frame timing; the caller hands it to `VideoQualityTarget.encode`
// (`.webH264`) so the whole floor-search machinery — receipts included — is reused rather than
// rebuilt. Net-clean: ImageIO + AVFoundation only.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum GIFVideo {

    public enum GIFError: Error, CustomStringConvertible {
        case unreadable, notAnimated, writeFailed(String)
        public var description: String {
            switch self {
            case .unreadable: return "image source unreadable"
            case .notAnimated: return "not an animated image (single frame)"
            case .writeFailed(let why): return "mezzanine write failed: \(why)"
            }
        }
    }

    /// Frame count of the image source (1 for stills, 0 when unreadable). The router's cheap
    /// animation probe — no frame decode happens here.
    public static func frameCount(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(src)
    }

    /// The per-frame delay in seconds, honoring the browser convention: an unclamped delay is
    /// preferred; anything ≤ 10 ms renders as 100 ms (the value virtually every player substitutes,
    /// so honoring the literal 0 would play a "fast" GIF ~10× off from how anyone has ever seen it).
    static func delay(_ src: CGImageSource, _ index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double
        let d = unclamped ?? clamped ?? 0.1
        return d <= 0.010 ? 0.1 : d
    }

    /// Render an animated GIF as a near-lossless H.264 mezzanine honoring per-frame delays.
    ///
    /// - Transparency composites over WHITE (H.264 has no alpha; white is the web-background
    ///   convention a GIF was authored against).
    /// - Frames composite onto a RUNNING canvas: full frames and do-not-dispose deltas — the
    ///   dominant styles — render correctly. ImageIO exposes no per-frame disposal method, so a
    ///   restore-to-background delta GIF (rare) would smear; the floor search still gates against
    ///   this mezzanine, so the failure mode is a faithful encode of a wrong composite, never a
    ///   quality lie. Revisit only with a real corpus case in hand.
    /// - Odd GIF dimensions round DOWN to even (4:2:0 requires it); the sub-pixel crop beats
    ///   letting the writer resample.
    @discardableResult
    public static func renderMezzanine(input: URL, output: URL) async throws
        -> (frames: Int, duration: Double, width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw GIFError.unreadable
        }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { throw GIFError.notAnimated }
        guard let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw GIFError.unreadable
        }
        let w = first.width - (first.width % 2)
        let h = first.height - (first.height % 2)
        guard w > 0, h > 0 else { throw GIFError.unreadable }

        // Near-lossless mezzanine rate: generous bits-per-pixel at the clip's own frame pacing.
        var totalDuration = 0.0
        for i in 0..<count { totalDuration += delay(src, i) }
        let avgFPS = totalDuration > 0 ? Double(count) / totalDuration : 10
        let bitrate = min(60_000_000, max(8_000_000, Int(Double(w * h) * avgFPS * 0.3)))

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: VideoQualityTarget.colorProperties(from: nil,
                                                                          width: w, height: h),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 4,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            ])
        guard writer.canAdd(videoIn) else { throw GIFError.writeFailed("cannot add input") }
        writer.add(videoIn)
        guard writer.startWriting() else {
            throw GIFError.writeFailed(String(describing: writer.error))
        }
        writer.startSession(atSourceTime: .zero)

        // Running canvas, prefilled white: each frame draws over the previous composite.
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let canvas = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: cs,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw GIFError.writeFailed("canvas context")
        }
        canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: w, height: h))

        var pts = 0.0
        for i in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            canvas.draw(frame, in: CGRect(x: 0, y: 0,
                                          width: frame.width, height: frame.height))
            guard let composed = canvas.makeImage() else { continue }
            var pb: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            } else {
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            }
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb),
               let dst = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) {
                dst.draw(composed, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !videoIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(pb, withPresentationTime: CMTime(seconds: pts,
                                                            preferredTimescale: 600))
            pts += delay(src, i)
        }
        videoIn.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        if writer.status == .failed {
            throw GIFError.writeFailed(String(describing: writer.error))
        }
        return (count, pts, w, h)
    }
}
