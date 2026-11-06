import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MediaMeasure

/// The floor search ships the bytes it scored. `Result.data` is the very probe the search measured at
/// `Result.quality` — not a re-encode of that knob, which costs one encode per item and, on an encoder
/// that is not deterministic, ships bytes nobody scored (AB-T-0463).
///
/// The encoder here stamps every call with a serial number in a JPEG comment segment, so no two calls
/// ever return the same bytes: equality with one recorded probe proves which call the bytes came from.
final class ScoredBytesTests: XCTestCase {

    private final class Probes: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(knob: Double, data: Data)] = []
        func add(_ knob: Double, _ data: Data) { lock.lock(); _calls.append((knob, data)); lock.unlock() }
        var calls: [(knob: Double, data: Data)] { lock.lock(); defer { lock.unlock() }; return _calls }
    }

    /// A JPEG with a COM segment carrying `serial`, inserted right after SOI. Decoders skip COM.
    private static func stamped(_ jpeg: Data, serial: Int) -> Data {
        let payload = Array("probe \(serial)".utf8)
        let length = payload.count + 2
        var out = Data(jpeg.prefix(2))                                   // FF D8
        out.append(contentsOf: [0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)] + payload)
        out.append(jpeg.dropFirst(2))
        return out
    }

    /// A step encoder: below `threshold` the knob renders a ruined JPEG, at or above it a near-perfect
    /// one, so the score is a step and the search's trajectory is known in advance.
    private func stepEncoder(threshold: Double, probes: Probes) -> (CGImage, Double) throws -> Data {
        { image, knob in
            let jpeg = try ImageQualityTarget.encode(image, quality: knob >= threshold ? 1.0 : 0.02,
                                                     type: .jpeg)
            let data = Self.stamped(jpeg, serial: probes.calls.count)
            probes.add(knob, data)
            return data
        }
    }

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

    /// Threshold 0.5 over [0.1, 1]: the ceiling passes, then 0.55 ✓ 0.325 ✗ 0.4375 ✗ 0.49375 ✗
    /// 0.521875 ✓ 0.5078 ✓ 0.5008 ✓ 0.4973 ✗ — the LAST probe is a rejected one, which is exactly the
    /// case "keep the last evaluated bytes" gets wrong.
    func testTheReturnedBytesAreTheProbeTheSearchScored() throws {
        let image = makePhotoImage(128)
        let probes = Probes()
        let result = try ImageQualityTarget.encode(image, targetScore: 70, codec: "test", backend: .cpu,
                                                   encoder: stepEncoder(threshold: 0.5, probes: probes))
        let calls = probes.calls
        XCTAssertTrue(result.metTarget)
        XCTAssertEqual(calls.count, 9, "ceiling + 8 bisections, and no final encode")
        XCTAssertLessThan(try XCTUnwrap(calls.last).knob, 0.5, "the last probe was rejected")
        XCTAssertNotEqual(calls.last?.knob, result.quality)
        let chosen = calls.filter { $0.knob == result.quality }
        XCTAssertEqual(chosen.count, 1)
        XCTAssertEqual(result.data, chosen.first?.data, "the shipped bytes are the scored probe's own")
        // …and the returned score describes them: re-score the shipped bytes.
        let decoded = try ImageQualityTarget.decode(result.data)
        XCTAssertEqual(try SSIMULACRA2.score(reference: image, distorted: decoded), result.score)
    }

    /// The other exit: the ceiling misses, the search stops there, and the ceiling's bytes ship.
    func testAnUnreachableFloorShipsTheCeilingProbe() throws {
        let image = makePhotoImage(128)
        let probes = Probes()
        let result = try ImageQualityTarget.encode(image, targetScore: 101, codec: "test", backend: .cpu,
                                                   encoder: stepEncoder(threshold: 0.5, probes: probes))
        XCTAssertFalse(result.metTarget)
        XCTAssertEqual(result.quality, 1.0)
        XCTAssertEqual(probes.calls.count, 1, "one probe, no final encode")
        XCTAssertEqual(result.data, probes.calls.first?.data)
    }

    /// The built-in formats run the same path: HEIC and JPEG return a probe's bytes, so a search
    /// encodes ceiling + bisections and nothing after.
    func testBuiltInFormatsShipTheirProbe() throws {
        let image = makePhotoImage(128)
        let jpeg = try ImageQualityTarget.encodeJPEG(image, targetScore: 80, backend: .cpu)
        XCTAssertEqual(jpeg.data, try ImageQualityTarget.encode(image, quality: jpeg.quality, type: .jpeg),
                       "ImageIO JPEG is deterministic, so the probe equals a fresh encode")
        let heic = try ImageQualityTarget.encodeHEIC(image, targetScore: 80, backend: .cpu)
        let decoded = try ImageQualityTarget.decode(heic.data)
        XCTAssertEqual(try SSIMULACRA2.score(reference: image, distorted: decoded), heic.score,
                       "the returned score describes the returned HEIC bytes")
    }

    // MARK: - The fallback

    /// When no kept probe sits at the returned knob, the knob is encoded — never a neighbour's bytes.
    func testAMismatchedProbeFallsBackToEncoding() throws {
        let search = QualityTargetSearch.Result(quality: 0.5, score: 81, metTarget: true)
        let other = ImageQualityTarget.ScoredProbe(quality: 0.55, data: Data([1, 2, 3]))
        var encoded: [Double] = []
        let data = ImageQualityTarget.shippedBytes(other, for: search) { q in
            encoded.append(q); return Data([9])
        }
        XCTAssertEqual(encoded, [0.5], "one encode, at exactly the returned knob")
        XCTAssertEqual(data, Data([9]))

        encoded.removeAll()
        let none = ImageQualityTarget.shippedBytes(nil, for: search) { q in
            encoded.append(q); return Data([7])
        }
        XCTAssertEqual(encoded, [0.5])
        XCTAssertEqual(none, Data([7]))
    }

    func testAMatchingProbeIsShippedWithoutEncoding() {
        let search = QualityTargetSearch.Result(quality: 0.5, score: 81, metTarget: true)
        let kept = ImageQualityTarget.ScoredProbe(quality: 0.5, data: Data([4, 5]))
        var calls = 0
        let data = ImageQualityTarget.shippedBytes(kept, for: search) { _ in calls += 1; return Data() }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(data, Data([4, 5]))
    }
}
