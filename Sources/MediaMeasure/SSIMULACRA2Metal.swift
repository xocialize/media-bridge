import Foundation
import Metal

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

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: Self.kernelSource, options: nil),
              let fh = lib.makeFunction(name: "ssimu2_blur_h"),
              let fv = lib.makeFunction(name: "ssimu2_blur_v"),
              let ph = try? device.makeComputePipelineState(function: fh),
              let pv = try? device.makeComputePipelineState(function: fv)
        else { return nil }
        self.device = device
        self.queue = queue
        self.blurHPipe = ph
        self.blurVPipe = pv
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
    """
}
