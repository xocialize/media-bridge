import Foundation
import Metal
import CoreGraphics

/// GPU backend for SSIMULACRA2's hot path. **V1 mirrors the pure-Swift `SSIMULACRA2` pipeline exactly**
/// (FIR σ=1.5 Gaussian, same constants) — a drop-in faster backend that *agrees with the CPU scores*, so
/// the corpus-validated 90/80/70 floors stay correct; the win is throughput (the blur runs 30×/score).
/// The recursive-IIR / canonical re-anchor is a deliberate V2 (`SSIMULACRA2-METAL-PLAN.md`). Runtime-
/// compiled Metal compute, verified headless on Apple M5 (not the MLX metallib boundary).
///
/// Stage 1 (this file): the separable Gaussian blur — the dominant cost and the parity-critical stage.
/// Later stages (XYB ingest, products, SSIM/edge maps, reductions, downsample, final) extend this.
public final class SSIMULACRA2Metal {

    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let blurHPipe: MTLComputePipelineState
    private let blurVPipe: MTLComputePipelineState
    private let productsPipe: MTLComputePipelineState
    private let mapReducePipe: MTLComputePipelineState

    private static let tgSize = 256   // map-reduce threadgroup (power of 2)

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: Self.kernelSource, options: nil),
              let fh = lib.makeFunction(name: "ssimu2_blur_h"),
              let fv = lib.makeFunction(name: "ssimu2_blur_v"),
              let fp = lib.makeFunction(name: "ssimu2_products"),
              let fmr = lib.makeFunction(name: "ssimu2_map_reduce"),
              let ph = try? device.makeComputePipelineState(function: fh),
              let pv = try? device.makeComputePipelineState(function: fv),
              let pp = try? device.makeComputePipelineState(function: fp),
              let pmr = try? device.makeComputePipelineState(function: fmr)
        else { return nil }
        self.device = device
        self.queue = queue
        self.blurHPipe = ph
        self.blurVPipe = pv
        self.productsPipe = pp
        self.mapReducePipe = pmr
    }

    /// Shared instance — kernels compile once. `nil` when no Metal device is available (→ CPU fallback).
    public static let shared = SSIMULACRA2Metal()

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

        cb.commit()
        cb.waitUntilCompleted()

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
    """
}
