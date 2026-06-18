# Metal SSIMULACRA2 — build & parity spec

A GPU SSIMULACRA2 backend for `MediaMeasure`, alongside the existing pure-Swift `SSIMULACRA2.score`.
**Why (revised 2026-06-18):** the floor re-baseline is **no longer the driver** — in a **Release** build
the pure-Swift path is ~1 s at 1080p (the "throughput wall" was a Debug no-specialization artifact; see
LESSONS), so re-baselining is tractable on CPU. Metal is now for **(1) real-time in-app perceptual checks**
(live preview / interactive optimize, where ~8 s/optimize is sluggish) and **(2) 4K/native at scale**.
Still worth building for those + the parity-correct reference. Distilled from a deep-research pass (2026-06;
caveats at bottom). Pairs with the MOS score scale (`90 visually-lossless / 80 very-high / 70 high`).

## The decisive calls

1. **Hand-written Metal compute, NOT MPS primitives.** The parity-critical stage is the **Gaussian blur
   (σ=1.5)**: libjxl uses a **recursive IIR (Young–van Vliet) Gaussian** (`CreateRecursiveGaussian(1.5)`,
   `tools/gauss_blur.cc`). `MPSImageGaussianBlur` is a different truncated/approximate filter and will
   **silently drift the score** — worst exactly at small σ. Port the recursive IIR (or a long FP32 FIR
   validated against golden blurred-plane dumps). MPS only for cheap parity-safe stages (2×2 box
   downsample, elementwise, L1 sums).
2. **Parity = per-stage tolerance vs canonical golden dumps, NOT bitwise.** CPU↔GPU bitwise is
   impossible (reduction order, FMA, transcendental impls) — same stance as our MLX bf16 work. Anchor =
   **canonical libjxl / rust-av**, NOT our Swift port (which carries the known FIR-Gaussian drift).
3. **Mixed precision: fp16 storage OK; fp32 accumulate for blur + pooling + variance; fp64 final.**

## Precision map

- **fp16-safe:** sRGB→linear, holding XYB planes, the elementwise products — *iff* the blur/reductions
  feeding them are fp32.
- **fp32-REQUIRED:** (a) opsin `cbrt` + the ×14 X-channel gain; (b) **all Gaussian accumulation**;
  (c) variance/covariance subtractions `E[x²]−E[x]²`; (d) **pooling L1/L4 accumulators** (use
  pairwise/Kahan in threadgroup memory — d⁴ has huge dynamic range); (e) final 108-weight sum +
  polynomial in **fp64** (reference pools in `double`).
- Default = **fp16 storage / fp32 accumulate**, with a compile switch to **all-fp32** for the floor
  re-baseline. **Never re-baseline a floor with the fp16 fast path.**

## Stage map

| # | Stage | Build | Precision |
|---|---|---|---|
| 0 | load RGB → planar buffers (libjxl is planar) | custom | fp32 in |
| 1 | sRGB→linear (EOTF) | custom kernel (fuse w/ 2,3) — avoid MPS colorspace | fp32 |
| 2 | linear→XYB (opsin: 3×3 matmul+bias+clamp+cbrt+mix) | custom (fuse) | fp32 |
| 3 | MakePositiveXYB (per-pixel affine) | fuse into 2 | fp32 |
| 4 | products X²,Y²,B²,XY… | custom elementwise (fuse) | fp16 store / fp32 |
| 5 | **Gaussian σ=1.5** (μ + blurred products) | **custom recursive-IIR / matched FIR — MAKE/BREAK** | **fp32 accum** |
| 6 | SSIM map | custom elementwise | fp32 |
| 7 | edge-diff maps (artifact / detail-lost) | custom elementwise | fp32 |
| 8 | pooling L1 + L4 per plane | custom threadgroup reduction (careful) | **fp32 careful** |
| 9 | 2×2 box downsample on **linear RGB** (XYB recomputed each scale) | custom (NOT MPSImagePyramid) | fp32 |
| 10 | 108-weight dot + cubic + power remap | CPU/Swift scalar | **fp64** |

6 scales; one command buffer per scale; read back 18 scalars/scale, finish on CPU.

## Constants (VERIFY against pinned libjxl commit before locking — see caveats)

**sRGB EOTF:** `linear = c/12.92 if c≤0.04045 else ((c+0.055)/1.055)^2.4`.
**Opsin (linear RGB→XYB), `kOpsinAbsorbanceMatrix` row-major:**
`{0.30,0.622,0.078} / {0.23,0.692,0.078} / {0.24342268924547819,0.20476744424496821,0.55180986650955360}`,
bias `{0.0037930734,0.0037930734,0.0037930734}`. Steps: `mixed=M·rgb+bias`; `max(mixed,0)`;
`cbrt(mixed)−cbrt(bias)`; `X=0.5(L−M)`, `Y=0.5(L+M)`, `B=S`. (intensity_target=255 ⇒ premul mul=1.)
**MakePositiveXYB** (per-pixel, SSIMULACRA2-specific — NOT libjxl `ScaleXYB`):
`B=(B−Y)+0.55; X=X·14.0+0.42; Y=Y+0.01`.
**Downsample:** exact 2×2 average, normalize `0.25`, edges clamped `min(ox*2+ix, w−1)`, on **linear RGB**.
**SSIM map** (`kC2=0.0009`, **no C1 / luma denom dropped**):
`num_m=1−(μ1−μ2)²; num_s=2(σ12−μ1μ2)+C2; denom_s=(σ11−μ1²)+(σ22−μ2²)+C2; d=max(1−num_m·num_s/denom_s, 0)`.
Pool: L1=mean(d), L4=mean(d⁴)^0.25.
**Edge-diff** (from `|img−μ|`): `d1=(1+|i2−μ2|)/(1+|i1−μ1|)−1; artifact=max(d1,0); detail_lost=max(−d1,0)`. L1+L4 each.
**Per-scale:** `avg_ssim[3·2]`, `avg_edgediff[3·4]`. **Final:** weighted sum of 108 (`weight[108]`, ~40 nonzero),
then `ssim*=0.9562382616834844; ssim=2.326765642916932·s−0.020884521182843837·s²+6.248496625763138e-05·s³;
score = s>0 ? 100−10·pow(s,0.6276336467831387) : 100`.
**Regression gates:** identical → exactly 100; tank pair (`tank_source/tank_distorted.png`) → ≈17.3985 (±0.25 CI).

