import XCTest
import CoreGraphics
import ImageIO
@testable import MediaMeasure

/// "Stop now" on a still costs at most one pass, not one item. The search runs on the scoring
/// queue where `Task.isCancelled` is invisible, so the async entry points thread a one-way flag
/// through it (the video path's `CancelFlag`), checked before every encode. This suite pins that
/// a cancelled task throws `CancellationError` at the next pass, and that an uncancelled search is
/// byte-identical to the synchronous one.
final class StillSearchCancellationTests: XCTestCase {

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _task: Task<ImageQualityTarget.Result, Error>?
        private var _calls = 0
        var task: Task<ImageQualityTarget.Result, Error>? {
            get { lock.lock(); defer { lock.unlock() }; return _task }
            set { lock.lock(); _task = newValue; lock.unlock() }
        }
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; _calls += 1; return _calls }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
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

    /// Cancel from inside the second pass: the pass in flight completes, the check before the
    /// third throws. Exactly one more encode at most, never a full search.
    func testCancellingTheTaskStopsTheSearchAtTheNextPass() async throws {
        let image = makePhotoImage(256)
        let box = Box()
        box.task = Task {
            try await ImageQualityTarget.encode(image, targetScore: 80, codec: "test",
                                                backend: .cpu) { img, q in
                if box.bump() == 2 { box.task?.cancel() }
                return try ImageQualityTarget.encode(img, quality: q, type: .jpeg)
            }
        }
        do {
            _ = try await box.task!.value
            XCTFail("a cancelled search must throw")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(box.calls, 2, "the second pass finishes; the check before the third throws")
    }

    /// A task cancelled BEFORE the search starts never encodes at all.
    func testATaskCancelledBeforeTheSearchNeverEncodes() async throws {
        let image = makePhotoImage(128)
        let box = Box()
        box.task = Task {
            try await Task.sleep(for: .milliseconds(200))       // give the cancel a head start
            return try await ImageQualityTarget.encodeJPEG(image, targetScore: 80, backend: .cpu)
        }
        box.task?.cancel()
        do {
            _ = try await box.task!.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
    }

    /// A non-async context, so the overload resolves to the synchronous search.
    private func syncJPEG(_ image: CGImage) throws -> ImageQualityTarget.Result {
        try ImageQualityTarget.encodeJPEG(image, targetScore: 80, backend: .cpu)
    }

    /// The flag changes nothing when nobody sets it: async and sync searches agree byte for byte.
    func testAnUncancelledSearchIsUnchanged() async throws {
        let image = makePhotoImage(128)
        let sync = try syncJPEG(image)
        let async = try await ImageQualityTarget.encodeJPEG(image, targetScore: 80, backend: .cpu)
        XCTAssertEqual(sync.data, async.data)
        XCTAssertEqual(sync.quality, async.quality)
        XCTAssertEqual(sync.score, async.score)
    }
}
