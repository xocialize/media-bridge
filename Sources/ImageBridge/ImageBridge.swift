//
// ImageBridge.swift — ImageBridge
//
// Stills foundation: ImageIO decode/encode (PNG/JPEG/HEIC/AVIF/TIFF), PDF rasterizer, animated
// GIF/APNG → MP4, alpha split, oxipng lossless, SSIMULACRA2 scoring, still quality-target.
//
// Per the salvage audit this target is **100% FFmpeg-free in format-bridge (16/16 files clean)** and
// lifts wholesale in Phase 4 — including the COxipng C target. This stub is a placeholder; the real
// sources (ImageBridgeFactory, ImageIODecoder/Encoder, PDFRasterizer, OxipngOptimizer,
// StillOptimizer, SSIMULACRA2Scorer, …) are copied verbatim then re-pointed at MediaBridge's encoder.
//

import Foundation

public enum ImageBridge {
    public static let scaffolded = true
}
