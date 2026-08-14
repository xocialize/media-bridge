//
// MediaMetrics.swift — MediaMetrics
//
// The package's performance-measurement harness: named wall-clock spans on a shared timeline, so a
// run can answer "where did the time go" (aggregation by stage) AND "what ran concurrently with
// what" (span overlap — the question that decides pipelining work, which an aggregate alone cannot
// answer). Dependency-free by design: `MediaMeasure`, `MediaBridge`, `ImageBridge`, and downstream
// packages (ForgeOptimizerKit) all record into the ONE process-wide collector, so a Kit-level item
// span and the bridge-level GPU dispatch it triggered land on the same timeline.
//
// Relationship to the older knobs: `FORGE_PROFILE` (`MediaProfile`) stays — human-readable stderr
// lines, unchanged. `MEDIABRIDGE_VT_LOG` (`VTBreadcrumb`) stays — crash-durable fsync'd breadcrumbs.
// MediaMetrics is the third leg: STRUCTURED spans a tool can aggregate, diff, and render (Perfetto
// via Chrome-trace export; NDJSON for scripts). Collection is in-memory and explicitly drained by
// the caller — a library must not write files as a silent side effect (the VTBreadcrumb rule).
//
// Overhead: off (default) each instrumentation point costs one unfair-lock check (~tens of ns
// against stages measured in ms). On, a span append under the same lock. Spans are capped
// (`maxSpans`) so a runaway loop degrades to a counted drop, never unbounded memory.
//
// ⚠️ Timings are only meaningful from a RELEASE build — Debug inverts conclusions on this codebase
// (pure-Swift SSIMULACRA2 is 50–150× slower in Debug; BRIDGE-044). Every report is stamped with
// `buildConfiguration` so a consumer can refuse or flag Debug-born numbers (calibration rule H-2).
//

import Foundation
import os

// MARK: - Span record

/// One completed span on the process timeline. `startNS` is uptime-nanoseconds since the collector's
/// epoch (set at `enable`/`reset`), so subtraction across spans is exact and monotonic; the report's
/// meta carries the wall-clock epoch for humans.
public struct MetricSpan: Sendable, Codable {
    public let name: String
    /// Resource lane, for timeline grouping: "decode" / "encode" / "score" / "gpu" / "io" /
    /// "orchestrate" / "kit" by convention. Free-form — new lanes are cheap.
    public let lane: String
    public let startNS: UInt64
    public let durationNS: UInt64
    public let attrs: [String: String]
    /// Mach thread ID at begin — enough to see which spans *could not* have overlapped.
    public let thread: UInt64

    public var startSeconds: Double { Double(startNS) / 1e9 }
    public var durationSeconds: Double { Double(durationNS) / 1e9 }
}

/// Aggregated view of one span name.
public struct StageStat: Sendable {
    public let name: String
    public let lane: String
    public let count: Int
    public let totalSeconds: Double
    public let minSeconds: Double
    public let maxSeconds: Double
    public var meanSeconds: Double { count > 0 ? totalSeconds / Double(count) : 0 }
}

// MARK: - Handle

/// Token returned by `begin` — pass to `end`. `nil` when collection is off (both calls no-op), so
/// manual bracketing costs nothing disabled. Sendable: safe to end on a different task/thread than
/// began (spans record wall intervals, not thread residency).
public struct MetricSpanHandle: Sendable {
    let name: String
    let lane: String
    let attrs: [String: String]
    let startNS: UInt64
    let thread: UInt64
    let signpostID: UInt64
}

// MARK: - Report

/// A drained snapshot of the collector: the raw timeline plus derived views. Serialization is the
/// caller's act (CLI, bench tool, tests) — never the library's.
public struct MetricsReport: Sendable {
    public struct Meta: Sendable, Codable {
        public let epochWallClock: Date
        public let osVersion: String
        public let process: String
        public let pid: Int32
        /// "release" or "debug" — stamped so Debug-born numbers can be refused downstream (H-2).
        public let buildConfiguration: String
        public let detailLevel: Int
        public let droppedSpans: Int
    }

    public let meta: Meta
    public let spans: [MetricSpan]

