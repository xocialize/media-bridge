//
// MediaMetricsTests.swift — MediaBridgeTests
//
// The harness must be trustworthy before its numbers are: spans record what they bracket, detail
// filtering filters, lane utilization merges overlaps (union, not double-count), and both export
// formats parse. No timing assertions — this suite runs in Debug where durations mean nothing.
//

import Foundation
import XCTest
@testable import MediaMetrics

final class MediaMetricsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MediaMetrics.enable(detail: 1)
    }

    override func tearDown() {
        MediaMetrics.disable()
        MediaMetrics.reset()
        super.tearDown()
    }

    func testSpansRecordAndAggregate() throws {
        MediaMetrics.time("t.alpha", lane: "cpu") { usleep(2000) }
        MediaMetrics.time("t.alpha", lane: "cpu") { usleep(2000) }
        MediaMetrics.time("t.beta", lane: "io") { usleep(1000) }

        let report = MediaMetrics.report()
        let alpha = report.spans.filter { $0.name == "t.alpha" }
        XCTAssertEqual(alpha.count, 2)
        XCTAssertTrue(alpha.allSatisfy { $0.durationSeconds > 0.001 })

        let agg = report.aggregated()
        let alphaStat = try XCTUnwrap(agg.first { $0.name == "t.alpha" })
        XCTAssertEqual(alphaStat.count, 2)
        XCTAssertEqual(alphaStat.lane, "cpu")
        XCTAssertGreaterThan(alphaStat.totalSeconds, 0.002)
    }

    func testDetailFiltering() {
        MediaMetrics.enable(detail: 0)
        MediaMetrics.time("t.stage", detail: 0) {}
        MediaMetrics.time("t.frame", detail: 1) {}
        MediaMetrics.time("t.kernel", detail: 2) {}
        let names = Set(MediaMetrics.report().spans.map(\.name))
        XCTAssertTrue(names.contains("t.stage"))
        XCTAssertFalse(names.contains("t.frame"))
        XCTAssertFalse(names.contains("t.kernel"))
    }

    func testDisabledRecordsNothingAndBodyStillRuns() {
        MediaMetrics.disable()
        MediaMetrics.reset()
        var ran = false
        MediaMetrics.time("t.off") { ran = true }
        XCTAssertTrue(ran)
        XCTAssertTrue(MediaMetrics.report().spans.isEmpty)
    }

    func testManualBracketAndExtraAttrs() {
        let h = MediaMetrics.begin("t.manual", lane: "encode", attrs: ["k": "v"])
        XCTAssertNotNil(h)
        MediaMetrics.end(h, extra: ["outcome": "ok"])
        let span = MediaMetrics.report().spans.first { $0.name == "t.manual" }
        XCTAssertEqual(span?.attrs["k"], "v")
        XCTAssertEqual(span?.attrs["outcome"], "ok")
        XCTAssertEqual(span?.lane, "encode")
    }

    func testErrorPropagatesAndSpanStillRecords() {
        struct Boom: Error {}
        XCTAssertThrowsError(try MediaMetrics.time("t.throws") { throw Boom() })
        XCTAssertEqual(MediaMetrics.report().spans.filter { $0.name == "t.throws" }.count, 1)
    }

    func testAsyncSpanCoversAwait() async {
        await MediaMetrics.time("t.async", lane: "score") {
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        let span = MediaMetrics.report().spans.first { $0.name == "t.async" }
        XCTAssertNotNil(span)
        XCTAssertGreaterThan(span?.durationSeconds ?? 0, 0.002)
    }

    func testIntervalMergeUnionsOverlaps() {
        // (0,10)+(5,15) overlap → 15; (20,25) separate → +5.
        let merged = MetricsReport.mergeIntervals([(0, 10), (5, 15), (20, 25)])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].0, 0); XCTAssertEqual(merged[0].1, 15)
        XCTAssertEqual(merged[1].0, 20); XCTAssertEqual(merged[1].1, 25)
    }

    func testExportsParse() throws {
        MediaMetrics.time("t.export", lane: "cpu", attrs: ["a": "1"]) { usleep(500) }
        let report = MediaMetrics.report()

        // NDJSON: every line is a JSON object; first is meta with a build stamp.
        let lines = String(data: report.ndjson(), encoding: .utf8)!
            .split(separator: "\n").map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        for line in lines {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertNotNil(obj?["t"])
        }
        XCTAssertTrue(lines[0].contains("\"buildConfiguration\""))

        // Chrome trace: parses, and carries thread_name metadata + at least one X event.
        let trace = try JSONSerialization.jsonObject(with: report.chromeTrace()) as? [String: Any]
        let events = try XCTUnwrap(trace?["traceEvents"] as? [[String: Any]])
        XCTAssertTrue(events.contains { $0["ph"] as? String == "M" })
        XCTAssertTrue(events.contains { $0["ph"] as? String == "X" && $0["name"] as? String == "t.export" })
    }

    /// The zero-overhead-when-off contract, enforced rather than asserted in a comment: `attrs` is
    /// an autoclosure, and the enablement/detail gate must short-circuit it. Pre-fix the closure
    /// was forced as an argument TO the gate, so every instrumentation point built its dictionary
    /// and formatted its strings even with `MEDIA_METRICS` unset — 18× per frame score on
    /// `ssimu2.channel` alone.
    func testAttrsAreNotBuiltWhenCollectionIsOff() {
        final class Counter { var n = 0 }
        let c = Counter()
        func attrs() -> [String: String] { c.n += 1; return ["k": "v"] }

        MediaMetrics.disable()
        MediaMetrics.reset()
        MediaMetrics.time("t.lazy", attrs: attrs()) {}
        _ = MediaMetrics.begin("t.lazy.manual", attrs: attrs())
        XCTAssertEqual(c.n, 0, "attrs must not be built while the collector is off")

        MediaMetrics.enable(detail: 1)
        MediaMetrics.time("t.lazy", attrs: attrs()) {}
        XCTAssertEqual(c.n, 1, "attrs must be built exactly once when the span is recorded")

        // Detail filtering rides the same gate — a span the level filters out is just as free.
        MediaMetrics.enable(detail: 0)
        MediaMetrics.time("t.lazy.deep", detail: 2, attrs: attrs()) {}
        XCTAssertEqual(c.n, 1, "a span filtered out by detail must not build its attrs either")
    }

    /// `reset()` moves the epoch. A span already open across it must still report the wall time it
    /// actually covered — pre-fix `end` measured against the NEW epoch while the handle was
    /// relative to the old one, silently truncating the duration (and clamping to 0 outright when
    /// the span was longer than the post-reset elapsed time). The Kit holds `kit.item` spans open
    /// for whole items, so this is reachable the moment `reset()` becomes callable from a host.
    func testDurationSurvivesAnEpochResetMidSpan() {
        MediaMetrics.enable(detail: 1)
        let h = MediaMetrics.begin("t.straddle", lane: "encode")
        XCTAssertNotNil(h)
        usleep(5000)
        MediaMetrics.reset()                 // epoch jumps forward under the open span
        usleep(1000)
        MediaMetrics.end(h)

        let span = MediaMetrics.report().spans.first { $0.name == "t.straddle" }
        XCTAssertNotNil(span)
        XCTAssertGreaterThan(span?.durationSeconds ?? 0, 0.004,
                             "a reset() between begin and end must not truncate the duration")
        XCTAssertEqual(span?.startNS, 0,
                       "a span that began before the current epoch clamps its start to 0")
    }

    func testEventIsZeroDuration() {
        MediaMetrics.event("t.mark", attrs: ["p10": "80.1"])
        let span = MediaMetrics.report().spans.first { $0.name == "t.mark" }
        XCTAssertEqual(span?.durationNS, 0)
        XCTAssertEqual(span?.attrs["p10"], "80.1")
    }
}
