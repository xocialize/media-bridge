//
// VideoQualityTargetCleanupTests.swift — MediaBridgeTests
//
// "No writer outlives the search." The speculative encode lane queues UNSTRUCTURED Tasks, so that
// invariant is not something the type system enforces — it holds only if every exit from
// `VideoQualityTarget.encode` brings the lane down and reaps its temps. These tests pin the exits
// the happy path never visits: a throw from delivery, a cancellation mid-search, and the lane's own
// revoke/cancel/drain semantics driven directly (the lane is file-scope precisely so they can be).
//

import AVFoundation
import XCTest
@testable import MediaMeasure

final class VideoQualityTargetCleanupTests: XCTestCase {

    // MARK: - EncodeLane, driven directly

    /// `revokeAll` is what every early loop exit relies on: bracket convergence, the
    /// slope-projection abort, and the descent break each leave the branch that *would* have been
    /// the next pass queued and unclaimable, and without this it encodes a whole clip that `drain`
    /// then waits for — the convergence break saving one pass and immediately spending one.
    func testRevokeAllStopsUnstartedJobsFromRunning() async {
        let lane = EncodeLane()
        let ran = Counter()
        let gate = Gate()

        // Job 1 parks on the gate, so everything behind it is queued-but-unstarted.
        let blocker = lane.submit(key: 1) { await gate.wait(); ran.hit(); return URL(fileURLWithPath: "/dev/null") }
        _ = lane.submit(key: 2) { ran.hit(); return URL(fileURLWithPath: "/dev/null") }
        _ = lane.submit(key: 3) { ran.hit(); return URL(fileURLWithPath: "/dev/null") }

        lane.revokeAll()
        gate.open()
        await lane.drain()
        _ = try? await blocker.value

        XCTAssertEqual(ran.count, 0, "a revoked job must self-skip, including the one already queued")
    }

    /// A re-submitted key must run again — the search legitimately revisits a bitrate, and
    /// `submit` clears the stale revocation for exactly that reason.
    func testResubmitAfterRevokeRunsAgain() async {
        let lane = EncodeLane()
        let ran = Counter()
        lane.revoke(7)
        _ = lane.submit(key: 7) { ran.hit(); return URL(fileURLWithPath: "/dev/null") }
        await lane.drain()
        XCTAssertEqual(ran.count, 1, "a fresh submit must clear its key's stale revocation")
    }

    /// `revokeAll` cannot reach a `key: nil` job — those are the plain serialized encodes, and they
    /// are structurally unrevocable. `cancelAll` is what covers them, which is why the throw path
    /// cancels rather than merely revoking.
    func testCancelAllReachesUnkeyedJobsThatRevokeCannot() async {
        let lane = EncodeLane()
        let ran = Counter()
        let gate = Gate()
        let blocker = lane.submit(key: nil) { await gate.wait(); return URL(fileURLWithPath: "/dev/null") }
        _ = lane.submit(key: nil) { ran.hit(); return URL(fileURLWithPath: "/dev/null") }

        lane.revokeAll()                    // no effect on un-keyed jobs, by construction
        lane.cancelAll()                    // this is the one that lands
        gate.open()
        await lane.drain()
        _ = try? await blocker.value

        XCTAssertEqual(ran.count, 0, "cancelAll must stop an unstarted un-keyed job")
    }

    /// `drain` must await the whole chain, not just the newest link — temp cleanup runs right
    /// after it and must never race a live writer.
    func testDrainAwaitsEveryQueuedJob() async {
        let lane = EncodeLane()
        let ran = Counter()
        for i in 0..<4 {
            _ = lane.submit(key: UInt64(100 + i)) {
                try? await Task.sleep(nanoseconds: 2_000_000)
                ran.hit()
                return URL(fileURLWithPath: "/dev/null")
            }
        }
        await lane.drain()
        XCTAssertEqual(ran.count, 4, "drain must await every queued job, not only the last")
    }

    // MARK: - The search's exits