    /// Group by span name: count / total / min / max, sorted by total descending.
    public func aggregated() -> [StageStat] {
        var acc: [String: (lane: String, count: Int, total: Double, minS: Double, maxS: Double)] = [:]
        for s in spans {
            let d = s.durationSeconds
            if var a = acc[s.name] {
                a.count += 1; a.total += d; a.minS = min(a.minS, d); a.maxS = max(a.maxS, d)
                acc[s.name] = a
            } else {
                acc[s.name] = (s.lane, 1, d, d, d)
            }
        }
        return acc.map { StageStat(name: $0.key, lane: $0.value.lane, count: $0.value.count,
                                   totalSeconds: $0.value.total, minSeconds: $0.value.minS,
                                   maxSeconds: $0.value.maxS) }
            .sorted { $0.totalSeconds > $1.totalSeconds }
    }

    /// Wall-clock span of the whole timeline (first begin → last end), in seconds.
    public var timelineSeconds: Double {
        guard let first = spans.min(by: { $0.startNS < $1.startNS }),
              let last = spans.max(by: { ($0.startNS + $0.durationNS) < ($1.startNS + $1.durationNS) })
        else { return 0 }
        return Double((last.startNS + last.durationNS) - first.startNS) / 1e9
    }

    /// Per-lane busy time and utilization vs the whole timeline — the pipelining headroom view.
    /// Overlapping spans within one lane are merged first (union, not sum), so a lane that
    /// double-brackets a region isn't counted twice.
    public func laneUtilization() -> [(lane: String, busySeconds: Double, utilization: Double)] {
        let wall = timelineSeconds
        guard wall > 0 else { return [] }
        var byLane: [String: [(UInt64, UInt64)]] = [:]
        for s in spans { byLane[s.lane, default: []].append((s.startNS, s.startNS + s.durationNS)) }
        return byLane.map { lane, iv in
            let merged = Self.mergeIntervals(iv)
            let busy = merged.reduce(UInt64(0)) { $0 + ($1.1 - $1.0) }
            let busyS = Double(busy) / 1e9
            return (lane, busyS, busyS / wall)
        }.sorted { $0.busySeconds > $1.busySeconds }
    }

    static func mergeIntervals(_ iv: [(UInt64, UInt64)]) -> [(UInt64, UInt64)] {
        guard !iv.isEmpty else { return [] }
        let sorted = iv.sorted { $0.0 < $1.0 }
        var out: [(UInt64, UInt64)] = [sorted[0]]
        for (s, e) in sorted.dropFirst() {
            if s <= out[out.count - 1].1 {
                out[out.count - 1].1 = max(out[out.count - 1].1, e)
            } else {
                out.append((s, e))
            }
        }
        return out
    }

    /// Fixed-width human summary (the CorpusVideoTests table idiom): top stages by total time.
    public func summaryTable(limit: Int = 20) -> String {
        var lines: [String] = []
        lines.append(String(format: "%-34@ %6@ %10@ %9@ %9@ %9@",
                            "stage" as NSString, "count" as NSString, "total s" as NSString,
                            "mean ms" as NSString, "min ms" as NSString, "max ms" as NSString))
        lines.append(String(repeating: "─", count: 82))
        for st in aggregated().prefix(limit) {
            lines.append(String(format: "%-34@ %6d %10.3f %9.1f %9.1f %9.1f",
                                st.name as NSString, st.count, st.totalSeconds,
                                st.meanSeconds * 1000, st.minSeconds * 1000, st.maxSeconds * 1000))
        }
        let lanes = laneUtilization()
        if !lanes.isEmpty {
            lines.append("")
            lines.append("lane utilization over \(String(format: "%.3f", timelineSeconds)) s wall:")
            for l in lanes {
                lines.append(String(format: "  %-12@ busy %8.3f s  (%4.1f%%)",
                                    l.lane as NSString, l.busySeconds, l.utilization * 100))
            }
        }
        if meta.buildConfiguration != "release" {
            lines.append("")
            lines.append("⚠️ \(meta.buildConfiguration.uppercased()) build — timings are NOT comparable (H-2)")
        }
        return lines.joined(separator: "\n")
    }

