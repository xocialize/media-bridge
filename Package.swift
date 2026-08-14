// swift-tools-version: 6.2
import PackageDescription

// media-bridge — the FFmpeg-free, pure-Swift / native-Apple successor to format-bridge. The
// upstream media foundation: open any container, decode the native codec set, normalize/transcode
// to native HEVC/AAC mp4, probe, and measure quality (SSIMULACRA2). NO FFmpeg, no .unsafeFlags, no
// vendored binaries, no copyleft — net-distributable (MIT). See MEDIABRIDGE-PLAN.md.
//
//   MediaImport   SupportGate (CodecID → native/deferred) + FormatDescriptionFactory +
//                 VTDecompressionSession / AudioConverter decode sessions. Consumes MatroskaDemux.
//   MediaBridge   convert/normalize orchestration; native HEVC/H.264 + AAC encode; AVAssetWriter
//                 mux; probe; ShotDetector. The public surface.
//   ImageBridge   stills (ImageIO/oxipng/SSIMULACRA2/PDF/GIF) — salvaged from format-bridge.
//   MediaMeasure  SSIMULACRA2-video quality scoring (extends ImageBridge's SSIMULACRA2 per-frame).
let package = Package(
    name: "media-bridge",
    platforms: [.macOS(.v14)],          // native Opus floor; AV1/VP9 runtime-gated
    products: [
        .library(name: "MediaBridge", targets: ["MediaBridge"]),
        .library(name: "ImageBridge", targets: ["ImageBridge"]),
        .library(name: "MediaMeasure", targets: ["MediaMeasure"]),
        // The performance-measurement harness (span timeline + aggregation + Chrome-trace export).
        // Dependency-free; exposed so downstream layers (ForgeOptimizerKit, bench tools) record onto
        // the SAME process timeline as the bridge's own decode/encode/score spans.
        .library(name: "MediaMetrics", targets: ["MediaMetrics"]),
        // Exposed so a SEPARATE package (e.g. vpx-swift) can conform to `ExternalVideoDecoder` and
        // build `DecodedVideoFrame`s to hand back through `MediaBridge.register(externalDecoder:)` —
        // the binary-free seam for deferred codecs (VP9/VP8/…). See DEFERRED-CODEC-PLAN.md §9.
        .library(name: "MediaImport", targets: ["MediaImport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/xocialize/matroska-swift.git", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "MediaImport",
            dependencies: [.product(name: "MatroskaDemux", package: "matroska-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]   // CMSampleBuffer/CVPixelBuffer aren't Sendable
        ),
        // MediaMeasure carries the alpha-capable writers (ProRes 4444 / HEVC-with-alpha) that the
        // alpha-preserving normalize routes to. Acyclic — MediaMeasure's only dependency is the
        // dependency-free MediaMetrics harness (Foundation + os, no media frameworks).
        .target(name: "MediaBridge",
                dependencies: ["MediaImport", "MediaMeasure", "MediaMetrics",
                               .product(name: "MatroskaDemux", package: "matroska-swift")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "ImageBridge", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "MediaMeasure", dependencies: ["MediaMetrics"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // Zero dependencies — the leaf every layer may import (see MediaMetrics.swift header).
        .target(name: "MediaMetrics", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MediaBridgeTests",
                    dependencies: ["MediaBridge", "MediaImport", "MediaMeasure", "ImageBridge",
                                   "MediaMetrics",
                                   .product(name: "MatroskaDemux", package: "matroska-swift")]),
    ]
)
