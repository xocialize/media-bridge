import CoreGraphics
import CoreVideo
import Foundation

// PDF input (PRD §3). CGImageSource can't open PDF, so PDF gets its own CoreGraphics
// path (no PDFKit dependency). Vector input has no intrinsic pixel size, so each page
// is rasterized at a target DPI (PDF user space = 72 units/inch). Multi-page → one
// frame per page (a sequence; PRD §7). PDFs carry no alpha — pages flatten onto opaque
// white, the typical document background. Output is premultiplied 32BGRA, matching the
// ImageIO decode path so the rest of the chain is format-blind.
enum PDFRasterizer {

    /// Sensible default for signage source docs (crisp at typical viewing size without
    /// exploding print-res buffers). Configurable via the decoder/probe init.
    static let defaultDPI: Double = 150

    static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }

    static func decode(url: URL, dpi: Double) throws -> (frames: [CVPixelBuffer], metadata: StillMetadata) {
        guard let doc = CGPDFDocument(url as CFURL) else {
            throw ImageBridgeError.decodeFailed("CGPDFDocument(\(url.lastPathComponent))")
        }
        let pages = doc.numberOfPages
        guard pages > 0 else { throw ImageBridgeError.decodeFailed("empty PDF") }

        var frames: [CVPixelBuffer] = []
        frames.reserveCapacity(pages)
        for i in 1 ... pages {
            guard let page = doc.page(at: i) else { throw ImageBridgeError.decodeFailed("PDF page \(i)") }
            frames.append(try rasterize(page, dpi: dpi))
        }
        let (w, h) = dimensions(doc.page(at: 1)!, dpi: dpi)
        let meta = StillMetadata(format: .pdf, width: w, height: h, bitDepth: 8, alpha: .none,
                                 iccProfile: nil, dpi: dpi, exifOrientation: 1, frameCount: pages)
        return (frames, meta)
    }

    static func probe(url: URL, dpi: Double) throws -> StillMetadata {
        guard let doc = CGPDFDocument(url as CFURL) else {
            throw ImageBridgeError.decodeFailed("CGPDFDocument(\(url.lastPathComponent))")
        }
        let pages = doc.numberOfPages
        guard pages > 0, let page = doc.page(at: 1) else { throw ImageBridgeError.decodeFailed("empty PDF") }
        let (w, h) = dimensions(page, dpi: dpi)
        return StillMetadata(format: .pdf, width: w, height: h, bitDepth: 8, alpha: .none,
                             iccProfile: nil, dpi: dpi, exifOrientation: 1, frameCount: pages)
    }

    // MARK: - private

    /// Pixel dimensions of a page at `dpi`, accounting for the crop box + the page's
    /// own /Rotate (a 90°/270° page swaps width/height).
    private static func dimensions(_ page: CGPDFPage, dpi: Double) -> (Int, Int) {
        let scale = dpi / 72.0
        let box = page.getBoxRect(.cropBox)
        let swap = page.rotationAngle % 180 != 0
        let w = (swap ? box.height : box.width) * scale
        let h = (swap ? box.width : box.height) * scale
        return (max(1, Int(w.rounded())), max(1, Int(h.rounded())))
    }

    private static func rasterize(_ page: CGPDFPage, dpi: Double) throws -> CVPixelBuffer {
        let (w, h) = dimensions(page, dpi: dpi)
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
                == kCVReturnSuccess, let buffer = pb else {
            throw ImageBridgeError.decodeFailed("CVPixelBufferCreate \(w)x\(h)")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw ImageBridgeError.decodeFailed("lock PDF buffer")
        }
        // 32BGRA == little-endian premultipliedFirst (byte order B,G,R,A).
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else {
            throw ImageBridgeError.decodeFailed("CGContext for PDF page")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))      // flatten onto white
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Scale points→pixels ourselves, THEN let getDrawingTransform handle only the
        // rotation/origin fit at 1:1. CGPDFPage.getDrawingTransform never scales UP — given
        // a pixel rect larger than the page (any DPI > 72) it 1:1-centers the page and leaves
        // white margins (the bug that hid behind center-pixel tests). So we ctx.scaleBy(dpi/72)
        // and ask it only for a POINT-sized (1:1) fit, which it maps faithfully (incl. /Rotate).
        let box = page.getBoxRect(.cropBox)
        let scale = dpi / 72.0
        let rotated = page.rotationAngle % 180 != 0
        let fitRect = CGRect(x: 0, y: 0,
                             width: rotated ? box.height : box.width,
                             height: rotated ? box.width : box.height)
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: fitRect, rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        return buffer
    }
}
