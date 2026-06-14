# media-bridge — CLAUDE.md

The **FFmpeg-free, pure-Swift / native-Apple** successor to `format-bridge` (MIT). Open any
container, decode the native codec set, normalize/transcode to native **HEVC+AAC mp4**, probe, and
measure quality. Targets:

- **`MediaImport`** — `SupportGate` (CodecID → native/deferred), `FormatDescriptionFactory`
  (CodecPrivate → `CMFormatDescription`), `VTDecompressionSession`/`AudioConverter` decode. Consumes
  `matroska-swift`'s `MatroskaDemux`. **CMTime conversion (ns→CMTime) happens here**, not in the demuxer.
- **`MediaBridge`** — convert/normalize orchestration, native HEVC/H.264 + AAC encode (AVAssetWriter),
  probe, ShotDetector. The public surface.
- **`ImageBridge`** — stills: ImageIO decode/encode (PNG/JPEG/HEIC/AVIF/TIFF), PDF rasterize, alpha
  split, tiled `FrameProcessor` AI-chain seam (`ModelChain` — how ForgeOptimizer injects
  Real-ESRGAN/NAFNet), decode→process→encode orchestrator. **Salvaged binary-free** — DROPPED on
  copy: `OxipngOptimizer`/`COxipng` (vendored 6.2 MB liboxipng .a), `SSIMULACRA2Scorer` (libjxl
  subprocess → use `MediaMeasure.SSIMULACRA2`), `StillQualityTarget`/`StillOptimizer` (redundant with
  `MediaMeasure.ImageQualityTarget`), `AnimatedToVideoConverter`+CLI (video-encode coupling). Quality-
  targeted still encode lives in `MediaMeasure.ImageQualityTarget` (pure SSIMULACRA2 oracle).
- **`MediaMeasure`** — SSIMULACRA2-video quality (replaces the FFmpeg+libvmaf VMAF path).

## Doctrine (see ../CLAUDE.md for the full rules)

- **No FFmpeg, ever** (no link, no subprocess). Native codec set only; non-native →
  `SupportGate.status(...) == .deferred` (surface, never silently fail).
- **AV1** (`V_AV1`) is `.nativeVideo` in the gate but must be **runtime-gated** by
  `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` at decode time (HW only, M3+). Build its
  format description manually (`av01` + `av1C` + sequence-header OBU — no convenience API).
- **H.264/HEVC:** `CMVideoFormatDescriptionCreateFrom{H264,HEVC}ParameterSets` from `codecPrivate`
  (avcC/hvcC); `nalUnitHeaderLength = lengthSizeMinusOne + 1` (≈4). Pass blocks through (AVCC).
- **Quality = SSIMULACRA2-video.** NOTE: the existing SSIMULACRA2 scorer is a **subprocess to libjxl's
  `ssimulacra2` binary** (brew jpeg-xl) — fine for optimizer/content-prep, but a pure-Swift/Metal port
  is needed for on-device scoring in a shipping player (tracked follow-up).

## Salvaging from format-bridge

Source: `/Volumes/DEV_VOL1/ffmpeg_refactor/format-bridge` (audit: 46 salvage / 5 rebuild / 3 drop —
plan §5). **SALVAGE** the encoders (NativeEncoder, VideoToolboxEncoder, Tier1Exporter), TierRouter,
ConversionOrchestrator (relink), ShotDetector, all Models/Protocols, and ImageBridge whole.
**REBUILD** the FFmpeg probe/decoder/PixelBufferConverter onto `MediaImport`. **DROP** FFmpegXC,
FFmpegAV1Encoder, FFmpegLogger. When lifting a file, strip all `import FFmpegXC` / `av*`/`sws*` calls.

## Conventions

- swift-tools **6.2**, macOS **14** floor (native Opus). `.swiftLanguageMode(.v5)` on every target
  (CVPixelBuffer/CMSampleBuffer aren't Sendable; the engine serializes lifecycle).
- Depends on `matroska-swift` by local `path:` until Phase 5 (then versioned `github.com/xocialize` URL).
- `MediaImport` is an internal target (not a product yet); the test target depends on it by name.

## Build / test

```
swift build && swift test
```

## Status & next

Phase 0 scaffold (SupportGate matrix done + tested). **Phase 2 next**: FormatDescriptionFactory +
VTDecompressionSession/AudioConverter for H.264/HEVC + AAC/FLAC, then an MKV→HEVC transcode e2e.
Plan: `/Volumes/DEV_VOL1/ffmpeg_refactor/MEDIABRIDGE-PLAN.md`.
