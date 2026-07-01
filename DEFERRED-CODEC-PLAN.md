# Deferred-Codec Re-Enable Plan (permissive-clean, native-first)

**Status:** planned · 2026-07-01
**Scope:** widen MediaImport's decode front-door for codecs currently `.deferred` by `SupportGate`,
without ever reintroducing FFmpeg and without any GPL/LGPL dependency.
**Doctrine:** native Apple decoders first (zero dependency); a *permissive* (BSD/MIT/Apache/PD) library
only where no native path exists; honest `.deferred` for everything else. See the research verdict in
memory `mediabridge-deferred-codec-decode-paths` and the rebuild history in `MEDIABRIDGE-PLAN.md`.

**Progress:** Phase 0 ✅ DONE (encoder stall guard + tests). Phase A ✅ DONE (AC-3/E-AC-3/MP2/MP3
decode natively, e2e green). Gotcha found in A: the normalizer's audio-track selector required
`codecPrivate != nil`, but AC-3/E-AC-3/MPEG audio are cookie-less — added
`AudioDecodeSession.requiresCodecPrivate(codecID:)` and gated the guard on it.
Phase B ⛔ VP9 STAYS DEFERRED — **the research's "native VP9" verdict was WRONG for Apple Silicon**
(empirically verified 2026-07-01, see §4). Two keepers landed anyway: a router extension-gate fix and a
graceful session-create → deferral catch. Phase D ✅ DONE — **MPEG-2 AND MPEG-1 video decode natively**
(VideoToolbox's legacy decoder IS present on Apple Silicon / macOS 27, unlike VP9; e2e green). Phase C
(Vorbis) DEFERRED by decision — bundle with a future libvpx phase (VP9 cascade gutted its near-term value).

---

## 1. Verdict table

| Codec | Matroska ID | Verdict | Mechanism | New dep? |
|---|---|---|---|---|
| AC-3 | `A_AC3` | ✅ native audio | AudioToolbox `kAudioFormatAC3` (macOS 10.2+) | none |
| E-AC-3 | `A_EAC3` | ✅ native audio | AudioToolbox `kAudioFormatEnhancedAC3` (macOS 10.11+) | none |
| MP2 | `A_MPEG/L2` | ✅ native audio | AudioToolbox `kAudioFormatMPEGLayer2` | none |
| MP3 | `A_MPEG/L3` | ✅ native audio | AudioToolbox `kAudioFormatMPEGLayer3` | none |
| MP1 | `A_MPEG/L1` | ✅ native audio | AudioToolbox `kAudioFormatMPEGLayer1` | none |
| VP9 | `V_VP9` | ❌ stays deferred | **NO native decoder on Apple Silicon** — VTDecompressionSessionCreate → -12906 (verified). libvpx (BSD) is the only path | (libvpx) |
| MPEG-2 video | `V_MPEG2` | ✅ native video | VideoToolbox `kCMVideoCodecType_MPEG2Video` — legacy decoder present (verified) | none |
| Vorbis | `A_VORBIS` | ✅ permissive lib | vendored `stb_vorbis` (public-domain/MIT) | 1 vendored C file |
| VP8 | `V_VP8` | ⏸️ skip | `libvpx` (BSD) exists, but VP8 ~extinct — add on demand only | (libvpx) |
| MPEG-1 video | `V_MPEG1` | ✅ native video | VideoToolbox `kCMVideoCodecType_MPEG1Video` (verified) | none |
| DTS | `A_DTS` | ❌ stays deferred | only decoder is `libdca` (**GPL**) — no permissive path | — |
| TrueHD | `A_TRUEHD` | ❌ stays deferred | no permissive decoder (`domyd/mlp` is a demuxer) | — |

**Net:** Phases A + B bring back AC-3/E-AC-3/MP1/2/3 + VP9 with **zero dependencies**. Phase C adds
Vorbis with one vendored public-domain file. DTS/TrueHD cannot move without relaxing the license bar.

---

## 2. Key architectural findings (grounding)

Established by reading the current sources:

- **`AudioDecodeSession.swift`** is already a `switch codecID` → `(AudioFormatID, framesPerPacket,
  inputRate, inBits)` feeding a generic `AudioConverter` → Int16 PCM pipeline. Adding a codec = adding
  a `switch` case + one `isSupported` clause. AC-3/E-AC-3/MP1/2/3 need **no magic cookie** (simpler
  than AAC/FLAC, which do).
- **`VideoDecodeSession.swift`** `makeSampleBuffer(avcc:)` is **codec-agnostic** — it wraps raw packet
  bytes in a `CMBlockBuffer` against the format description; it does no AVCC-specific parsing. VP9 and
  MPEG-2 Matroska blocks are self-contained frames, so **the decode session needs no changes**. All
  per-codec work is in `FormatDescriptionFactory` + the runtime gate.
- **`SupportGate.swift`** is a static `CodecID → SupportStatus` switch. AV1 sets the precedent:
  reported `.nativeVideo` statically, then *runtime-gated at decode time*. VP9/MPEG-2 follow the same
  shape — **but with a critical difference (§4.1).**
- **Tests** generate fixtures at runtime with `ffmpeg` (dev-time tool, never shipped) and `XCTSkip`
  when it's absent. `SupportGateTests.testDeferredCodecs` currently asserts all 9 codecs `.deferred` —
  each phase flips the relevant assertions.

---

## 2a. Phase 0 — Encoder stall guard (PREREQUISITE, cross-package)

**Why this comes first.** `frame-stream-native` commit `a80c26e` (2026-07-01) fixed the hardware
VideoToolbox media engine stalling when it encodes right after heavy MLX GPU compute
(`isReadyForMoreMediaData` goes false and never recovers). media-bridge's `NativeMP4Writer` has the
**same two defects** and is *more* exposed by this plan: every codec we re-enable funnels through
`normalizeVideoToHEVC → NativeMP4Writer`, whose primary consumer (ForgeOptimizer) encodes right after
MLX inference. Widening decode without this guard = decode succeeds, then the encoder hangs forever in
the real pipeline.

Current defects in `Sources/MediaBridge/NativeMP4Writer.swift`:
- **Hardware-default encoder** (line ~31): `AVVideoCodecKey: .hevc` with no `AVVideoEncoderSpecificationKey`.
- **Unbounded readiness wait** (`waitReady`, ~line 92): `while !input.isReadyForMoreMediaData { sleep }`
  with no timeout — a genuine stall spins at ~0% CPU forever and looks like a hang.

**Fix — mirror `frame-stream-native`'s `NativeFrameStream.run(software:)` exactly:**
- Default `NativeMP4Writer` to a **software-only** HEVC encoder via string-form encoder-spec keys (no
  VideoToolbox import): `AVVideoEncoderSpecificationKey: ["EnableHardwareAcceleratedVideoEncoder": false,
  "RequireSoftwareOnlyVideoEncoder": true]`. Preserve BT.709 tagging.
- Opt-out for pure-transcode callers that are NOT post-MLX (`software: false` init arg + env
  `MEDIABRIDGE_ENCODE=hardware`; `MEDIABRIDGE_ENCODE=software` forces it) — matches the sibling's
  `FRAMESTREAM_ENCODE` contract.
- **Bound `waitReady`** (~90s) → throw a new `WriterError.encoderStalled(String)` with the same
  diagnostic message shape (software-vs-hardware, output frame index) instead of hanging.
- Test both encoder paths write a valid MP4 (`asset.load(.tracks)` returns `vide`).

Small, well-understood, and unblocks A–D. Do it before Phase A.

---

## 3. Phase A — Native audio: AC-3 / E-AC-3 / MP1 / MP2 / MP3  (DO FIRST after Phase 0)

Highest value, lowest effort, zero dependency. AudioToolbox has decoded these since well below the
macOS 14 floor, so they are **statically native** — no runtime gate.

**A1 — `AudioDecodeSession` switch cases.** Add to the `switch codecID`:
```
case "A_AC3":      formatID = kAudioFormatAC3;             framesPerPacket = 1536; inputRate = sampleRate
case "A_EAC3":     formatID = kAudioFormatEnhancedAC3;     framesPerPacket = 1536; inputRate = sampleRate  // nominal; converter derives variable blocks
case "A_MPEG/L3":  formatID = kAudioFormatMPEGLayer3;      framesPerPacket = 1152; inputRate = sampleRate
case "A_MPEG/L2":  formatID = kAudioFormatMPEGLayer2;      framesPerPacket = 1152; inputRate = sampleRate
case "A_MPEG/L1":  formatID = kAudioFormatMPEGLayer1;      framesPerPacket = 384;  inputRate = sampleRate
```
No cookie block needed (leave `inBits = 0`; these are not lossless). The existing cookie-set at the end
is guarded by `codecPrivate != nil`, and these carry none — safe.

**A2 — `isSupported`.** Extend to include the five IDs above.

**A3 — De-risk the `'bada'` precedent.** FLAC failed `AudioConverterNew` with `'bada'`. AC-3/MP2/MP3
are *first-class* AudioToolbox decoders (FLAC is the corner case), so they should behave like AAC/Opus.
But add a targeted unit test that constructs each `AudioDecodeSession` and asserts `AudioConverterNew`
succeeds; if any returns `'bada'`, fall back to the file-based `ExtAudioFile`/`AVAudioFile` detour
(the same escape hatch FLAC needs — a separate `FileAudioDecodeSession`).

**A4 — `SupportGate`.** Move the five IDs into the `.nativeAudio` group (static). Add a `case "A_MPEG/L2", "A_MPEG/L3", "A_MPEG/L1"` and `case "A_AC3", "A_EAC3"`.

**A5 — Tests.** In `SupportGateTests`: move the five out of `testDeferredCodecs` into `testNativeAudioCodecs`.
Add an e2e (`ffmpeg -c:a ac3` / `-c:a mp2`) MKV → `normalizeVideoToHEVC` → verify with
`asset.load(.tracks)` returns a `soun` track (NOT ffprobe alone — per the rebuild lesson, ffprobe is
too lenient). Add an E-AC-3 fixture too (`-c:a eac3`).

---

## 4. Phase B — VP9  ⛔ INVESTIGATED → STAYS DEFERRED (verified 2026-07-01)

**The research's "RE-ENABLE via native" verdict does NOT hold on Apple Silicon.** Empirically, on this
M-series machine (macOS 27.0):
- `VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)` = **false** (no HW block — expected).
- `VTDecompressionSessionCreate` for a VP9 format description → **-12906 `kVTCouldNotFindVideoDecoderErr`**,
  both with and without a synthesized `vpcC` atom. There is **no software VP9 decoder** exposed to
  `VTDecompressionSession` (the API `VideoDecodeSession` uses).
- `AVAssetReader`/`AVURLAsset.loadTracks` returns **no video track** for the VP9 WebM — AVFoundation
  won't decode it either.

This reconciles with the research's own signals: the *confirmed* claim was that Apple's docs make **no
statement** that VideoToolbox decodes VP9; only an *unverified* Wikipedia line claimed "macOS 11 VP9,"
which refers to **Safari's private/internal** playback path, not a third-party-creatable decoder. On
Apple Silicon, VP9 VideoToolbox decode has never been available to `VTDecompressionSession` callers.

**Verdict:** VP9 stays `.deferred`. The only re-enable path is the permissive **`libvpx` (BSD)** as an
optional binaryTarget — itself deferred until a concrete consumer needs it (§7). VP9 WebM now demuxes
and cleanly surfaces `.deferredCodec("V_VP9")` rather than erroring.

**Two keepers landed during this investigation (both correct independent of VP9):**
1. **Router extension-gate** (`normalizeNativeContainer`): the native AVAssetExportSession fast-path is
   now gated on a genuinely-native container extension (`mp4/mov/m4v/qt`), not on `loadTracks` success.
   Modern macOS can *partially* read some non-native containers (returning a track) but then fail to
   transcode them — MKV/WebM must deterministically take the pure-Swift demux path. Mirrors
   frame-stream-native's `nativeExtensions`.
2. **Graceful session-create catch** (normalizer): `VideoDecodeSession.DecodeError.sessionCreate` →
   `NormalizeError.deferredCodec` instead of a crash. This is the runtime capability probe reused by
   Phase D (MPEG-2, whose availability is likewise machine-dependent).

*(Original B1–B4 native-VP9 tasks removed — the premise they rested on is false on Apple Silicon, per
the verification above. If VP9 is ever needed, it's the `libvpx` binaryTarget in §7, not a native path.)*

---

## 5. Phase C — Vorbis via vendored `stb_vorbis`  (DO THIRD)

Medium value (pairs with VP9 in WebM). The one genuinely fiddly item.

**C1 — Vendor, don't link.** Add `stb_vorbis.c` (public-domain/MIT, single file) as a new **C target**
`CVorbis` in `Package.swift`, wrapped by a small Swift target `VorbisSupport`. Vendoring PD source is
cleaner than a binaryTarget and keeps the net binary-free (consistent with dropping oxipng/libjxl in the
rebuild). Gate compilation behind a package trait/flag if excludability is wanted; otherwise always-on
(it's ~1 file).

**C2 — The Matroska wrinkle (not Ogg-framed).** `A_VORBIS` `CodecPrivate` is **xiph-laced**
`[id header][comment header][setup header]` (lacing = a count byte, then per-header lengths as
255-summed bytes), and block packets are **raw Vorbis** (no Ogg pages). Use `stb_vorbis`'s **pushdata
API** (`stb_vorbis_open_pushdata` + `stb_vorbis_decode_frame_pushdata`): parse the lacing to split the
3 setup headers, initialize with them, then decode each block packet → float → interleaved Int16 to
match `AudioDecodeSession.PCM`.

**C3 — Fallback if pushdata fights the header handoff.** `stb_vorbis` is Ogg-oriented; if feeding raw
Matroska headers proves painful, swap to `vorbis-swift` (BSD libvorbis) whose conventional
`vorbis_synthesis_headerin` path handles this directly. Try `stb_vorbis` first (smaller footprint).

**C4 — `SupportGate` + tests.** Report `A_VORBIS` `.nativeAudio` when `VorbisSupport` is compiled in
(`#if canImport(VorbisSupport)`), else `.deferred`. e2e: `ffmpeg -c:a libvorbis` in WebM/MKV → PCM →
mux. Move `A_VORBIS` out of `testDeferredCodecs` (guarded by the same compile flag).

---

## 6. Phase D — MPEG-2 (and MPEG-1) video  ✅ DONE — NATIVE (verified 2026-07-01)

**Both MPEG-2 and MPEG-1 decode natively** on this Apple Silicon machine (macOS 27) — VideoToolbox's
legacy decoder is present (unlike VP9). `V_MPEG2`/`V_MPEG1` are `.nativeVideo`; the normalizer's
session-create probe handles a host that lacks the decoder by degrading to a clean `.deferredCodec`
(the test `XCTSkip`s in that case). e2e green: MPEG-1/2 MKV → native HEVC. Implementation notes below.


**D1 — `FormatDescriptionFactory.makeVideo`.** Add `V_MPEG2` → `kCMVideoCodecType_MPEG2Video` and
`V_MPEG1` → `kCMVideoCodecType_MPEG1Video`, dimensions from track; Matroska CodecPrivate carries the
sequence header (may be needed — test with and without).

**D2 — Probe on the Apple-Silicon min-target.** Same session-create gate as VP9. **If create succeeds
→ support; if it fails → leave `.deferred` permanently** — there is **no permissive fallback** (libmpeg2
/ liba52 are GPL). Cheap to attempt; binary outcome. Document the result either way.

---

## 7. Explicitly NOT doing

| Codec | Reason |
|---|---|
| **VP8** (`V_VP8`) | `libvpx` (BSD) works, but VP8 is effectively extinct. Add the target only when a concrete asset demands it — one binaryTarget then covers VP8 + a VP9 pre-11 fallback. |
| **DTS** (`A_DTS`) | Only open decoder is `libdca` (**GPL**). No BSD/MIT DTS decoder exists. Stays `.deferred`. |
| **TrueHD** (`A_TRUEHD`) | No permissive decoder at all. `domyd/mlp` (MIT/Apache) is a demuxer, not a PCM decoder. Stays `.deferred`. |

DTS/TrueHD are not a research gap — they are a license-bar decision. They can only be revisited if the
permissive-only constraint is relaxed to allow LGPL dynamic linking.

---

## 8. Suggested sequencing & effort

0. **Phase 0** — encoder stall guard. S. Prerequisite; mirrors `frame-stream-native` `a80c26e`. Do first.
1. **Phase A** — native audio. S–M. Reuses the `AudioConverter` path wholesale. Biggest coverage win.
2. ~~**Phase B** — native VP9.~~ ⛔ Not possible on Apple Silicon (§4). Path is the libvpx seam (§9).
3. **Phase C** — Vorbis. M–L. DEFERRED — bundle with the libvpx package (§9) so one binary unlocks WebM.
4. **Phase D** — MPEG-2 probe. ✅ DONE — native.

Encode side is unchanged throughout — every path still normalizes to **HEVC + AAC**. This plan only
widens what the front-door will accept.

---

## 9. External-decoder seam + libvpx package (the VP9/VP8/Vorbis path)

VP9 has **no native macOS decoder** (§4) and **no pure-Swift decoder exists** — the only option is
`libvpx` (BSD-3 + PATENTS grant, actively maintained), a vendored binary. Unlike oxipng (dropped because
a pure-Swift equivalent existed to hold out for), there is no alternative here, so the question isn't
*whether* to accept the binary but *where to put it* — and the answer is **not in media-bridge**.

### Step 1 — the seam ✅ DONE (binary-free, in media-bridge)

`ExternalVideoDecoder` (protocol, `MediaImport`) + `MediaBridge.register(externalDecoder:)` /
`unregisterAllExternalDecoders()` (registry) + a hand-off in `normalizeMatroska`: when a codec is
`.deferred`, the normalizer consults the registry; a registered decoder produces `DecodedVideoFrame`s
that flow through the **same** HEVC-encode/mux path as native decode. With nothing registered, behavior
is byte-for-byte unchanged (the codec defers). media-bridge stays **pure-Swift, zero binaries**. Proven
end-to-end by `ExternalDecoderTests` with a pure-Swift fake VP9 decoder — register rescues VP9, unregister
restores the deferral. 64 tests green.

### Step 2 — `vpx-swift` package (the quarantine, NOT YET BUILT)

A **separate** package (ships open in `MetalToolBox/PROD`, alongside matroska-swift) that carries ALL the
binary encumbrance and conforms to `ExternalVideoDecoder`:
- Build upstream libvpx **VP9(+VP8)-decode-only** (`--disable-vp8_encoder --disable-vp9_encoder
  --disable-examples --disable-docs`, ~1–2 MB/arch) for arm64(+x86_64) macOS → `.xcframework` → SPM
  `binaryTarget`. **No usable prebuilt exists** (`denghe/libvpx_prebuilt` is Android/Windows, dead) — build our own.
- Thin Swift C-interop wrapper: `vpx_codec_dec_init(vpx_codec_vp9_dx())` → `vpx_codec_decode(pkt)` →
  `vpx_codec_get_frame()` → I420 `vpx_image_t` (the `examples/simple_decoder.c` surface).
- `vImage` I420→BGRA `CVPixelBuffer` → emit `DecodedVideoFrame` per the protocol. We already demux WebM
  (matroska-swift), so **libwebm is NOT needed** — decoder only.
- **The FFmpeg lesson:** keep it small — decode-only config, one codec family, no encoder/tools. The
  ~100 MB FFmpeg mess came from linking everything; a VP9-decode-only libvpx is a couple MB per arch.

### Step 3 — wire into a consumer (e.g. Forge Erase)

The consumer depends on `media-bridge` **and** `vpx-swift`, and calls
`MediaBridge.register(externalDecoder: VpxDecoder())` once at startup → **transparent WebM** (Forge Erase
use case). Consumers that don't need VP9 depend on media-bridge alone and stay binary-free. Bundle Vorbis
(Phase C) into the same package effort so one binary unlocks the whole WebM stack (VP8 + VP9 + Vorbis).

**License containment:** media-bridge stays MIT-pure; only a consumer that links `vpx-swift` accepts
BSD-3 + the libvpx PATENTS grant.