    /// One JSON object per line: a `meta` record, then every span. Machine currency for benches.
    public func ndjson() -> Data {
        var out = Data()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        struct MetaLine: Codable { let t: String; let meta: Meta }
        struct SpanLine: Codable { let t: String; let name: String; let lane: String
            let startS: Double; let durS: Double; let attrs: [String: String]; let tid: UInt64 }
        if let m = try? enc.encode(MetaLine(t: "meta", meta: meta)) { out.append(m); out.append(0x0A) }
        for s in spans {
            let line = SpanLine(t: "span", name: s.name, lane: s.lane,
                                startS: (s.startSeconds * 1e6).rounded() / 1e6,
                                durS: (s.durationSeconds * 1e6).rounded() / 1e6,
                                attrs: s.attrs, tid: s.thread)
            if let d = try? enc.encode(line) { out.append(d); out.append(0x0A) }
        }
        return out
    }

    /// Chrome-trace JSON (load in Perfetto / chrome://tracing). Lanes render as named rows, so
    /// serialization gaps — decode idle while scoring, GPU idle while decoding — are visible at a
    /// glance; that picture is the harness's whole reason to exist.
    public func chromeTrace() -> Data {
        var laneTID: [String: Int] = [:]
        var events: [[String: Any]] = []
        for s in spans {
            let tid: Int
            if let t = laneTID[s.lane] { tid = t } else {
                tid = laneTID.count + 1
                laneTID[s.lane] = tid
                events.append(["ph": "M", "name": "thread_name", "pid": 1, "tid": tid,
                               "args": ["name": s.lane]])
            }
            var ev: [String: Any] = ["name": s.name, "cat": s.lane, "ph": "X", "pid": 1, "tid": tid,
                                     "ts": Double(s.startNS) / 1000.0,
                                     "dur": Double(s.durationNS) / 1000.0]
            if !s.attrs.isEmpty { ev["args"] = s.attrs }
            events.append(ev)
        }
        let doc: [String: Any] = ["traceEvents": events, "displayTimeUnit": "ms",
                                  "otherData": ["process": meta.process,
                                                "build": meta.buildConfiguration,
                                                "os": meta.osVersion]]
        return (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])) ?? Data()
    }
}

// MARK: - Collector

/// The process-wide collector. Off by default; opt in with `MEDIA_METRICS=1` (detail via
/// `MEDIA_METRICS_DETAIL=0|1|2`, default 1) or programmatically with `enable(detail:)`.
///
/// Detail levels — call sites declare how deep a span sits, the collector filters:
///   0  stage level (search passes, mezzanine, probe, per-item) — always recorded when enabled
///   1  frame level (per-frame ssimu2, per-iteration still encode/decode/score)
///   2  kernel level (per-channel GPU dispatch, ingest) — measurement-of-the-measurement
public enum MediaMetrics {

    private struct State {
        var enabled = false
        var detail = 1
        var epochUptimeNS: UInt64 = 0
        var spans: [MetricSpan] = []
        var dropped = 0
    }

    /// Cap on retained spans — a full 4K search at detail 2 stays well under this; a runaway
    /// per-pixel mistake degrades to a counted drop instead of eating the process.
    public static let maxSpans = 250_000

    private static let state: OSAllocatedUnfairLock<State> = {
        var s = State()
        let env = ProcessInfo.processInfo.environment
        if env["MEDIA_METRICS"] != nil {
            s.enabled = true
            s.detail = env["MEDIA_METRICS_DETAIL"].flatMap(Int.init) ?? 1
            s.epochUptimeNS = DispatchTime.now().uptimeNanoseconds
        }
        return OSAllocatedUnfairLock(initialState: s)
    }()
    private static let epochWall = Date()   // close enough to epochUptime for human labelling

    private static let signpostLog = OSLog(subsystem: "com.xocialize.media-bridge",
                                           category: "MediaMetrics")

    public static var isEnabled: Bool { state.withLock { $0.enabled } }
    public static var detailLevel: Int { state.withLock { $0.detail } }

    /// Start (or restart) collection. Resets the timeline and the epoch.
    public static func enable(detail: Int = 1) {
        let epoch = DispatchTime.now().uptimeNanoseconds
        state.withLock {
            $0.enabled = true
            $0.detail = detail
            $0.epochUptimeNS = epoch
            $0.spans.removeAll(keepingCapacity: true)
            $0.dropped = 0
        }
    }

    public static func disable() { state.withLock { $0.enabled = false } }

