import Foundation
import Metal
import CoreGraphics
import MediaMetrics

/// GPU backend for SSIMULACRA2's hot path. **V1 mirrors the pure-Swift `SSIMULACRA2` pipeline exactly**
/// (FIR σ=1.5 Gaussian, same constants) — a drop-in faster backend that *agrees with the CPU scores*, so
/// the corpus-validated 90/80/70 floors stay correct; the win is throughput (the blur runs 30×/score).
/// The recursive-IIR / canonical re-anchor is a deliberate V2 (`SSIMULACRA2-METAL-PLAN.md`). Runtime-
/// compiled Metal compute, verified headless on Apple M5 (not the MLX metallib boundary).
///
/// Stage 1 (this file): the separable Gaussian blur — the dominant cost and the parity-critical stage.
/// Later stages (XYB ingest, products, SSIM/edge maps, reductions, downsample, final) extend this.
// @unchecked Sendable: genuinely concurrency-safe as of the multi-set pool — every mutable member
// (`pool`) sits behind `poolLock`; device/queue/pipelines are immutable after init; `scoreResident`
// callers each hold a distinct working set. The Kit's width-3 bulk default calls this concurrently.
public final class SSIMULACRA2Metal: @unchecked Sendable {

    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let blurHPipe: MTLComputePipelineState
    private let blurVPipe: MTLComputePipelineState
    private let productsPipe: MTLComputePipelineState
    private let mapReducePipe: MTLComputePipelineState
    private let ingestPipe: MTLComputePipelineState
    private let downscalePipe: MTLComputePipelineState
    private let xybPipe: MTLComputePipelineState

    private static let tgSize = 256   // map-reduce threadgroup (power of 2)

