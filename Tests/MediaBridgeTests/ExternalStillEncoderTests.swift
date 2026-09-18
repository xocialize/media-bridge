import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MediaBridge
@testable import MediaImport
@testable import MediaMeasure

/// The stills twin of `ExternalAlphaEncoderTests`.
///
/// Two promises: the registry answers **honestly** (nothing registered → nothing claimed, so a caller
/// never relabels other bytes as WebP), and the generic floor search is the SAME search law the native
/// formats use — JPEG now runs through it, and this suite pins that the delegation changed nothing.
final class ExternalStillEncoderTests: XCTestCase {

    /// Claims WebP but emits ImageIO JPEG bytes — a pure-Swift stand-in, exactly as the decode-side
    /// tests used a fake VP9 decoder. Enough to prove plumbing; the real encoder's tests live in
    /// webp-swift, where libwebp is.
    private struct Stub: ExternalStillEncoder {
        struct Unsupported: Error {}
        let id: String
        var format: ExternalStillFormat { .webp }
        var supportsAlpha: Bool { false }
        var supportsLossless: Bool { false }
        func encode(_ image: CGImage, quality: Double) throws -> Data {
            try ImageQualityTarget.encode(image, quality: quality, type: .jpeg)
        }
        func encodeLossless(_ image: CGImage) throws -> Data { throw Unsupported() }
    }

    override func setUp() { super.setUp(); MediaBridge.unregisterAllExternalStillEncoders() }
    override func tearDown() { MediaBridge.unregisterAllExternalStillEncoders(); super.tearDown() }

    private func makePhotoImage(_ n: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        var seed: UInt32 = 0x9E3779B9
        func grain() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(Int32(truncatingIfNeeded: seed >> 8) % 13) - 6
        }
        for y in 0..<n { for x in 0..<n {
            let fx = Double(x) / Double(n), fy = Double(y) / Double(n)
            let l1 = 110 + 70 * sin(fx * 4.1 + 0.6) * cos(fy * 2.9 + 1.1)
            let l2 = 40 * sin((fx + fy) * 6.3)
            let i = (y * n + x) * 4
            bytes[i]     = UInt8(clamping: Int(l1 + l2 * 0.7 + grain()))
            bytes[i + 1] = UInt8(clamping: Int(l1 * 0.9 + l2 + grain()))
            bytes[i + 2] = UInt8(clamping: Int(l1 * 1.1 + l2 * 0.4 + grain()))
            bytes[i + 3] = 255
        } }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    // MARK: - Registry

    func testWebPIsUnencodableUntilSomethingRegisters() {
        XCTAssertFalse(MediaBridge.canEncodeStill(.webp), "nothing registered — must not claim WebP")
        XCTAssertNil(MediaBridge.externalStillEncoder(for: .webp))
    }

    func testRegisteringMakesWebPEncodable() {
        MediaBridge.register(externalStillEncoder: Stub(id: "a"))
        XCTAssertTrue(MediaBridge.canEncodeStill(.webp))
        XCTAssertNotNil(MediaBridge.externalStillEncoder(for: .webp))
    }

    /// Documented as most-recently-registered-wins, matching the other two registries.
    func testMostRecentlyRegisteredWins() {
        MediaBridge.register(externalStillEncoder: Stub(id: "first"))
        MediaBridge.register(externalStillEncoder: Stub(id: "second"))
        let chosen = MediaBridge.externalStillEncoder(for: .webp) as? Stub
        XCTAssertEqual(chosen?.id, "second")
    }

    func testUnregisterRestoresTheHonestAnswer() {
        MediaBridge.register(externalStillEncoder: Stub(id: "a"))
        XCTAssertTrue(MediaBridge.canEncodeStill(.webp))
        MediaBridge.unregisterAllExternalStillEncoders()
        XCTAssertFalse(MediaBridge.canEncodeStill(.webp),
                       "after teardown the registry must go back to admitting it cannot write WebP")
    }

    /// The vocabulary a caller builds file names, UTTypes and receipts from.
    func testFormatVocabulary() {
        XCTAssertEqual(ExternalStillFormat.webp.utType, .webP)
        XCTAssertEqual(ExternalStillFormat.webp.fileExtension, "webp")
        XCTAssertEqual(ExternalStillFormat.webp.mimeType, "image/webp")
        XCTAssertEqual(ExternalStillFormat.webp.utType.preferredMIMEType, "image/webp")
    }

    // MARK: - The generic search

    /// `encodeJPEG` delegates to the generic search; the two must agree byte for byte, so the
    /// delegation is provably a refactor and not a second search law.
    func testGenericSearchReproducesTheJPEGLane() throws {
        let image = makePhotoImage(128)
        let direct = try ImageQualityTarget.encodeJPEG(image, targetScore: 80, backend: .cpu)
        let generic = try ImageQualityTarget.encode(image, targetScore: 80, codec: "jpeg",
                                                    backend: .cpu) { img, q in
            try ImageQualityTarget.encode(img, quality: q, type: .jpeg)
        }
        XCTAssertEqual(direct.quality, generic.quality)
        XCTAssertEqual(direct.score, generic.score)
        XCTAssertEqual(direct.metTarget, generic.metTarget)
        XCTAssertEqual(direct.data, generic.data, "same law, same knob, same bytes")
    }

    /// A registered encoder is driven through the generic search exactly like a native format: the
    /// result is decodable by ImageIO, meets the floor (or says it did not), and its bytes are the
    /// final re-encode at the chosen knob.
    func testARegisteredEncoderRunsTheSameSearch() throws {
        MediaBridge.register(externalStillEncoder: Stub(id: "stub"))
        let encoder = try XCTUnwrap(MediaBridge.externalStillEncoder(for: .webp))
        let image = makePhotoImage(128)
        let result = try ImageQualityTarget.encode(image, targetScore: 80, codec: "webp",
                                                   backend: .cpu) { img, q in
            try encoder.encode(img, quality: q)
        }
        XCTAssertTrue(result.metTarget)
        XCTAssertGreaterThanOrEqual(result.score, 80)
        XCTAssertEqual(result.data, try encoder.encode(image, quality: result.quality))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), "ImageIO must decode it")
    }

    /// The lossless counterpart measures the round trip rather than asserting it — the PNG rule.
    func testGenericLosslessMeasuresTheRoundTrip() throws {
        let image = makePhotoImage(96)
        let png = try ImageQualityTarget.encodePNG(image, backend: .cpu)
        let generic = try ImageQualityTarget.encodeLossless(image, codec: "png", backend: .cpu) {
            try ImageQualityTarget.encodePNGData($0)
        }
        XCTAssertEqual(generic.data, png.data)
        XCTAssertEqual(generic.score, png.score)
        XCTAssertGreaterThan(generic.score, 99, "a lossless round trip of an 8-bit sRGB source")
    }
}