    /// Drop collected spans, keep enablement; the epoch resets so the next span starts near 0.
    public static func reset() {
        let epoch = DispatchTime.now().uptimeNanoseconds
        state.withLock {
            $0.spans.removeAll(keepingCapacity: true)
            $0.dropped = 0
            $0.epochUptimeNS = epoch
        }
    }

    // MARK: Recording

    /// Time a synchronous body as one span. The body always runs; recording depends on
    /// enablement + detail. `attrs` is an autoclosure — not built when collection is off.
    @discardableResult
    public static func time<R>(_ name: String, lane: String = "cpu", detail: Int = 0,
                               attrs: @autoclosure () -> [String: String] = [:],
                               _ body: () throws -> R) rethrows -> R {
        guard let h = begin(name, lane: lane, detail: detail, attrs: attrs()) else {
            return try body()
        }
        defer { end(h) }
        return try body()
    }

    /// Async twin. The span covers suspensions too — it measures wall clock, which is the currency
    /// pipeline-overlap analysis needs (a stage that awaits an encoder IS occupying its lane).
    @discardableResult
    public static func time<R>(_ name: String, lane: String = "cpu", detail: Int = 0,
                               attrs: @autoclosure () -> [String: String] = [:],
                               _ body: () async throws -> R) async rethrows -> R {
        guard let h = begin(name, lane: lane, detail: detail, attrs: attrs()) else {
            return try await body()
        }
        defer { end(h) }
        return try await body()
    }

    /// Manual bracket for spans that cross closure boundaries. `nil` when off — pass it to `end`
    /// unconditionally; both sides no-op.
    public static func begin(_ name: String, lane: String = "cpu", detail: Int = 0,
                             attrs: [String: String] = [:]) -> MetricSpanHandle? {
        let (on, epoch): (Bool, UInt64) = state.withLock {
            ($0.enabled && detail <= $0.detail, $0.epochUptimeNS)
        }
        guard on else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        let spid = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "span", signpostID: spid,
                    "%{public}s", name)
        return MetricSpanHandle(name: name, lane: lane, attrs: attrs,
                                startNS: now &- epoch, thread: currentThreadID(),
                                signpostID: spid.rawValue)
    }

    public static func end(_ handle: MetricSpanHandle?, extra: [String: String] = [:]) {
        guard let h = handle else { return }
        let nowRel: UInt64 = state.withLock { DispatchTime.now().uptimeNanoseconds &- $0.epochUptimeNS }
        os_signpost(.end, log: signpostLog, name: "span",
                    signpostID: OSSignpostID(h.signpostID), "%{public}s", h.name)
        let dur = nowRel > h.startNS ? nowRel - h.startNS : 0
        var attrs = h.attrs
        for (k, v) in extra { attrs[k] = v }
        append(MetricSpan(name: h.name, lane: h.lane, startNS: h.startNS, durationNS: dur,
                          attrs: attrs, thread: h.thread))
    }

    /// Instantaneous mark (zero-duration span) — verdicts, decisions, thresholds crossed.
    public static func event(_ name: String, lane: String = "orchestrate", detail: Int = 0,
                             attrs: [String: String] = [:]) {
        let (on, epoch): (Bool, UInt64) = state.withLock {
            ($0.enabled && detail <= $0.detail, $0.epochUptimeNS)
        }
        guard on else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        append(MetricSpan(name: name, lane: lane, startNS: now &- epoch, durationNS: 0,
                          attrs: attrs, thread: currentThreadID()))
    }

    private static func append(_ span: MetricSpan) {
        state.withLock {
            if $0.spans.count < maxSpans {
                $0.spans.append(span)
            } else {
                $0.dropped += 1
            }
        }
    }

    // MARK: Draining

    /// Snapshot the timeline (collection continues). Serialization/writing is the caller's job.
    public static func report() -> MetricsReport {
        let (spans, detail, dropped) = state.withLock { ($0.spans, $0.detail, $0.dropped) }
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        let p = ProcessInfo.processInfo
        return MetricsReport(
            meta: .init(epochWallClock: epochWall,
                        osVersion: p.operatingSystemVersionString,
                        process: p.processName, pid: p.processIdentifier,
                        buildConfiguration: config, detailLevel: detail, droppedSpans: dropped),
            spans: spans)
    }

    private static func currentThreadID() -> UInt64 {
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        return tid
    }
}
