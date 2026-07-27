import XCTest
import CoreVideo
@testable import MediaBridge
@testable import MediaImport

/// The write-side mirror of `ExternalDecoderTests`.
///
/// The registry's whole promise is that asking for a format nothing can write **fails honestly rather
/// than silently producing something opaque** — the same doctrine that makes an undecodable codec surface
/// as `.deferred`. Until this suite existed that promise lived only in a doc comment, which is exactly
/// the shape of claim that quietly stops being true.
final class ExternalAlphaEncoderTests: XCTestCase {

    /// Claims one format and refuses the rest, so a test can tell "found the right encoder" from
    /// "found any encoder".
    private struct StubEncoder: ExternalAlphaVideoEncoder {
        let claims: TransparentVideoFormat
        let id: String
        func canWrite(_ format: TransparentVideoFormat) -> Bool { format == claims }
        func write(to output: URL, format: TransparentVideoFormat, width: Int, height: Int,
                   frameRate: Double,
                   nextFrame: () async throws -> (buffer: CVPixelBuffer, ptsNanos: Int64?)?) async throws -> Int { 0 }
    }

    override func setUp() { super.setUp(); MediaBridge.unregisterAllExternalAlphaEncoders() }
    override func tearDown() { MediaBridge.unregisterAllExternalAlphaEncoders(); super.tearDown() }

    /// With nothing registered, WebM must report unwritable — the honest answer. The two `.mov`
    /// formats must still report writable, because media-bridge writes those itself and their
    /// availability does not depend on any plug-in.
    func testWebMIsUnwritableUntilAnEncoderRegisters() {
        XCTAssertFalse(MediaBridge.canWriteTransparent(.webmVP9Alpha),
                       "no encoder registered — must not claim it can write WebM")
        XCTAssertTrue(MediaBridge.canWriteTransparent(.movHEVCAlpha))
        XCTAssertTrue(MediaBridge.canWriteTransparent(.movProRes4444))
        XCTAssertNil(MediaBridge.externalAlphaEncoder(for: .webmVP9Alpha))
    }

    func testRegisteringMakesWebMWritable() {
        MediaBridge.register(externalAlphaEncoder: StubEncoder(claims: .webmVP9Alpha, id: "a"))
        XCTAssertTrue(MediaBridge.canWriteTransparent(.webmVP9Alpha))
        XCTAssertNotNil(MediaBridge.externalAlphaEncoder(for: .webmVP9Alpha))
    }

    /// An encoder that claims a *different* format must not be handed WebM work. Guards the
    /// plausible-looking bug where lookup returns `.last` regardless of what it claims.
    func testLookupRespectsWhatTheEncoderClaims() {
        MediaBridge.register(externalAlphaEncoder: StubEncoder(claims: .movProRes4444, id: "prores"))
        XCTAssertNil(MediaBridge.externalAlphaEncoder(for: .webmVP9Alpha),
                     "an encoder claiming ProRes must not be selected for WebM")
        XCTAssertFalse(MediaBridge.canWriteTransparent(.webmVP9Alpha))
    }

    /// Documented as most-recently-registered-wins, matching the decode registry.
    func testMostRecentlyRegisteredWins() {
        MediaBridge.register(externalAlphaEncoder: StubEncoder(claims: .webmVP9Alpha, id: "first"))
        MediaBridge.register(externalAlphaEncoder: StubEncoder(claims: .webmVP9Alpha, id: "second"))
        let chosen = MediaBridge.externalAlphaEncoder(for: .webmVP9Alpha) as? StubEncoder
        XCTAssertEqual(chosen?.id, "second")
    }

    func testUnregisterRestoresTheHonestAnswer() {
        MediaBridge.register(externalAlphaEncoder: StubEncoder(claims: .webmVP9Alpha, id: "a"))
        XCTAssertTrue(MediaBridge.canWriteTransparent(.webmVP9Alpha))
        MediaBridge.unregisterAllExternalAlphaEncoders()
        XCTAssertFalse(MediaBridge.canWriteTransparent(.webmVP9Alpha),
                       "after teardown the registry must go back to admitting it cannot write WebM")
    }

    /// `isNative` is what decides whether a format needs a plug-in at all; if WebM were ever marked
    /// native the registry would be bypassed and the silent-opaque failure would return.
    func testOnlyWebMRequiresAnExternalEncoder() {
        XCTAssertFalse(TransparentVideoFormat.webmVP9Alpha.isNative)
        XCTAssertTrue(TransparentVideoFormat.movHEVCAlpha.isNative)
        XCTAssertTrue(TransparentVideoFormat.movProRes4444.isNative)
        XCTAssertEqual(TransparentVideoFormat.webmVP9Alpha.fileExtension, "webm")
        XCTAssertEqual(TransparentVideoFormat.movHEVCAlpha.fileExtension, "mov")
    }
}