    /// The leak the happy path hides: delivery throws AFTER the search has completed and drained,
    /// with every temp still on disk. Fully deterministic — no timing, no cancellation, no failure
    /// injection: the output's parent directory simply does not exist, so `copyItem` throws.
    /// `.webH264` is the right profile because `bestEffortOnFloorMiss` + `!requireSmaller` makes
    /// `didWin` unconditional, so the copy is always reached regardless of how the clip compresses.
    func testDeliveryFailureLeavesNoTemps() async throws {
        let src = tmpURL("vqtdeliver-src", "mov")
        defer { try? FileManager.default.removeItem(at: src) }
        try makeClip(at: src, w: 320, h: 240, frames: 30)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-dir-\(UUID().uuidString)")
            .appendingPathComponent("out.mp4")

        let before = vqtTemps()
        do {
            _ = try await VideoQualityTarget.encode(input: src, output: out, targetScore: 60,
                                                    iterations: 3, profile: .webH264)
            XCTFail("delivery into a nonexistent directory must throw")
        } catch {
            // expected — a Foundation copyItem error
        }
        XCTAssertEqual(vqtTemps().subtracting(before), [],
                       "a failed delivery must not orphan the search's temps")
    }

    /// Cancellation, end to end, with the lane forced on so the speculative branches are really
    /// queued. Exercises all three layers: the caller's cancel reaches the unstructured lane job
    /// (Layer 2), the job's pump stops on the flag (Layer 1), and the catch cancels the siblings
    /// and drains before the temp defer fires (Layer 3).
    func testCancelMidSearchThrowsAndLeavesNoTemps() async throws {
        setenv("MEDIABRIDGE_FORCE_SPECULATE", "1", 1)
        defer { unsetenv("MEDIABRIDGE_FORCE_SPECULATE") }

        let src = tmpURL("vqtcancel-src", "mov")
        let out = tmpURL("vqtcancel-out", "mp4")
        defer { [src, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try makeClip(at: src, w: 640, h: 480, frames: 150)

        let before = vqtTemps()
        let reachedPass2 = XCTestExpectation(description: "the search is underway")
        let task = Task {
            try await VideoQualityTarget.encode(
                input: src, output: out, targetScore: 70, iterations: 6,
                onProgress: { p in
                    if case .pass(_, let idx, _, _) = p.stage, idx >= 2 { reachedPass2.fulfill() }
                })
        }
        await fulfillment(of: [reachedPass2], timeout: 180)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled search must surface as a throw, not a completed result")
        } catch {
            // CancellationError, or a sourceAborted from the cancelled reader — either is a stop.
        }
        XCTAssertEqual(vqtTemps().subtracting(before), [],
                       "no vqt-* temp may outlive a cancelled search")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                       "a cancelled search must leave nothing at output")
    }

    // MARK: - Helpers

    /// Every temp the search creates is `vqt-*` in the system temp dir (`vqt-<uuid>`,
    /// `vqt-mezz-<uuid>`, `vqt-final-<uuid>`). Compare SETS, not counts — XCTest shares a process
    /// and a temp directory with every other suite.
    private func vqtTemps() -> Set<String> {
        let d = FileManager.default.temporaryDirectory
        let all = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        return Set(all.filter { $0.hasPrefix("vqt-") })
    }

    private func tmpURL(_ stem: String, _ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(stem)-\(UUID().uuidString).\(ext)")
    }

    /// Minimal synthetic H.264 clip — noisy frames so it does not compress to nothing and the
    /// search has real work to bisect over.
    private func makeClip(at url: URL, w: Int, h: Int, frames: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:
                                            kCVPixelFormatType_32BGRA])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var seed: UInt32 = 0x1234_5678
        func next() -> UInt8 { seed = seed &* 1_664_525 &+ 1_013_904_223; return UInt8((seed >> 16) & 0xff) }
        for f in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let row = CVPixelBufferGetBytesPerRow(pb)
                let p = base.bindMemory(to: UInt8.self, capacity: row * h)
                for y in 0..<h {
                    for x in 0..<w {
                        let i = y * row + x * 4
                        p[i] = next(); p[i + 1] = UInt8((x &+ f) & 0xff)
                        p[i + 2] = UInt8((y &+ f) & 0xff); p[i + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !input.isReadyForMoreMediaData { usleep(1000) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }
}

/// Lock-guarded call counter — the lane runs its jobs on arbitrary threads.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    func hit() { lock.lock(); n += 1; lock.unlock() }
}

/// Holds a lane job open so the jobs behind it are provably queued-but-unstarted when the test
/// revokes or cancels them.
private final class Gate: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    func open() { sem.signal() }
    func wait() async { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async { self.sem.wait(); c.resume() }
    } }
}
