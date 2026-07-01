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
        // Exposed so a SEPARATE package (e.g. vpx-swift) can conform to `ExternalVideoDecoder` and
        // build `DecodedVideoFrame`s to hand back through `MediaBridge.register(externalDecoder:)` —
        // the binary-free seam for deferred codecs (VP9/VP8/…). See DEFERRED-CODEC-PLAN.md §9.
        .library(name: "MediaImport", targets: ["MediaImport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/xocialize/matroska-swift.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "MediaImport",
            dependencies: [.product(name: "MatroskaDemux", package: "matroska-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]   // CMSampleBuffer/CVPixelBuffer aren't Sendable
        ),
        .target(name: "MediaBridge",
                dependencies: ["MediaImport",
                               .product(name: "MatroskaDemux", package: "matroska-swift")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "ImageBridge", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "MediaMeasure", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MediaBridgeTests",
                    dependencies: ["MediaBridge", "MediaImport", "MediaMeasure", "ImageBridge",
                                   .product(name: "MatroskaDemux", package: "matroska-swift")]),
    ]
)
