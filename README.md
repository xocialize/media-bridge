# media-bridge

The **FFmpeg-free**, pure-Swift / native-Apple successor to `format-bridge` (MIT). An upstream media
foundation: open any container, decode the native codec set, **normalize/transcode to native
HEVC+AAC mp4**, probe, and measure quality (SSIMULACRA2). No FFmpeg, no `.unsafeFlags`, no vendored
binaries, no copyleft — net-distributable.

```
MediaImport   SupportGate (CodecID → native/deferred) + FormatDescriptionFactory +
              VTDecompressionSession / AudioConverter.  Consumes matroska-swift's MatroskaDemux.
MediaBridge   convert/normalize + native HEVC/H.264 + AAC encode + AVAssetWriter mux + probe +
              ShotDetector. The public surface.
ImageBridge   stills (ImageIO/oxipng/SSIMULACRA2/PDF/GIF) — salvaged 1:1 from format-bridge.
MediaMeasure  SSIMULACRA2-video quality (replaces the FFmpeg+libvmaf VMAF path).
```

## What it does / doesn't

- **Decodes natively:** H.264, HEVC, AV1 (M3+), AAC, ALAC, FLAC, Opus, LPCM.
- **Defers (honestly, never silently fails):** VP9/VP8, Vorbis, AC-3/E-AC-3, DTS, TrueHD, MPEG-1/2 —
  surfaced as `.deferred(codecID)`. A future per-codec fallback (dav1d/libvpx — BSD) slots behind
  the SupportGate as an optional `binaryTarget`; never FFmpeg again.
- **Encodes:** HEVC / H.264 (VideoToolbox) + AAC (AudioToolbox). **No** AV1/VP9 encode (VideoToolbox
  can't on Apple Silicon; both target apps output HEVC anyway).

## Status

Scaffold (Phase 0). Depends on [`matroska-swift`](../matroska-swift) by local path during dev (flips
to a versioned `github.com/xocialize` URL at Phase 5). The SupportGate is implemented; decode/encode
and the salvaged FormatBridge/ImageBridge surfaces land in Phases 2–4. See `MEDIABRIDGE-PLAN.md`.

## Requirements

macOS 14+ (native Opus floor); AV1/VP9 runtime-gated via `VTIsHardwareDecodeSupported`.

## License

MIT © 2026 xocialize.