    public init?() {
        let hCompile = MediaMetrics.begin("metal.compile", lane: "gpu")
        defer { MediaMetrics.end(hCompile) }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: Self.kernelSource, options: nil),
              let fh = lib.makeFunction(name: "ssimu2_blur_h"),
              let fv = lib.makeFunction(name: "ssimu2_blur_v"),
              let fp = lib.makeFunction(name: "ssimu2_products"),
              let fmr = lib.makeFunction(name: "ssimu2_map_reduce"),
              let fi = lib.makeFunction(name: "ssimu2_ingest"),
              let fd = lib.makeFunction(name: "ssimu2_downscale2"),
              let fx = lib.makeFunction(name: "ssimu2_xyb"),
              let ph = try? device.makeComputePipelineState(function: fh),
              let pv = try? device.makeComputePipelineState(function: fv),
              let pp = try? device.makeComputePipelineState(function: fp),
              let pmr = try? device.makeComputePipelineState(function: fmr),
              let pi = try? device.makeComputePipelineState(function: fi),
              let pd = try? device.makeComputePipelineState(function: fd),
              let px = try? device.makeComputePipelineState(function: fx)
        else { return nil }
        self.device = device
        self.queue = queue
        self.blurHPipe = ph
        self.blurVPipe = pv
        self.productsPipe = pp
        self.mapReducePipe = pmr
        self.ingestPipe = pi
        self.downscalePipe = pd
        self.xybPipe = px
    }

    /// Shared instance — kernels compile once. `nil` when no Metal device is available (→ CPU
    /// fallback), or when **`MEDIAMEASURE_NO_METAL`** is set — the measurement kill switch that
    /// forces the pure-Swift path so CPU-vs-GPU scoring can be A/B'd on identical inputs.
    public static let shared: SSIMULACRA2Metal? =
        ProcessInfo.processInfo.environment["MEDIAMEASURE_NO_METAL"] != nil ? nil : SSIMULACRA2Metal()

    /// Pinpoints WHERE GPU setup fails (device vs command-queue vs runtime shader compile vs pipeline) — so a
    /// host can tell a missing device (fixable by injecting one) from a `makeLibrary(source:)` failure (needs
    /// a precompiled metallib instead). Returns "OK …" when the GPU path is fully available.
    public static func diagnostics() -> String { cachedDiagnostics }

    /// Computed once (each run recompiles the Metal library — don't pay that per call).
    private static let cachedDiagnostics: String = {
        if ProcessInfo.processInfo.environment["MEDIAMEASURE_NO_METAL"] != nil {
            return "OFF: MEDIAMEASURE_NO_METAL set — CPU path forced"
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            return "FAIL: no Metal device (MTLCreateSystemDefaultDevice == nil)"
        }
        guard device.makeCommandQueue() != nil else {
            return "FAIL: \(device.name): makeCommandQueue == nil"
        }
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: kernelSource, options: nil) }
        catch { return "FAIL: \(device.name): makeLibrary(source:) threw — \(error)" }
        for fn in ["ssimu2_blur_h", "ssimu2_blur_v", "ssimu2_products", "ssimu2_map_reduce",
                   "ssimu2_ingest", "ssimu2_downscale2", "ssimu2_xyb"] {
            guard let f = lib.makeFunction(name: fn) else { return "FAIL: missing kernel \(fn)" }
            guard (try? device.makeComputePipelineState(function: f)) != nil else {
                return "FAIL: pipeline \(fn)"
            }
        }
        return "OK: GPU SSIMULACRA2 available on \(device.name)"
    }()

    /// The GPU blur exposed as an injectable `SSIMULACRA2.BlurFunction` (for `ImageQualityTarget` / `score`).
    public var blurFunction: SSIMULACRA2.BlurFunction {
        { src, w, h, k in self.blur(src, width: w, height: h, kernel: k) }
    }

    /// Full SSIMULACRA2 score with the **GPU blur injected** into the pure-Swift pipeline — only the
    /// σ=1.5 blur (the 90×/score bottleneck) runs on the GPU; XYB / SSIM+edge maps / reductions / final
    /// stay the validated CPU path, so this agrees with `SSIMULACRA2.score` to fp tolerance.
    public func score(reference: CGImage, distorted: CGImage) throws -> Double {
        try SSIMULACRA2.score(reference: reference, distorted: distorted) { src, w, h, k in
            self.blur(src, width: w, height: h, kernel: k)
        }
    }

    /// Separable FIR Gaussian blur on a `w×h` float plane (edge-clamped), matching `SSIMULACRA2.blur`.
    public func blur(_ src: [Float], width w: Int, height h: Int, kernel: [Float]) -> [Float] {
        let n = w * h
        guard n > 0, src.count == n, !kernel.isEmpty else { return src }
        let stride = MemoryLayout<Float>.stride
        let srcBuf = device.makeBuffer(bytes: src, length: n * stride, options: .storageModeShared)!
        let tmpBuf = device.makeBuffer(length: n * stride, options: .storageModeShared)!
        let outBuf = device.makeBuffer(length: n * stride, options: .storageModeShared)!
        let kBuf = device.makeBuffer(bytes: kernel, length: kernel.count * stride, options: .storageModeShared)!
        var W = Int32(w), H = Int32(h), R = Int32(kernel.count / 2)

        let cb = queue.makeCommandBuffer()!
        encode(cb, blurHPipe, src: srcBuf, dst: tmpBuf, k: kBuf, &W, &H, &R, w: w, h: h)
        encode(cb, blurVPipe, src: tmpBuf, dst: outBuf, k: kBuf, &W, &H, &R, w: w, h: h)
        cb.commit()
        cb.waitUntilCompleted()

        let p = outBuf.contents().bindMemory(to: Float.self, capacity: n)
        return Array(UnsafeBufferPointer(start: p, count: n))
    }

    /// The **full-GPU per-channel** backend as an injectable `SSIMULACRA2.ChannelScalars`: products +
    /// 5 blurs + SSIM/edge maps + reduction run on-device with planes resident; only `numTG*6` partial
    /// sums come back. `SSIMULACRA2.score(channelScalars:)` uses this for the all-GPU path.
    public var channelScalarsFunction: SSIMULACRA2.ChannelScalars {
        { i1, i2, w, h, kernel in self.channelScalars(i1, i2, width: w, height: h, kernel: kernel) }
    }

    public func channelScalars(_ i1: [Float], _ i2: [Float], width w: Int, height h: Int,
                               kernel: [Float]) -> SSIMULACRA2.ChannelResult {
        let hGPU = MediaMetrics.begin("ssimu2.gpu", lane: "gpu", detail: 2,
                                      attrs: ["w": "\(w)", "h": "\(h)"])
        defer { MediaMetrics.end(hGPU) }
        let n = w * h
        let fs = MemoryLayout<Float>.stride
        func buf(_ count: Int) -> MTLBuffer { device.makeBuffer(length: count * fs, options: .storageModeShared)! }
        func bufFrom(_ a: [Float]) -> MTLBuffer { device.makeBuffer(bytes: a, length: a.count * fs, options: .storageModeShared)! }

        let bi1 = bufFrom(i1), bi2 = bufFrom(i2), bk = bufFrom(kernel)
        let p11 = buf(n), p22 = buf(n), p12 = buf(n)
        let mu1 = buf(n), mu2 = buf(n), s11 = buf(n), s22 = buf(n), s12 = buf(n)
        let tmp = buf(n)
        let numTG = (n + Self.tgSize - 1) / Self.tgSize
        let partials = buf(numTG * 6)
        var W = Int32(w), H = Int32(h), R = Int32(kernel.count / 2), N = Int32(n), C2 = Float(0.0009)

        let cb = queue.makeCommandBuffer()!

        let pe = cb.makeComputeCommandEncoder()!
        pe.setComputePipelineState(productsPipe)
        pe.setBuffer(bi1, offset: 0, index: 0); pe.setBuffer(bi2, offset: 0, index: 1)
        pe.setBuffer(p11, offset: 0, index: 2); pe.setBuffer(p22, offset: 0, index: 3); pe.setBuffer(p12, offset: 0, index: 4)
        pe.setBytes(&N, length: 4, index: 5)
        pe.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                           threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        pe.endEncoding()

        blurInto(cb, src: bi1, tmp: tmp, dst: mu1, k: bk, &W, &H, &R, w: w, h: h)
        blurInto(cb, src: bi2, tmp: tmp, dst: mu2, k: bk, &W, &H, &R, w: w, h: h)
        blurInto(cb, src: p11, tmp: tmp, dst: s11, k: bk, &W, &H, &R, w: w, h: h)
        blurInto(cb, src: p22, tmp: tmp, dst: s22, k: bk, &W, &H, &R, w: w, h: h)
        blurInto(cb, src: p12, tmp: tmp, dst: s12, k: bk, &W, &H, &R, w: w, h: h)

        let me = cb.makeComputeCommandEncoder()!
        me.setComputePipelineState(mapReducePipe)
        me.setBuffer(bi1, offset: 0, index: 0); me.setBuffer(bi2, offset: 0, index: 1)
        me.setBuffer(mu1, offset: 0, index: 2); me.setBuffer(mu2, offset: 0, index: 3)
        me.setBuffer(s11, offset: 0, index: 4); me.setBuffer(s22, offset: 0, index: 5); me.setBuffer(s12, offset: 0, index: 6)
        me.setBytes(&N, length: 4, index: 7); me.setBytes(&C2, length: 4, index: 8)
        me.setBuffer(partials, offset: 0, index: 9)
        me.dispatchThreadgroups(MTLSize(width: numTG, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: Self.tgSize, height: 1, depth: 1))
        me.endEncoding()

        let hWait = MediaMetrics.begin("ssimu2.gpu.wait", lane: "gpu", detail: 2)
        cb.commit()
        cb.waitUntilCompleted()
        MediaMetrics.end(hWait)

        let pp = partials.contents().bindMemory(to: Float.self, capacity: numTG * 6)
        var sumD = 0.0, sumD4 = 0.0, aSum = 0.0, a4 = 0.0, dSum = 0.0, d4 = 0.0
        for t in 0..<numTG {
            sumD += Double(pp[t * 6 + 0]); sumD4 += Double(pp[t * 6 + 1])
            aSum += Double(pp[t * 6 + 2]); a4 += Double(pp[t * 6 + 3])
            dSum += Double(pp[t * 6 + 4]); d4 += Double(pp[t * 6 + 5])
        }
        let dn = Double(n)
        return SSIMULACRA2.ChannelResult(
            ssimL1: sumD / dn, ssimL4: (sumD4 / dn).squareRoot().squareRoot(),
            artifactL1: aSum / dn, artifactL4: (a4 / dn).squareRoot().squareRoot(),
            detailL1: dSum / dn, detailL4: (d4 / dn).squareRoot().squareRoot())
    }

    private func blurInto(_ cb: MTLCommandBuffer, src: MTLBuffer, tmp: MTLBuffer, dst: MTLBuffer, k: MTLBuffer,
                          _ W: inout Int32, _ H: inout Int32, _ R: inout Int32, w: Int, h: Int) {
        encode(cb, blurHPipe, src: src, dst: tmp, k: k, &W, &H, &R, w: w, h: h)
        encode(cb, blurVPipe, src: tmp, dst: dst, k: k, &W, &H, &R, w: w, h: h)
    }

    private func encode(_ cb: MTLCommandBuffer, _ pipe: MTLComputePipelineState,
                        src: MTLBuffer, dst: MTLBuffer, k: MTLBuffer,
                        _ W: inout Int32, _ H: inout Int32, _ R: inout Int32, w: Int, h: Int) {
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pipe)
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setBuffer(dst, offset: 0, index: 1)
        enc.setBuffer(k, offset: 0, index: 2)
        enc.setBytes(&W, length: 4, index: 3)
        enc.setBytes(&H, length: 4, index: 4)
        enc.setBytes(&R, length: 4, index: 5)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
    }

    // MARK: - Resident whole-score path

    /// Kill switch for A/B and emergencies: forces callers back to the V1 per-channel path
    /// (CPU ingest + pyramid, 18 GPU syncs per frame score).
    private static let residentDisabled =
        ProcessInfo.processInfo.environment["MEDIAMEASURE_NO_RESIDENT"] != nil

    /// The whole-score on-device path is available (kernels compiled, not env-disabled).
    public var residentAvailable: Bool { !Self.residentDisabled }

    /// Pooled per-resolution buffers. The searches score the same dimensions dozens of times, and
    /// the measured V1 anatomy charged ~198 fresh `MTLBuffer`s per frame score — the pool holds
    /// ONE cached set keyed by (w, h); a concurrent caller gets a transient set instead of waiting.
    /// ~21 float planes + 2 RGBA uploads ≈ 180 MB at 1080p, ~0.7 GB at 4K, reused across frames.
    private final class WorkingSet {
        let w: Int, h: Int, partialCapacity: Int
        var inUse = false
        let rgba1: MTLBuffer, rgba2: MTLBuffer
        var rgb1: [MTLBuffer], rgb2: [MTLBuffer]      // current-scale linear RGB (ping)
        var rgb1b: [MTLBuffer], rgb2b: [MTLBuffer]    // downscale targets (pong)
        let xyb1: [MTLBuffer], xyb2: [MTLBuffer]
        let work: [MTLBuffer]                          // p11 p22 p12 mu1 mu2 s11 s22 s12 tmp
        let kernelBuf: MTLBuffer
        let partials: MTLBuffer

        init?(device: MTLDevice, w: Int, h: Int, kernel: [Float], partialFloats: Int) {
            let n = w * h, fs = MemoryLayout<Float>.stride
            func plane() -> MTLBuffer? { device.makeBuffer(length: n * fs, options: .storageModeShared) }
            func planes(_ count: Int) -> [MTLBuffer]? {
                var out: [MTLBuffer] = []
                for _ in 0..<count { guard let p = plane() else { return nil }; out.append(p) }
                return out
            }
            guard let ra = device.makeBuffer(length: n * 4, options: .storageModeShared),
                  let rb = device.makeBuffer(length: n * 4, options: .storageModeShared),
                  let r1 = planes(3), let r2 = planes(3), let r1b = planes(3), let r2b = planes(3),
                  let x1 = planes(3), let x2 = planes(3), let wk = planes(9),
                  let kb = device.makeBuffer(bytes: kernel, length: kernel.count * fs,
                                             options: .storageModeShared),
                  let pt = device.makeBuffer(length: max(1, partialFloats) * fs,
                                             options: .storageModeShared)
            else { return nil }
            self.w = w; self.h = h; self.partialCapacity = partialFloats
            rgba1 = ra; rgba2 = rb; rgb1 = r1; rgb2 = r2; rgb1b = r1b; rgb2b = r2b
            xyb1 = x1; xyb2 = x2; work = wk; kernelBuf = kb; partials = pt
        }
    }
    private let poolLock = NSLock()
    /// Multi-set pool (was a single cached set): the Kit's bulk default of 3 concurrent stills
    /// (ForgeOptimizerKit v0.12.0, AB-R-0069) meant callers beyond the one cache allocated a
    /// transient working set PER SCORE (~0.18 GB @1080p, ~0.75 GB @4K — the 2.31× was measured
    /// WITH that churn). Policy: sets are reused by exact (w, h); a checkout for NEW dims evicts
    /// idle mismatched sets (a 4K batch's sets don't linger under 1080p work); at checkin, idle
    /// sets trim to `maxIdleSets` so steady-state width-3 batches reuse 2 and allocate at most
    /// one fresh set per BATCH, and an idle process holds ≤2 sets. In-flight count is bounded by
    /// the callers' own width (the Kit clamps at 8).
    private var pool: [WorkingSet] = []
    private static let maxIdleSets = 2

    private func checkout(w: Int, h: Int, kernel: [Float], partialFloats: Int) -> WorkingSet? {
        poolLock.lock()
        if let s = pool.first(where: { !$0.inUse && $0.w == w && $0.h == h
                                       && $0.partialCapacity >= partialFloats }) {
            s.inUse = true
            poolLock.unlock()
            return s
        }
        pool.removeAll { !$0.inUse && ($0.w != w || $0.h != h) }   // dims changed → drop stale idles
        poolLock.unlock()
        guard let fresh = WorkingSet(device: device, w: w, h: h, kernel: kernel,
                                     partialFloats: partialFloats) else { return nil }
        fresh.inUse = true
        poolLock.lock()
        pool.append(fresh)
        poolLock.unlock()
        return fresh
    }
    private func checkin(_ set: WorkingSet) {
        poolLock.lock()
        set.inUse = false
        var idle = 0
        pool.removeAll { s in
            guard !s.inUse else { return false }
            idle += 1
            return idle > Self.maxIdleSets
        }
        poolLock.unlock()
    }

    /// Full SSIMULACRA2 with ingest, XYB, the 2×2 pyramid, products, blurs, and reductions all
    /// resident on-device, encoded into ONE command buffer with ONE `waitUntilCompleted` — versus
    /// V1's two CPU plane conversions plus 18 sync round-trips per frame score (measured: the V1
    /// "GPU" score was two-thirds CPU, and most of the GPU share was stall). Same FIR math as the
    /// pure-Swift pipeline — this is NOT the canonical-IIR re-anchor (SSIMULACRA2-METAL-PLAN's
    /// V2); parity target is the currently-calibrated scores, gated at ±0.05 in the test suite.
    /// The only CPU work left per score: two `CGContext.draw` rasterizes into the shared upload
    /// buffers, and the tiny partial-sum tail through the shared `finalScore`.
    public func scoreResident(reference: CGImage, distorted: CGImage) throws -> Double {
        let w = reference.width, h = reference.height
        guard w == distorted.width, h == distorted.height else {
            throw SSIMULACRA2.ScoreError.dimensionMismatch
        }
        guard w >= 8, h >= 8 else { throw SSIMULACRA2.ScoreError.tooSmall }
        let mm = MediaMetrics.begin("ssimu2", lane: "score", detail: 1,
                                    attrs: ["w": "\(w)", "h": "\(h)", "path": "resident"])
        defer { MediaMetrics.end(mm) }

        // Per-scale ladder, exactly the CPU loop's (2×2 clamp-mean, stop below 8×8, max 6).
        var dims: [(w: Int, h: Int)] = [(w, h)]
        while dims.count < 6 {
            let (pw, ph) = dims[dims.count - 1]
            let nw = (pw + 1) / 2, nh = (ph + 1) / 2
            if nw < 8 || nh < 8 { break }
            dims.append((nw, nh))
        }
        // Partials layout, 64-float (256 B) aligned per (scale, channel) segment for setBuffer.
        var offsets: [[Int]] = []
        var totalFloats = 0
        for d in dims {
            let numTG = (d.w * d.h + Self.tgSize - 1) / Self.tgSize
            var row: [Int] = []
            for _ in 0..<3 {
                row.append(totalFloats)
                totalFloats += ((numTG * 6 + 63) / 64) * 64
            }
            offsets.append(row)
        }
        let kernel = SSIMULACRA2.gaussianKernel(sigma: 1.5)
        guard let set = checkout(w: w, h: h, kernel: kernel, partialFloats: totalFloats) else {
            throw SSIMULACRA2.ScoreError.rasterFailed
        }
        defer { checkin(set) }

        // Rasterize straight into the shared-memory upload buffers (the linearize loop moves off-CPU).
        let hRaster = MediaMetrics.begin("ssimu2.res.raster", lane: "cpu", detail: 2)
        try Self.rasterize(reference, into: set.rgba1, width: w, height: h)
        try Self.rasterize(distorted, into: set.rgba2, width: w, height: h)
        MediaMetrics.end(hRaster)

        guard let cb = queue.makeCommandBuffer() else { throw SSIMULACRA2.ScoreError.rasterFailed }
        var bias = SSIMULACRA2.cbrtBias
        var R = Int32(kernel.count / 2)

        encodeIngest(cb, rgba: set.rgba1, planes: set.rgb1, n: w * h)
        encodeIngest(cb, rgba: set.rgba2, planes: set.rgb2, n: w * h)
        var cur1 = set.rgb1, cur2 = set.rgb2, alt1 = set.rgb1b, alt2 = set.rgb2b
        for (scale, d) in dims.enumerated() {
            if scale > 0 {
                let p = dims[scale - 1]
                for i in 0..<3 {
                    encodeDownscale(cb, src: cur1[i], dst: alt1[i], p.w, p.h, d.w, d.h)
                    encodeDownscale(cb, src: cur2[i], dst: alt2[i], p.w, p.h, d.w, d.h)
                }
                swap(&cur1, &alt1); swap(&cur2, &alt2)
            }
            let n = d.w * d.h
            encodeXYB(cb, rgb: cur1, xyb: set.xyb1, n: n, bias: &bias)
            encodeXYB(cb, rgb: cur2, xyb: set.xyb2, n: n, bias: &bias)
            var W = Int32(d.w), H = Int32(d.h), N = Int32(n), C2 = Float(0.0009)
            let numTG = (n + Self.tgSize - 1) / Self.tgSize
            for c in 0..<3 {
                let pe = cb.makeComputeCommandEncoder()!
                pe.setComputePipelineState(productsPipe)
                pe.setBuffer(set.xyb1[c], offset: 0, index: 0)
                pe.setBuffer(set.xyb2[c], offset: 0, index: 1)
                pe.setBuffer(set.work[0], offset: 0, index: 2)
                pe.setBuffer(set.work[1], offset: 0, index: 3)
                pe.setBuffer(set.work[2], offset: 0, index: 4)
                pe.setBytes(&N, length: 4, index: 5)
                pe.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                pe.endEncoding()

                blurInto(cb, src: set.xyb1[c], tmp: set.work[8], dst: set.work[3], k: set.kernelBuf,
                         &W, &H, &R, w: d.w, h: d.h)
                blurInto(cb, src: set.xyb2[c], tmp: set.work[8], dst: set.work[4], k: set.kernelBuf,
                         &W, &H, &R, w: d.w, h: d.h)
                blurInto(cb, src: set.work[0], tmp: set.work[8], dst: set.work[5], k: set.kernelBuf,
                         &W, &H, &R, w: d.w, h: d.h)
                blurInto(cb, src: set.work[1], tmp: set.work[8], dst: set.work[6], k: set.kernelBuf,
                         &W, &H, &R, w: d.w, h: d.h)
                blurInto(cb, src: set.work[2], tmp: set.work[8], dst: set.work[7], k: set.kernelBuf,
                         &W, &H, &R, w: d.w, h: d.h)

                let me = cb.makeComputeCommandEncoder()!
                me.setComputePipelineState(mapReducePipe)
                me.setBuffer(set.xyb1[c], offset: 0, index: 0)
                me.setBuffer(set.xyb2[c], offset: 0, index: 1)
                me.setBuffer(set.work[3], offset: 0, index: 2)
                me.setBuffer(set.work[4], offset: 0, index: 3)
                me.setBuffer(set.work[5], offset: 0, index: 4)
                me.setBuffer(set.work[6], offset: 0, index: 5)
                me.setBuffer(set.work[7], offset: 0, index: 6)
                me.setBytes(&N, length: 4, index: 7)
                me.setBytes(&C2, length: 4, index: 8)
                me.setBuffer(set.partials, offset: offsets[scale][c] * MemoryLayout<Float>.stride,
                             index: 9)
                me.dispatchThreadgroups(MTLSize(width: numTG, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: Self.tgSize, height: 1, depth: 1))
                me.endEncoding()
            }
        }

        let hGPU = MediaMetrics.begin("ssimu2.res.gpu", lane: "gpu", detail: 2)
        cb.commit()
        cb.waitUntilCompleted()
        MediaMetrics.end(hGPU)

        // CPU tail: fold the per-threadgroup partials exactly like V1's readback, then the shared
        // trained-weights polynomial.
        let pp = set.partials.contents().bindMemory(to: Float.self, capacity: totalFloats)
        var scales: [SSIMULACRA2.Scale] = []
        for (scale, d) in dims.enumerated() {
            let n = d.w * d.h
            let numTG = (n + Self.tgSize - 1) / Self.tgSize
            var s = SSIMULACRA2.Scale()
            for c in 0..<3 {
                let base = offsets[scale][c]
                var sumD = 0.0, sumD4 = 0.0, aSum = 0.0, a4 = 0.0, dSum = 0.0, d4 = 0.0
                for t in 0..<numTG {
                    sumD += Double(pp[base + t * 6 + 0]); sumD4 += Double(pp[base + t * 6 + 1])
                    aSum += Double(pp[base + t * 6 + 2]); a4 += Double(pp[base + t * 6 + 3])
                    dSum += Double(pp[base + t * 6 + 4]); d4 += Double(pp[base + t * 6 + 5])
                }
                let dn = Double(n)
                s.avgSsim[c * 2 + 0] = sumD / dn
                s.avgSsim[c * 2 + 1] = (sumD4 / dn).squareRoot().squareRoot()
                s.avgEdge[c * 4 + 0] = aSum / dn
                s.avgEdge[c * 4 + 1] = (a4 / dn).squareRoot().squareRoot()
                s.avgEdge[c * 4 + 2] = dSum / dn
                s.avgEdge[c * 4 + 3] = (d4 / dn).squareRoot().squareRoot()
            }
            scales.append(s)
        }
        return SSIMULACRA2.finalScore(scales)
    }

    private static func rasterize(_ image: CGImage, into buf: MTLBuffer,
                                  width: Int, height: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: buf.contents(), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw SSIMULACRA2.ScoreError.rasterFailed
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func encodeIngest(_ cb: MTLCommandBuffer, rgba: MTLBuffer, planes: [MTLBuffer], n: Int) {
        var N = Int32(n)
        let e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(ingestPipe)
        e.setBuffer(rgba, offset: 0, index: 0)
        e.setBuffer(planes[0], offset: 0, index: 1)
        e.setBuffer(planes[1], offset: 0, index: 2)
        e.setBuffer(planes[2], offset: 0, index: 3)
        e.setBytes(&N, length: 4, index: 4)
        e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        e.endEncoding()
    }

    private func encodeDownscale(_ cb: MTLCommandBuffer, src: MTLBuffer, dst: MTLBuffer,
                                 _ w: Int, _ h: Int, _ ow: Int, _ oh: Int) {
        var W = Int32(w), H = Int32(h), OW = Int32(ow), OH = Int32(oh)
        let e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(downscalePipe)
        e.setBuffer(src, offset: 0, index: 0)
        e.setBuffer(dst, offset: 0, index: 1)
        e.setBytes(&W, length: 4, index: 2)
        e.setBytes(&H, length: 4, index: 3)
        e.setBytes(&OW, length: 4, index: 4)
        e.setBytes(&OH, length: 4, index: 5)
        e.dispatchThreads(MTLSize(width: ow, height: oh, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        e.endEncoding()
    }

    private func encodeXYB(_ cb: MTLCommandBuffer, rgb: [MTLBuffer], xyb: [MTLBuffer],
                           n: Int, bias: inout Float) {
        var N = Int32(n)
        let e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(xybPipe)
        e.setBuffer(rgb[0], offset: 0, index: 0)
        e.setBuffer(rgb[1], offset: 0, index: 1)
        e.setBuffer(rgb[2], offset: 0, index: 2)
        e.setBuffer(xyb[0], offset: 0, index: 3)
        e.setBuffer(xyb[1], offset: 0, index: 4)
        e.setBuffer(xyb[2], offset: 0, index: 5)
        e.setBytes(&N, length: 4, index: 6)
        e.setBytes(&bias, length: 4, index: 7)
        e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        e.endEncoding()
    }

    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void ssimu2_blur_h(device const float* src [[buffer(0)]], device float* dst [[buffer(1)]],
                              device const float* k [[buffer(2)]], constant int& W [[buffer(3)]],
                              constant int& H [[buffer(4)]], constant int& R [[buffer(5)]],
                              uint2 gid [[thread_position_in_grid]]) {
        int x = int(gid.x), y = int(gid.y);
        if (x >= W || y >= H) return;
        int row = y * W; float acc = 0.0;
        for (int j = -R; j <= R; ++j) { int xx = min(max(x + j, 0), W - 1); acc += src[row + xx] * k[j + R]; }
        dst[row + x] = acc;
    }
    kernel void ssimu2_blur_v(device const float* src [[buffer(0)]], device float* dst [[buffer(1)]],
                              device const float* k [[buffer(2)]], constant int& W [[buffer(3)]],
                              constant int& H [[buffer(4)]], constant int& R [[buffer(5)]],
                              uint2 gid [[thread_position_in_grid]]) {
        int x = int(gid.x), y = int(gid.y);
        if (x >= W || y >= H) return;
        float acc = 0.0;
        for (int j = -R; j <= R; ++j) { int yy = min(max(y + j, 0), H - 1); acc += src[yy * W + x] * k[j + R]; }
        dst[y * W + x] = acc;
    }
    kernel void ssimu2_products(device const float* i1 [[buffer(0)]], device const float* i2 [[buffer(1)]],
                                device float* p11 [[buffer(2)]], device float* p22 [[buffer(3)]],
                                device float* p12 [[buffer(4)]], constant int& N [[buffer(5)]],
                                uint gid [[thread_position_in_grid]]) {
        if (int(gid) >= N) return;
        float a = i1[gid], b = i2[gid];
        p11[gid] = a * a; p22[gid] = b * b; p12[gid] = a * b;
    }
    // Per-pixel SSIM + edge-diff, reduced to 6 partial sums per threadgroup (tg=256).
    kernel void ssimu2_map_reduce(device const float* i1 [[buffer(0)]], device const float* i2 [[buffer(1)]],
                                  device const float* mu1 [[buffer(2)]], device const float* mu2 [[buffer(3)]],
                                  device const float* s11 [[buffer(4)]], device const float* s22 [[buffer(5)]],
                                  device const float* s12 [[buffer(6)]], constant int& N [[buffer(7)]],
                                  constant float& C2 [[buffer(8)]], device float* partials [[buffer(9)]],
                                  uint gid [[thread_position_in_grid]], uint lid [[thread_position_in_threadgroup]],
                                  uint tg [[threadgroup_position_in_grid]]) {
        threadgroup float sm[6][256];
        float v0 = 0, v1 = 0, v2 = 0, v3 = 0, v4 = 0, v5 = 0;
        if (int(gid) < N) {
            float m1 = mu1[gid], m2 = mu2[gid];
            float md = m1 - m2;
            float numM = 1.0 - md * md;
            float numS = 2.0 * (s12[gid] - m1 * m2) + C2;
            float denomS = (s11[gid] - m1 * m1) + (s22[gid] - m2 * m2) + C2;
            float d = fmax(1.0 - (numM * numS) / denomS, 0.0);
            v0 = d; v1 = d * d * d * d;
            float d1 = (1.0 + fabs(i2[gid] - m2)) / (1.0 + fabs(i1[gid] - m1)) - 1.0;
            float art = fmax(d1, 0.0), det = fmax(-d1, 0.0);
            v2 = art; v3 = art * art * art * art;
            v4 = det; v5 = det * det * det * det;
        }
        sm[0][lid] = v0; sm[1][lid] = v1; sm[2][lid] = v2; sm[3][lid] = v3; sm[4][lid] = v4; sm[5][lid] = v5;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint s = 128; s > 0; s >>= 1) {
            if (lid < s) { for (int k = 0; k < 6; ++k) sm[k][lid] += sm[k][lid + s]; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (lid == 0) { for (int k = 0; k < 6; ++k) partials[tg * 6 + k] = sm[k][0]; }
    }
    // RGBA8 → linear-RGB float planes (sRGB EOTF, exact branch match with the CPU port).
    kernel void ssimu2_ingest(device const uchar* rgba [[buffer(0)]],
                              device float* r [[buffer(1)]], device float* g [[buffer(2)]],
                              device float* b [[buffer(3)]], constant int& N [[buffer(4)]],
                              uint gid [[thread_position_in_grid]]) {
        if (int(gid) >= N) return;
        float3 c = float3(rgba[gid * 4 + 0], rgba[gid * 4 + 1], rgba[gid * 4 + 2]) / 255.0f;
        float3 lo = c / 12.92f;
        float3 hi = pow((c + 0.055f) / 1.055f, 2.4f);
        float3 lin = select(hi, lo, c <= 0.04045f);
        r[gid] = lin.x; g[gid] = lin.y; b[gid] = lin.z;
    }
    // 2×2 box mean with edge clamp — the CPU downscaleBy2, one plane per dispatch.
    kernel void ssimu2_downscale2(device const float* src [[buffer(0)]], device float* dst [[buffer(1)]],
                                  constant int& W [[buffer(2)]], constant int& H [[buffer(3)]],
                                  constant int& OW [[buffer(4)]], constant int& OH [[buffer(5)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        int ox = int(gid.x), oy = int(gid.y);
        if (ox >= OW || oy >= OH) return;
        float s = 0.0f;
        for (int iy = 0; iy < 2; ++iy)
            for (int ix = 0; ix < 2; ++ix) {
                int x = min(ox * 2 + ix, W - 1);
                int y = min(oy * 2 + iy, H - 1);
                s += src[y * W + x];
            }
        dst[oy * OW + ox] = s * 0.25f;
    }
    // linear RGB → positive-XYB (opsin constants verbatim from the port; bias passed from the
    // host so it is the SAME cbrtf(kB0) value the CPU path subtracts).
    kernel void ssimu2_xyb(device const float* r [[buffer(0)]], device const float* g [[buffer(1)]],
                           device const float* b [[buffer(2)]],
                           device float* X [[buffer(3)]], device float* Y [[buffer(4)]],
                           device float* B [[buffer(5)]], constant int& N [[buffer(6)]],
                           constant float& cbrtBias [[buffer(7)]],
                           uint gid [[thread_position_in_grid]]) {
        if (int(gid) >= N) return;
        const float kB0 = 0.0037930732552754493f;
        float rr = r[gid], gg = g[gid], bb = b[gid];
        float m0 = 0.30f * rr + 0.622f * gg + 0.078f * bb + kB0;
        float m1 = 0.23f * rr + 0.692f * gg + 0.078f * bb + kB0;
        float m2 = 0.24342268924547819f * rr + 0.20476744424496821f * gg
                 + 0.5518098657995536f * bb + kB0;
        m0 = pow(m0, 1.0f / 3.0f) - cbrtBias;
        m1 = pow(m1, 1.0f / 3.0f) - cbrtBias;
        m2 = pow(m2, 1.0f / 3.0f) - cbrtBias;
        float x = 0.5f * (m0 - m1);
        float y = 0.5f * (m0 + m1);
        float z = m2;
        z = (z - y) + 0.55f;
        x = x * 14.0f + 0.42f;
        y = y + 0.01f;
        X[gid] = x; Y[gid] = y; B[gid] = z;
    }
    """
}
