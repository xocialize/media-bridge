import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MediaBridge

/// MediaIntegrity — every corruption fixture here is *manufactured deterministically* (truncation at
/// a computed offset, a single flipped byte, a handcrafted EBML stream), so a verdict is a fact the
/// suite controls, never a decoder's mood. The classes covered are the ones production actually
/// produces: interrupted copies (truncation), unfinalized recordings (no moov), payload bit-rot
/// (PNG CRC), and the honest "unverified" for bytes that are not a media format at all.
final class IntegrityTests: XCTestCase {

    // MARK: - ISOBMFF

    func testIntactMP4IsIntact() async throws {
        let clip = try makeClip(frames: 12)
        defer { try? FileManager.default.removeItem(at: clip) }
        let r = await MediaIntegrity.verify(url: clip)
        XCTAssertEqual(r.verdict, .intact, "\(r.checks)")
        XCTAssertTrue(r.checks.contains { $0.name == "box-chain" && $0.outcome == .passed })
    }

    func testTruncatedMP4IsCorrupt() async throws {
        let clip = try makeClip(frames: 12)
        let cut = tmpURL("trunc", "mp4")
        defer { [clip, cut].forEach { try? FileManager.default.removeItem(at: $0) } }
        let data = try Data(contentsOf: clip)
        try data.prefix(data.count * 2 / 3).write(to: cut)

        let r = await MediaIntegrity.verify(url: cut)
        XCTAssertEqual(r.verdict, .corrupt)
        XCTAssertTrue(r.detail?.contains("truncated") == true
                   || r.detail?.contains("not a box") == true, "\(String(describing: r.detail))")
    }

    /// The unfinalized-recording case: media data present, `moov` never written. Manufactured by
    /// cutting the file exactly at the moov box header, so the remaining chain is byte-clean.
    func testMP4WithoutMoovIsCorrupt() async throws {
        let clip = try makeClip(frames: 12)
        let cut = tmpURL("nomoov", "mp4")
        defer { [clip, cut].forEach { try? FileManager.default.removeItem(at: $0) } }
        let data = try Data(contentsOf: clip)
        guard let range = data.range(of: Data("moov".utf8)) else {
            throw XCTSkip("fixture layout has no plain moov marker")
        }
        // Box header = 4-byte size immediately before the type.
        try data.prefix(range.lowerBound - 4).write(to: cut)

        let r = await MediaIntegrity.verify(url: cut)
        XCTAssertEqual(r.verdict, .corrupt)
        XCTAssertTrue(r.checks.contains { $0.name == "moov-present" && $0.outcome == .failed },
                      "\(r.checks)")
    }

    // MARK: - PNG

    func testIntactPNGIsIntact() async throws {
        let png = try makePNG()
        defer { try? FileManager.default.removeItem(at: png) }
        let r = await MediaIntegrity.verify(url: png)
        XCTAssertEqual(r.verdict, .intact, "\(r.checks)")
        XCTAssertTrue(r.checks.contains { $0.name == "png-chunks" && $0.outcome == .passed })
    }

    /// One flipped byte inside IDAT payload — invisible to a header probe, deterministic here
    /// because PNG chunks carry CRC32s.
    func testBitFlippedPNGIsCorrupt() async throws {
        let png = try makePNG()
        let bad = tmpURL("bitflip", "png")
        defer { [png, bad].forEach { try? FileManager.default.removeItem(at: $0) } }
        var data = try Data(contentsOf: png)
        guard let idat = data.range(of: Data("IDAT".utf8)) else { throw XCTSkip("no IDAT marker") }
        let target = idat.upperBound + 8            // safely inside the compressed payload
        data[target] ^= 0xFF
        try data.write(to: bad)

        let r = await MediaIntegrity.verify(url: bad)
        XCTAssertEqual(r.verdict, .corrupt)
        XCTAssertTrue(r.detail?.contains("CRC mismatch") == true, "\(String(describing: r.detail))")
    }

    func testTruncatedPNGIsCorrupt() async throws {
        let png = try makePNG()
        let cut = tmpURL("pngcut", "png")
        defer { [png, cut].forEach { try? FileManager.default.removeItem(at: $0) } }
        let data = try Data(contentsOf: png)
        try data.prefix(data.count * 3 / 5).write(to: cut)

        let r = await MediaIntegrity.verify(url: cut)
        XCTAssertEqual(r.verdict, .corrupt)
    }

    // MARK: - JPEG

    func testTruncatedJPEGIsCorrupt() async throws {
        let jpg = try makeJPEG()
        let cut = tmpURL("jpgcut", "jpg")
        defer { [jpg, cut].forEach { try? FileManager.default.removeItem(at: $0) } }
        let data = try Data(contentsOf: jpg)
        try data.prefix(data.count * 7 / 10).write(to: cut)

        let r = await MediaIntegrity.verify(url: cut)
        XCTAssertEqual(r.verdict, .corrupt)
        XCTAssertTrue(r.detail?.contains("EOI") == true, "\(String(describing: r.detail))")

        let intact = await MediaIntegrity.verify(url: jpg)
        XCTAssertEqual(intact.verdict, .intact)
    }

    // MARK: - EBML (handcrafted — matroska-swift has no muxer)