## Tolerance ladder (vs canonical golden dumps)

XYB/colorspace rel ≤ 1e-5 · per blurred plane rel ≤ 1e-3 *(>this ⇒ blur is wrong)* · SSIM/edge maps
rel ≤ 1e-3 · per-scale pooled norms abs ≤ 1e-4 · **final score abs ≤ 0.02–0.05** (recursive Gaussian +
fp32 pooling). MPS-approx blur ⇒ loosen to ±0.1–0.5 = correlated-but-distinct, OK for live checks, **NOT
for floor re-baseline**.

## Staged build plan

1. **Skeleton (offline, all-fp32, long FP32 FIR blur)** + the golden-dump harness (build `ssimulacra2_rs`
   as oracle). Gate: identical=100 exact, tank within ±0.1.
2. **Gaussian parity** — port libjxl recursive IIR (or tune FIR until per-blurred-plane diff ≤1e-3).
   Re-gate final ±0.02–0.05. **Make-or-break.**
3. **Verify our Swift port** — run `MediaMeasure.SSIMULACRA2.score` through the same harness to quantify
   ITS deviation from canonical (the ~2.5pt FIR drift) → decide whether to also correct the Swift blur.
4. **Fast path (live)** — fp16 storage / fp32 accumulate, fused kernels; gate vs the all-fp32 GPU path
   at a looser documented tol (±0.1). Live in-app only.

## Measured Swift-port drift (2026-06-18 — first datapoint, Stage 3 started)

Canonical = libjxl `ssimulacra2` 0.11.2 (`/opt/homebrew/bin`). Ours = `forge score` (MediaMeasure pure-
Swift) on `Corpus/derived/320/stills/RBC_photo.png` vs JPEG-distorted copies:

| distortion | canonical | ours | Δ (ours−canon) |
|---|---|---|---|
| jpeg-q30 | 59.60 | 57.60 | **−2.00** |
| jpeg-q60 | 76.78 | 75.57 | **−1.21** |
| jpeg-q90 | 81.41 | 81.33 | **−0.08** |

**Our port reads LOW, score-dependent (worst mid-range, ~0 near-lossless)** — the Gaussian-mismatch
signature, confirmed. Implications: (1) our floor presets (defined on Swift scores) are ~1–2 pts
**conservative** vs canonical MOS in the 70–80 operative band → safe (we over-deliver quality slightly,
leave a little compression on the table), but the labels are mis-anchored by ~1–2. (2) One image / 3
points — drift varies by content; don't re-tune floors on this alone. The Metal port (canonical parity)
or a validated Swift-blur fix re-anchors properly. Harness now exists (`forge score` + the binary).

## Golden-harness methodology

Build the reference (`ssimulacra2_rs` / libjxl `ssimulacra2`) as oracle; instrument it to dump: linear RGB,
XYB pre/post-MakePositive, each blurred plane (μ1,μ2,σ11,σ22,σ12) per scale, SSIM + edge maps, per-scale
`avg_*`, the 108 raw sub-scores. Dump the SAME from the Metal pipeline AND our Swift port → **three-way
diff** at each stage. Score-range pairs: identical(=100), tank(≈17.4), plus mozjpeg/cjxl anchors spanning
30/50/90.

## Where it runs / verification boundary

Runtime-compiled Metal **compute** (like our preview shaders) should run **headless** in a CLI process
(`MTLCreateSystemDefaultDevice` + compute pipelines work without Xcode — this is NOT the MLX metallib
boundary). If so, a `forge`/media-bridge CLI gets native-res SSIMULACRA2 → **directly unblocks the corpus
re-baseline**. Watch the GPU watchdog (discipline command buffers — the watchdog trips on undisciplined
submission, per the dev-machine lesson); post-reboot Metal-cryptex flakiness → Debug. If headless GPU
proves flaky, the parity-harness + offline runs go through the Xcode agent (AGENT_BRIDGE ticket).

## Caveats — verify before locking constants

- **Read directly & pin a commit (v2.1 retuned weights, Apr 2023 — weights changed v2.0→v2.1):**
  `lib/jxl/cms/opsin_params.h` (opsin matrix rows 0/1 + bias corroborated indirectly — confirm),
  `tools/gauss_blur.cc` (the recursive-IIR coefficients — port exactly), `tools/ssimulacra2.cc`
  (the full `weight[108]` array + polynomial). rust-av `ssimulacra2` crate is the easier line-by-line read.
- M5 Max: ~614 GB/s / 128 GB (Apple newsroom); ~70 TFLOPS FP16 is a 3rd-party estimate. Neural
  Accelerators/TensorOps don't materially help this metric — win is FP16 ALU + bandwidth. Measure on-box.
- Closest existing design = `turbo-metrics/ssimulacra2-cuda` (CUDA, not bit-parity); `msplat` ships
  hand-written separable-blur Metal kernels = a structural template (but textbook 11-tap, not recursive).
