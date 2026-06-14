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

Working. Depends on [`matroska-swift`](https://github.com/xocialize/matroska-swift) by versioned URL
(`from: "0.1.0"`). Implemented: the any-container→native HEVC+AAC normalizer (native-container fast
path via `AVAssetExportSession`; MKV/WebM via the pure-Swift demuxer → VideoToolbox/AudioToolbox decode
→ encode, memory-bounded), `MediaBridge.probe`, `ImageBridge` stills, and a pure-Swift `SSIMULACRA2`
with quality-targeted encode. Native codecs: H.264 / HEVC / AV1 (M3+) video, AAC / Opus audio.

## Requirements

macOS 14+ (native Opus floor); AV1/VP9 runtime-gated via `VTIsHardwareDecodeSupported`.

## License

MIT © 2026 xocialize.
