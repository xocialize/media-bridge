//
// RGBA8Image.swift — MediaMeasureCore
//
// The plain-pixels currency of the pure metric core: 8-bit RGBA, **tightly packed**
// (`bytesPerRow == width * 4`), sRGB-encoded, alpha ignored by every consumer here.
//
// It exists so SSIMULACRA2 can score without CoreGraphics. On Apple platforms `MediaMeasure`
// rasterizes a `CGImage` into exactly this layout — sRGB colour space, `noneSkipLast` — and the
// numbers are unchanged, because that rasterization is byte-for-byte what the CGImage path always
// did internally. In a browser the same bytes arrive from `ImageData`/`VideoFrame` with no
// rasterization at all.
//
// Alpha note: SSIMULACRA2 reads only R, G and B. A transparent source is therefore scored as if
// composited over whatever the caller left in the colour channels — the same behaviour the Apple
// path has always had, and the reason the Kit refuses alpha video at probe time rather than
// trusting a quality gate to catch it (see `AB-L-0098`).
//

public struct RGBA8Image: Sendable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes, row-major, R,G,B,A.
    public let pixels: [UInt8]

    /// Fails when `pixels` is not exactly `width * height * 4` bytes, so a stride mistake is a
    /// construction error rather than a silently wrong score.
    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}
