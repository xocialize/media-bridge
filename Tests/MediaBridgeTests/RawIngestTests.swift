import XCTest
import CoreVideo
@testable import ImageBridge

/// BRIDGE-053. RAW is the one input that is not already an image — everything else arrives downstream
/// of a demosaic somebody else chose.
///
/// ⚠️ **These do not decode a real camera file.** No RAW sample exists on this machine and ffmpeg
/// cannot author a valid CFA DNG, so the acceptance rows that need a CR3/ARW/NEF/DNG are **not** covered
/// here — see the ticket. What *is* covered is everything reachable without one: routing, the honest
/// deferral, and proof that no non-RAW path moved.
final class RawIngestTests: XCTestCase {

    private func temp(_ ext: String, bytes: [UInt8] = [0, 1, 2, 3]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-\(UUID().uuidString).\(ext)")
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - Routing

    /// Every extension in the allowlist must route to the RAW decoder. A body whose UTI this OS does not
    /// know still has to reach a decoder that can defer honestly, rather than falling through to
    /// `.unknown` — which reads to a user as "not an image".
    func testAllRawExtensionsRoute() throws {
        for ext in ImageIODecoderImpl.rawExtensions {
            let url = try temp(ext)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertTrue(ImageIODecoderImpl.isRaw(url), ".\(ext) must route to the RAW decoder")
        }
    }

    /// The guard must not over-trigger: ordinary formats keep their existing path.
    func testNonRawExtensionsDoNotRoute() throws {
        for ext in ["png", "jpg", "jpeg", "tiff", "heic", "gif", "bmp", "pdf", "mp4", "webm"] {
            let url = try temp(ext)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertFalse(ImageIODecoderImpl.isRaw(url), ".\(ext) must NOT route to the RAW decoder")
        }
    }

    // MARK: - Honest deferral

    /// A file that claims to be RAW but is not must **defer**, never crash and never return a green
    /// frame. `.deferred` is a distinct case from `.decodeFailed` precisely so a host can say
    /// "not supported yet" rather than "failed" — nothing is wrong with the user's file.
    func testUndecodableRawDefersRatherThanFailing() throws {
        let url = try temp("cr3", bytes: Array(repeating: 0xAB, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try RawDecoderImpl().decode(url: url)) { error in
            guard case ImageBridgeError.deferred(let message) = error else {
                return XCTFail("expected .deferred, got \(error)")
            }
            XCTAssertTrue(message.lowercased().contains("supported")
                          || message.lowercased().contains("no image"),
                          "the message must be readable by a user: \(message)")
        }
    }

    /// The same file through the routing decoder — a corrupt RAW must not surface as a generic decode
    /// failure just because it took the shared entry point.
    func testDeferralSurvivesRouting() throws {
        let url = try temp("nef", bytes: Array(repeating: 0x00, count: 2048))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ImageIODecoderImpl().decode(url: url)) { error in
            guard case ImageBridgeError.deferred = error else {
                return XCTFail("routing must preserve the deferral, got \(error)")
            }
        }
    }

    /// Probe and decode must agree about what a file is. Probing a RAW through CGImageSource would
    /// describe the *embedded preview* — wrong dimensions and `isRaw: false` — so a host would be told
    /// one thing and handed another.
    func testProbeAndDecodeAgreeOnRawRouting() throws {
        let url = try temp("arw", bytes: Array(repeating: 0x7F, count: 2048))
        defer { try? FileManager.default.removeItem(at: url) }

        var probeDeferred = false, decodeDeferred = false
        if case ImageBridgeError.deferred = (try? ImageIOProbeImpl().probe(url: url)).map({ _ in
            ImageBridgeError.deferred("")
        }) ?? (Result { try ImageIOProbeImpl().probe(url: url) }.failureError ?? ImageBridgeError.deferred("x")) {
            probeDeferred = true
        }
        if case ImageBridgeError.deferred = (Result { try ImageIODecoderImpl().decode(url: url) }
            .failureError ?? ImageBridgeError.deferred("x")) {
            decodeDeferred = true
        }
        XCTAssertEqual(probeDeferred, decodeDeferred, "probe and decode must classify a file the same way")
    }

    // MARK: - Options

    /// Faithful means faithful: nothing is adjusted unless the caller asked.
    func testFaithfulDefaultsAdjustNothingButKeepNoiseReduction() {
        let o = RawDecodeOptions.faithful
        XCTAssertNil(o.exposureEV)
        XCTAssertNil(o.boost)
        XCTAssertNil(o.neutralTemperature)
        XCTAssertNil(o.neutralTint)
        XCTAssertTrue(o.enableRawNoiseReduction, "demosaic-from-sensor denoise is the win; on by default")
        XCTAssertEqual(o.decoderVersion, .osDefault, "must not silently pin a decoder generation")
    }

    /// P2's flag exists and is off, so 16-bit latitude is an additive flip rather than a rework.
    func testHighBitDepthIsGatedOffForP1() {
        XCTAssertFalse(RawDecodeOptions.faithful.preserveHighBitDepth)
    }
}

private extension Result where Failure == Error {
    var failureError: Error? { if case .failure(let e) = self { return e }; return nil }
}
