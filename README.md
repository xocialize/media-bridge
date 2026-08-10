# media-bridge

The **FFmpeg-free**, pure-Swift / native-Apple media foundation (MIT). Open any container, decode
the native codec set, **normalize to native HEVC+AAC mp4**, probe without decoding — and **measure
what you made**: a pure-Swift (CPU + Metal) [SSIMULACRA2](https://github.com/cloudinary/ssimulacra2)
implementation drives *target-quality* encoding for both video and stills: the smallest file whose
perceptual score still clears a floor you chose. No FFmpeg, no `.unsafeFlags`, no vendored binaries,
no copyleft — net-distributable.

```
MediaImport   SupportGate (CodecID → native/deferred) + FormatDescriptionFactory +
              VTDecompressionSession / AudioConverter decode. Consumes matroska-swift's demuxer.
MediaBridge   normalize → native HEVC+AAC mp4 · lossless remux · probe · ShotDetector ·
              the external-decoder / external-alpha-encoder registries. The container surface.
ImageBridge   stills (ImageIO) + the FrameProcessor / ModelChain enhancement seam
              (process(CVPixelBuffer) → CVPixelBuffer — plug ML models into the frame path).
MediaMeasure  the measurement + target-quality engine: SSIMULACRA2 (CPU + Metal) · per-frame
              video scoring (p10-gated) · floor-targeted encode search (VideoQualityTarget,
              ImageQualityTarget) · GIF→mp4 · alpha/opaque video writers · fidelity guards ·
              temporal-consistency toolkit.
```

Products: `MediaBridge`, `ImageBridge`, `MediaMeasure`, and `MediaImport` (exposed so a separate
package can supply an external decoder — see the seam below).

## Install

```swift
.package(url: "https://github.com/xocialize/media-bridge.git", from: "0.27.0")
```

macOS 14+. Swift 6.2 toolchain (targets build in Swift 5 language mode).

## Quick tour

```swift
import MediaBridge
import MediaMeasure

// Probe — never decodes. Native containers via AVFoundation, MKV/WebM pure-Swift.
let info = try await MediaBridge.probe(url: url)

// Normalize anything the native set can decode → HEVC+AAC mp4.
let normalized = try await MediaBridge.normalizeVideoToHEVC(input: mkvURL, output: mp4URL)

// Target-quality video: the SMALLEST web H.264 whose 10th-percentile per-frame
// SSIMULACRA2 still clears 75. Bitrate is searched, quality is measured, the
// receipt states the guarantee.
let result = try await VideoQualityTarget.encode(
    input: source, output: webOut, targetScore: 75, profile: .webH264)
print(result.aggregation.summary)
// e.g. "p10 78.3 · min 64.2 · mean 86.1 · scored 16/1447 frames"

// Resolution-class downscale during the same search (4K → 1080p-class; the floor
// is measured AT the target resolution against a high-quality mezzanine).
let hd = try await VideoQualityTarget.encode(
    input: source, output: hdOut, targetScore: 75, maxHeight: 1080, profile: .webH264)

// Score any pair of clips, per-frame (synchronous; GPU when available).
let score = try VideoQuality.videoScore(reference: a, distorted: b)

// Stills: same idea, per format.
let heic = try ImageQualityTarget.encodeHEIC(image, targetScore: 80)
let jpeg = try ImageQualityTarget.encodeJPEG(image, targetScore: 80)

// Animated GIF → a real video mezzanine (browser timing conventions honored),
// ready for the target-quality search.
try await GIFVideo.renderMezzanine(input: gifURL, output: movURL)
```

## The quality model

**SSIMULACRA2** is the only score in the package — full-reference, perceptual, pure Swift, with a
runtime-compiled **Metal path** (~4× on 1080p frames, byte-identical search results; CPU fallback
when no Metal device). Rough calibration: 90+ ≈ visually lossless, 70 ≈ high quality, 50 ≈ visibly
degraded.

Video scores are **not** stills scores. A clip is scored per frame and gated on the **10th
percentile** — one bad scene can't hide behind a good mean — and the aggregation travels with the
number (`percentile / percentileScore / mean / minimum / framesScored / frameCount`) so a receipt
states *which* guarantee was made, not just a bare number. Sampling is adaptive: short clips are
scored densely enough that p10 can't collapse into a noisy min-of-3.

The search itself is bitrate-binary-search + refinement, followed by a **corridor squeeze** (one
extra candidate below the winner, adopted only if it still clears the floor and is strictly
smaller) and **near-gate re-scoring** (candidates landing within 1.5 of the floor are re-scored at
2× sampling before they're trusted). Floors are promises: `metTarget` and `delivered` report the
truth separately, and the profile — not the caller — owns the delivery rule.

## Encode profiles

The encoder knobs live **on the preset** so they can't be forgotten at a call site:

| | `.hevc` | `.webH264` | `.webH264Shrink` |
|---|---|---|---|
| Codec / audio | HEVC · passthrough | H.264 · AAC web-safe | H.264 · AAC web-safe |
| Use | native Apple deliverable | web *conversion* (always delivers) | already-web-native (shrink only) |
| Delivery rule | smaller only | larger OK · floor-miss → best-effort ceiling | strictly smaller |
| QP corridor (max/min) | 38 / 18 | 34 / 20 | 34 / 20 |
| Look-ahead | — | 16 frames (macOS 15+) | 16 frames |
| HDR handling | HDR preserved | tone-mapped to SDR BT.709 | tone-mapped to SDR BT.709 |
| Audio rung | passthrough | re-encode above 112 kb/s/channel | re-encode above 112 kb/s/channel |

Why a QP corridor: under ABR the encoder's rate model craters exactly the hard frames a p10 gate
watches. Clamping max QP forces bits into those frames at negligible size cost (measured: a
3240×1920 H.264 encode's worst frame 71.9 → 81.2 for +1.5% bytes); the min-QP side stops easy
scenes being over-polished — but a min QP caps achievable quality, so it rides only on the
post-search squeeze, never inside the search.

**The mezzanine pattern.** Downscaling, HDR→SDR tone-mapping, and GIF compositing all run **once**
into a near-lossless intermediate that becomes *both* the scoring reference and the search input.
That keeps the floor honest at the delivered resolution/gamut — and it is a deliberate property
that when reference and candidate share a rendering decision, the floor measures encode quality,
not the decision. Scaling uses a measured-good vImage Lanczos path; HDR→SDR uses
`VTPixelTransferSession` for color only (never its scaler).

## What it decodes / defers

- **Decodes natively (zero dependencies):**
  - Video — H.264, HEVC, AV1 (HW, M3+), MPEG-2, MPEG-1.
  - Audio — AAC, ALAC, FLAC, Opus, LPCM, AC-3, E-AC-3, MPEG audio (MP1/MP2/MP3).
  - AV1 and MPEG-1/2 are **runtime-gated** — availability is machine-dependent, so a host that
    can't actually create the decode session degrades to a clean `.deferred`, never a crash.
- **Defers (honestly — demux succeeds, decode surfaces as `.deferred(codecID)`, never a silent fail):**
  - **VP9 / VP8** — no native macOS decoder; re-enabled on demand via the external-decoder seam below.
  - **Vorbis** — no native path.
  - **DTS / TrueHD** — the only open decoders are GPL or nonexistent; deferred under the
    permissive-only bar.
- **Encodes:** HEVC / H.264 (VideoToolbox) + AAC (AudioToolbox); ProRes 4444 / HEVC-with-alpha via
  the alpha writers. No AV1/VP9 encode (VideoToolbox can't on Apple Silicon).

## External-decoder seam (VP9/VP8 without contaminating this package)

media-bridge stays **pure-Swift and binary-free** — but a consumer can opt into a deferred codec by
registering a decoder that lives in a **separate** package (so the binary encumbrance never enters
media-bridge). A registered decoder's frames flow through the **same** encode/mux path as native
decode; with nothing registered, a deferred codec defers exactly as before.

```swift
import MediaBridge
import VpxSwift   // github.com/xocialize/vpx-swift — libvpx (BSD-3), ~2.9 MB/arch

MediaBridge.register(externalDecoder: VpxVideoDecoder())   // once at startup
```

The seam is the `ExternalVideoDecoder` protocol (in `MediaImport`) +
`MediaBridge.register(externalDecoder:)` / `unregisterAllExternalDecoders()`. See
[`DEFERRED-CODEC-PLAN.md`](DEFERRED-CODEC-PLAN.md) §9.

## Observability

Set `MEDIABRIDGE_VT_LOG=/path/to/log` and every hardware encode writes one fsync'd breadcrumb line
**before** it starts and one on completion (knobs included). After a machine-level VideoToolbox
wedge, the last `START` without a matching `END` names the operation that was in flight — evidence
that survives a hard lock, which in-memory logging does not. Off (zero cost) unless the variable is
set.

## Requirements

macOS 14+ (native Opus floor). AV1 and MPEG-1/2 decode are runtime-gated. Metal SSIMULACRA2
engages automatically when a Metal device exists; everything falls back to CPU cleanly, so the
package is CI-safe on GPU-less runners.

## Related packages

- [`matroska-swift`](https://github.com/xocialize/matroska-swift) — the pure-Swift MKV/WebM demuxer
  media-bridge consumes.
- [`vpx-swift`](https://github.com/xocialize/vpx-swift) — optional VP9/VP8 via the external-decoder
  seam (BSD-3, lives outside this package on purpose).
- [`ForgeOptimizerKit`](https://github.com/xocialize/ForgeOptimizerKit) — the content-aware
  optimizer built on this package (presets, content classification, delivery receipts).

## License

MIT © 2026 xocialize. (An external decoder registered by a consumer carries its own license — e.g.
vpx-swift is BSD-3; media-bridge itself stays MIT / binary-free.)
