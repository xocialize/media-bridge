import XCTest
import CoreVideo
@testable import ImageBridge

/// BRIDGE-053's acceptance rows that need a real camera file. Four vendors, four RAW containers, all
/// CC0 from raw.pixls.us.
///
/// Skips rather than fails when the corpus is absent, so the suite stays green on a machine without it —
/// but the skip message says exactly what is missing, because a silently-skipped acceptance test is
/// indistinguishable from a passing one.
final class RawDecodeRealFileTests: XCTestCase {

    private static let corpus = URL(fileURLWithPath: "/Volumes/Satechi/Models/_ForgeSmokeCorpus/raw")

    private func sample(_ name: String) throws -> URL {
        let url = Self.corpus.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("RAW corpus missing \(name) — see BRIDGE-053 (CC0 samples from raw.pixls.us)")
        }
        return url
    }

    /// One row per vendor: each must demosaic to a real buffer and be *reported* as RAW.
    func testEachVendorDecodesToAValidBuffer() throws {
        for (file, vendor) in [("canon-r5m2.CR3", "Canon CR3"), ("sony-rx0.ARW", "Sony ARW"),
                               ("nikon-1j1.NEF", "Nikon NEF"), ("ricoh-gr.DNG", "Ricoh DNG")] {
            let url = try sample(file)
            let (frames, meta) = try ImageIODecoderImpl().decode(url: url)

            XCTAssertEqual(frames.count, 1, "\(vendor): one frame")
            let buffer = try XCTUnwrap(frames.first)
            XCTAssertGreaterThan(CVPixelBufferGetWidth(buffer), 1000, "\(vendor): sensor-sized, not a thumbnail")
            XCTAssertGreaterThan(CVPixelBufferGetHeight(buffer), 1000, "\(vendor)")
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA, "\(vendor)")

            XCTAssertEqual(meta.format, .raw, "\(vendor)")
            XCTAssertTrue(meta.isRaw, "\(vendor): isRaw must be true")
            XCTAssertEqual(meta.bitDepth, 8, "\(vendor): P1 narrows to 8-bit at the buffer boundary")
            XCTAssertFalse(meta.isLinear, "\(vendor): P1 is display-referred")
            XCTAssertEqual(meta.width, CVPixelBufferGetWidth(buffer), "\(vendor): metadata must describe the buffer")
            XCTAssertEqual(meta.height, CVPixelBufferGetHeight(buffer), "\(vendor)")
        }
    }

    /// **The double-apply trap.** `CIRAWFilter` applies EXIF orientation itself, so a consumer that
    /// also applies it rotates twice.
    ///
    /// The source is a landscape DNG whose orientation tag is patched to 6 (rotate 90° CW). That makes
    /// the three outcomes distinguishable by shape alone: applied once → **portrait**; not applied →
    /// landscape; applied twice → 180°, which is landscape again. Only one of them is taller than wide.
    func testOrientationIsAppliedExactlyOnce() throws {
        let landscape = try sample("ricoh-gr.DNG")
        let rotated = try sample("ricoh-gr-portrait.DNG")

        let (_, base) = try ImageIODecoderImpl().decode(url: landscape)
        XCTAssertGreaterThan(base.width, base.height, "control: the unrotated source decodes landscape")

        let (_, meta) = try ImageIODecoderImpl().decode(url: rotated)
        XCTAssertGreaterThan(meta.height, meta.width,
                             "orientation=6 must decode PORTRAIT; landscape means it was skipped or applied twice")
        XCTAssertEqual(meta.width, base.height, "a 90° rotation swaps the axes exactly")
        XCTAssertEqual(meta.height, base.width)

        // And the metadata must not ask a consumer to rotate again.
        XCTAssertEqual(meta.exifOrientation, 1,
                       "pixels are already upright, so the reported orientation must be 1")
    }

    /// Probe must describe the same image decode produces — not the embedded preview JPEG, which is a
    /// different size and is not RAW.
    func testProbeDescribesTheSensorImageNotThePreview() throws {
        let url = try sample("canon-r5m2.CR3")
        let probed = try ImageIOProbeImpl().probe(url: url)
        let (_, decoded) = try ImageIODecoderImpl().decode(url: url)

        XCTAssertTrue(probed.isRaw)
        XCTAssertEqual(probed.width, decoded.width, "probe and decode must agree on dimensions")
        XCTAssertEqual(probed.height, decoded.height)
    }
}
