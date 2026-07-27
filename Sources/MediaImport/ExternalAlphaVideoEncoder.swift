//
// ExternalAlphaVideoEncoder.swift — MediaImport
//
// The WRITE-side mirror of `ExternalVideoDecoder`: a pluggable encoder for a transparent delivery
// format media-bridge cannot produce natively.
//
// Transparent video on the web has exactly two delivery formats, and they split by platform:
//
//   Apple / Safari          .mov + HEVC-with-alpha   — media-bridge writes this itself
//                                                      (`AlphaVideoWriter`, via AVAssetWriter)
//   Chrome / Firefox / Edge .webm + VP9-with-alpha    — needs a VP9 encoder, so it needs a binary
//
// The second one is the reason this protocol exists. AVFoundation has no VP9 encoder, and the only
// implementation is libvpx — a binary media-bridge deliberately does not carry. Same demarcation as
// the decode side: the codec binary lives entirely in the registered package (`vpx-swift`), and
// media-bridge stays pure-Swift. With nothing registered, asking for a WebM export fails honestly
// rather than silently writing something opaque.
//
// Register with `MediaBridge.register(externalAlphaEncoder:)`.
//

import CoreVideo
import Foundation

/// A transparent-video delivery format.
public enum TransparentVideoFormat: String, Sendable, CaseIterable {
    /// `.webm` + VP9-with-alpha — the only transparent format non-Apple browsers accept. Alpha is a
    /// second VP9 stream in Matroska `BlockAdditional`; requires an external encoder.
    case webmVP9Alpha
    /// `.mov` + HEVC-with-alpha — Apple platforms. Written natively; note that **no mp4
    /// configuration carries alpha**, `hevcWithAlpha` included, so the container change is genuine.
    case movHEVCAlpha
    /// `.mov` + ProRes 4444 — an intermediate, not a delivery format (measured ~23x larger than
    /// HEVC-with-alpha for the same content). Written natively.
    case movProRes4444

    /// Whether media-bridge can write this itself. `false` means it needs a registered encoder.
    public var isNative: Bool { self != .webmVP9Alpha }

    public var fileExtension: String { self == .webmVP9Alpha ? "webm" : "mov" }
}

public protocol ExternalAlphaVideoEncoder: Sendable {
    /// Whether this encoder writes the given format.
    func canWrite(_ format: TransparentVideoFormat) -> Bool

    /// Write `width × height` BGRA frames to `output` in `format`, returning the number of frames
    /// written.
    ///
    /// Pull-based, matching `AlphaVideoWriter`: `nextFrame` returns the next frame in presentation
    /// order, or `nil` at end. Supply a real `ptsNanos` wherever one exists — synthesizing
    /// `index × step` silently retimes variable-frame-rate sources, and screen and browser capture
    /// (exactly the sources that carry alpha) are commonly VFR. `frameRate` is the fallback for
    /// frames that supply no PTS.
    ///
    /// The frames carry **straight, not premultiplied** alpha: a player composites `colour × alpha`
    /// itself, so premultiplied colour renders semi-transparent pixels twice as dark.
    @discardableResult
    func write(to output: URL,
               format: TransparentVideoFormat,
               width: Int,
               height: Int,
               frameRate: Double,
               nextFrame: () async throws -> (buffer: CVPixelBuffer, ptsNanos: Int64?)?) async throws -> Int
}