    /// Minimal valid stream: EBML header (4 B payload) + known-size Segment holding one empty
    /// Info element. Dropping the final bytes must flip intact → corrupt.
    func testHandcraftedEBMLWalks() async throws {
        var bytes: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x84, 0x00, 0x00, 0x00, 0x00]   // EBML header
        bytes += [0x18, 0x53, 0x80, 0x67, 0x85]                                        // Segment, 5 B
        bytes += [0x15, 0x49, 0xA9, 0x66, 0x80]                                        // Info, 0 B
        let good = tmpURL("ebml", "mkv"), bad = tmpURL("ebmlcut", "mkv")
        defer { [good, bad].forEach { try? FileManager.default.removeItem(at: $0) } }
        try Data(bytes).write(to: good)
        try Data(bytes.dropLast(2)).write(to: bad)

        let g = await MediaIntegrity.verify(url: good)
        XCTAssertEqual(g.verdict, .intact, "\(g.checks)")
        let b = await MediaIntegrity.verify(url: bad)
        XCTAssertEqual(b.verdict, .corrupt, "\(b.checks)")
    }

    // MARK: - Deep tier

    func testDeepDecodeIntactClipPassesWithSampleCount() async throws {
        let clip = try makeClip(frames: 12)
        defer { try? FileManager.default.removeItem(at: clip) }
        let r = await MediaIntegrity.verify(url: clip, level: .deep)
        XCTAssertEqual(r.verdict, .intact, "\(r.checks)")
        let decode = try XCTUnwrap(r.checks.first { $0.name == "decode" })
        XCTAssertEqual(decode.outcome, .passed)
        XCTAssertTrue(decode.detail?.contains("12 samples") == true,
                      "must report the decoded sample count: \(String(describing: decode.detail))")
    }

    func testDeepImageDecodePasses() async throws {
        let png = try makePNG()
        defer { try? FileManager.default.removeItem(at: png) }
        let r = await MediaIntegrity.verify(url: png, level: .deep)
        XCTAssertEqual(r.verdict, .intact)
        XCTAssertTrue(r.checks.contains { $0.name == "decode" && $0.outcome == .passed })
    }

    /// Deep ⊇ structural: the CRC walk stays the backstop even when ImageIO tolerates the damage.
    func testDeepStillReportsStructuralCorruption() async throws {
        let png = try makePNG()
        let bad = tmpURL("deepflip", "png")
        defer { [png, bad].forEach { try? FileManager.default.removeItem(at: $0) } }
        var data = try Data(contentsOf: png)
        guard let idat = data.range(of: Data("IDAT".utf8)) else { throw XCTSkip("no IDAT marker") }
        data[idat.upperBound + 8] ^= 0xFF
        try data.write(to: bad)

        let r = await MediaIntegrity.verify(url: bad, level: .deep)
        XCTAssertEqual(r.verdict, .corrupt)
    }

    // MARK: - Non-media / unreadable

    func testRandomBytesAreUnverified() async throws {
        let junk = tmpURL("junk", "bin")
        defer { try? FileManager.default.removeItem(at: junk) }
        try Data((0..<1024).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }).write(to: junk)
        let r = await MediaIntegrity.verify(url: junk)
        XCTAssertEqual(r.verdict, .unverified)
    }

    func testMissingFileIsUnverified() async {
        let r = await MediaIntegrity.verify(url: tmpURL("missing", "mp4"))
        XCTAssertEqual(r.verdict, .unverified)
    }

    /// The sniff ignores the extension — a JPEG named .png walks as a JPEG.
    func testMislabeledExtensionIsSniffedByMagic() async throws {
        let jpg = try makeJPEG()
        let lied = tmpURL("mislabel", "png")
        defer { [jpg, lied].forEach { try? FileManager.default.removeItem(at: $0) } }
        try FileManager.default.copyItem(at: jpg, to: lied)
        let r = await MediaIntegrity.verify(url: lied)
        XCTAssertEqual(r.verdict, .intact)
        XCTAssertTrue(r.checks.contains { $0.name == "jpeg-eoi" },
                      "magic must route to the JPEG walk despite the .png extension: \(r.checks)")
    }

    // MARK: - Fixtures

    private func tmpURL(_ stem: String, _ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("integrity-\(stem)-\(UUID().uuidString).\(ext)")
    }

    private func makeClip(frames: Int) throws -> URL {
        let url = tmpURL("clip", "mp4")
        let w = 160, h = 120, fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 800_000]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buf = pb else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buf)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h { for x in 0..<w {
                    let o = y * rowBytes + x * 4
                    p[o] = UInt8((x * 255 / w + i * 9) % 256)
                    p[o + 1] = UInt8(y * 255 / h)
                    p[o + 2] = UInt8((x + y) * 255 / (w + h))
                    p[o + 3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
        guard writer.status == .completed else {
            throw NSError(domain: "IntegrityTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "fixture writer failed"])
        }
        return url
    }

    private func makeImage(_ n: Int = 64) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n { for x in 0..<n {
            let noise = ((x * 131 + y * 57) % 64) - 32
            let i = (y * n + x) * 4
            bytes[i] = UInt8(clamping: x * 4 + noise)
            bytes[i + 1] = UInt8(clamping: y * 4 + noise)
            bytes[i + 2] = UInt8(clamping: 128 + noise)
            bytes[i + 3] = 255
        } }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    private func makePNG() throws -> URL {
        let url = tmpURL("img", "png")
        try write(makeImage(), to: url, type: UTType.png, quality: nil)
        return url
    }

    private func makeJPEG() throws -> URL {
        let url = tmpURL("img", "jpg")
        try write(makeImage(), to: url, type: UTType.jpeg, quality: 0.8)
        return url
    }

    private func write(_ image: CGImage, to url: URL, type: UTType, quality: Double?) throws {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "IntegrityTests", code: 2)
        }
        let props = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(dst, image, props)
        guard CGImageDestinationFinalize(dst) else { throw NSError(domain: "IntegrityTests", code: 3) }
    }
}
