# media-bridge

The **FFmpeg-free**, pure-Swift / native-Apple successor to `format-bridge` (MIT). An upstream media
foundation: open any container, decode the native codec set, **normalize/transcode to native
HEVC+AAC mp4**, probe, and measure quality (SSIMULACRA2). No FFmpeg, no `.unsafeFlags`, no vendored
binaries, no copyleft — net-distributable.

```
MediaImport   SupportGate (CodecID → native/deferred) + FormatDescriptionFactory +
              VTDecompressionSession / AudioConverter.  Consumes matroska-swift's MatroskaDemux.
MediaBridge   convert/normalize + native HEVC/H.264 + AAC encode + AVAssetWriter mux + probe +
              ShotDetector + the external-decoder registry. The public surface.
ImageBridge   stills (ImageIO/oxipng/SSIMULACRA2/PDF/GIF) — salvaged 1:1 from format-bridge.
MediaMeasure  SSIMULACRA2-video quality (replaces the FFmpeg+libvmaf VMAF path).
```

Products: `MediaBridge`, `ImageBridge`, `MediaMeasure`, and `MediaImport` (exposed so a separate
package can supply an external decoder — see below).

## What it does / doesn't

- **Decodes natively (zero dependencies):**
  - Video — H.264, HEVC, AV1 (HW, M3+), MPEG-2, MPEG-1.
  - Audio — AAC, ALAC, FLAC, Opus, LPCM, AC-3, E-AC-3, MPEG audio (MP1/MP2/MP3).
  - AV1 and MPEG-1/2 are **runtime-gated** — availability is machine-dependent, so a host that can't
    actually create the decode session degrades to a clean `.deferred`, never a crash.
- **Defers (honestly — demux succeeds, decode is surfaced as `.deferred(codecID)`, never a silent fail):**
  - **VP9 / VP8** — no native macOS decoder (`VTDecompressionSessionCreate` → `-12906` on Apple Silicon)
    and no pure-Swift decoder exists. **Re-enabled on demand via the external-decoder seam** (below).
  - **Vorbis** — no native path; planned via a permissive vendored decoder (bundled with the VP9 effort).
  - **DTS / TrueHD** — only open decoders are GPL / non-existent; stay deferred under the permissive-only bar.
- **Encodes:** HEVC / H.264 (VideoToolbox) + AAC (AudioToolbox). **No** AV1/VP9 encode (VideoToolbox
  can't on Apple Silicon; both target apps output HEVC anyway).

## External-decoder seam (VP9/VP8 without contaminating this package)

media-bridge stays **pure-Swift and binary-free** — but a consumer can opt into a deferred codec by
registering a decoder that lives in a **separate** package (so the binary encumbrance never enters
media-bridge). A registered decoder's frames flow through the **same** HEVC-encode/mux path as native
decode; with nothing registered, a deferred codec defers exactly as before (zero behavior change).

```swift
import MediaBridge
import VpxSwift   // github.com/xocialize/vpx-swift — decode-only libvpx (BSD-3), ~1 MB/arch

// Once at startup. Now VP9/VP8 WebM/MKV normalize transparently.
MediaBridge.register(externalDecoder: VpxVideoDecoder())
```

The seam is the `ExternalVideoDecoder` protocol (in `MediaImport`) +
`MediaBridge.register(externalDecoder:)` / `unregisterAllExternalDecoders()`. See
[`DEFERRED-CODEC-PLAN.md`](DEFERRED-CODEC-PLAN.md) §9. This is why the deferral path is "honest, never
silent" — it's a live plug-in point, not a dead end.

## Status

Working. Latest tag **`v0.3.0`**. Depends on
[`matroska-swift`](https://github.com/xocialize/matroska-swift) by versioned URL (`from: "0.1.0"`).

Implemented: the any-container → native HEVC+AAC normalizer (native-container fast path via
`AVAssetExportSession`; MKV/WebM via the pure-Swift demuxer → VideoToolbox/AudioToolbox decode → encode,
memory-bounded), the deferred-codec re-enable phases (native AC-3/E-AC-3/MPEG-audio + MPEG-1/2 video),
the external-decoder seam, `MediaBridge.probe`, `ImageBridge` stills, and a pure-Swift `SSIMULACRA2`
with quality-targeted encode.

## Requirements

macOS 14+ (native Opus floor). AV1 and MPEG-1/2 decode are runtime-gated (HW / machine-dependent).

## License

MIT © 2026 xocialize. (An external decoder registered by a consumer carries its own license — e.g.
vpx-swift is BSD-3; media-bridge itself stays MIT / binary-free.)
