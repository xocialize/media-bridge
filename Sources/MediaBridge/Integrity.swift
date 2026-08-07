//
// Integrity.swift — MediaBridge
//
// File-integrity verification, tiered by cost. The probe reads *headers* and is therefore blind to
// the corruption that actually occurs in production — truncated copies, interrupted downloads,
// bit-rot inside payload data — all of which probe as perfectly healthy files.
//
//   • `.structural` (milliseconds): magic-byte sniff (never the extension — a mislabeled file is
//     itself a finding), then a format-specific *byte walk* that checks the container's declared
//     structure against the actual file extent: ISOBMFF box chains, PNG chunk CRCs, the JPEG EOI
//     marker, Matroska element sizes. Deterministic — a failure is a fact about bytes, not a guess.
//   • `.deep` (a full decode pass): everything structural, plus decode-to-EOF through the
//     OS-hardened decoders — AVAssetReader with an explicit terminal-status check for video (the
//     EMBED-005 lesson: `copyNextSampleBuffer() == nil` is EOF *or* failure, only `status` says
//     which), full-raster ImageIO decode for stills. On failure it reports HOW FAR decode got —
//     the triage number a production incident wants.
//
// The report never throws and never lies about scope: `checks` lists exactly what ran, so `intact`
// can't be read as a stronger claim than the tier that produced it.
//

import AVFoundation
import CoreMedia
import Foundation
import ImageIO

public enum MediaIntegrity {

    public enum Level: Sendable {
        case structural     // byte walks only — safe to run on every ingest
        case deep           // + decode-to-EOF (costs a full decode pass)
    }

    public struct Check: Sendable, Equatable {
        public enum Outcome: String, Sendable { case passed, failed, skipped }
        public let name: String
        public let outcome: Outcome
        public let detail: String?

        init(_ name: String, _ outcome: Outcome, _ detail: String? = nil) {
            self.name = name; self.outcome = outcome; self.detail = detail
        }
    }

    public struct Report: Sendable {
        public enum Verdict: String, Sendable {
            case intact         // every check that ran passed
            case corrupt        // at least one deterministic check failed
            case unverified     // nothing beyond readability could run (unknown format, IO error)
        }
        public let verdict: Verdict
        public let checks: [Check]

        /// The first failure's diagnosis — nil when nothing failed.
        public var detail: String? { checks.first { $0.outcome == .failed }?.detail }
        public var isIntact: Bool { verdict == .intact }
    }

    // MARK: - Entry

    public static func verify(url: URL, level: Level = .structural) async -> Report {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
              let fh = try? FileHandle(forReadingFrom: url) else {
            return Report(verdict: .unverified,
                          checks: [Check("readable", .failed, "file missing, empty, or unreadable")])
        }
        defer { try? fh.close() }

        var checks: [Check] = [Check("readable", .passed)]
        let head = (try? fh.read(upToCount: 16)) ?? Data()
        let format = sniff(head)

        switch format {
        case .isobmff:
            checks += isobmffWalk(fh, fileSize: UInt64(size))
        case .png:
            checks += pngWalk(fh, fileSize: UInt64(size))
        case .jpeg:
            checks += jpegTail(fh, fileSize: UInt64(size))
        case .ebml:
            checks += ebmlWalk(fh, fileSize: UInt64(size))
        case .other(let name):
            checks.append(Check("magic", .passed, "\(name): no structural walk for this format"))
        case .unknown:
            checks.append(Check("magic", .skipped, "unrecognized leading bytes — not a known media format"))
        }

        if level == .deep {
            checks += await deepChecks(url: url, format: format)
        }

        let failed = checks.contains { $0.outcome == .failed }
        let ranAnything = checks.contains { $0.name != "readable" && $0.outcome != .skipped }
        let verdict: Report.Verdict = failed ? .corrupt : (ranAnything ? .intact : .unverified)
        return Report(verdict: verdict, checks: checks)
    }

    // MARK: - Magic sniff

    enum Sniffed: Equatable {
        case isobmff        // mp4 / mov / m4v / heic / avif — box-structured
        case png, jpeg
        case ebml           // Matroska / WebM
        case other(String)  // recognized, no walk (gif / bmp / tiff / webp / avi)
        case unknown
    }

    static func sniff(_ head: Data) -> Sniffed {
        guard head.count >= 12 else { return .unknown }
        let b = [UInt8](head)
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A { return .png }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        if b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 { return .ebml }
        let type4 = String(bytes: b[4...7], encoding: .ascii) ?? ""
        if ["ftyp", "styp", "moov", "mdat", "free", "skip", "wide", "pnot"].contains(type4) {
            return .isobmff
        }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return .other("gif") }
        if b[0] == 0x42, b[1] == 0x4D { return .other("bmp") }
        if (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00)
            || (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A) { return .other("tiff") }
        if let riff = String(bytes: b[0...3], encoding: .ascii), riff == "RIFF",
           let kind = String(bytes: b[8...11], encoding: .ascii) {
            if kind == "WEBP" { return .other("webp") }
            if kind.hasPrefix("AVI") { return .other("avi") }
        }
        return .unknown
    }

    // MARK: - ISOBMFF (mp4 / mov / heic / avif) box-chain walk

    /// Top-level boxes must chain *exactly* to EOF — a truncated file's last box declares bytes the
    /// file no longer has, and an unfinalized recording is missing its `moov`. Header reads only:
    /// a multi-GB file costs a few dozen 8–16-byte reads.
    static func isobmffWalk(_ fh: FileHandle, fileSize end: UInt64) -> [Check] {
        var offset: UInt64 = 0
        var tops: [String] = []
        var imageBrand = false

        while offset < end {
            guard end - offset >= 8 else {
                return [Check("box-chain", .failed,
                              "truncated: \(end - offset) trailing bytes at EOF are not a box")]
            }
            guard let header = read(fh, at: offset, count: 8), header.count == 8 else {
                return [Check("box-chain", .failed, "unreadable box header at offset \(offset)")]
            }
            var boxSize = UInt64(be32(header, 0))
            let type = fourCC(header, 4)
            guard type.allSatisfy({ $0.isASCII && $0 >= " " && $0 <= "~" }) else {
                return [Check("box-chain", .failed,
                              "invalid box type at offset \(offset) — payload bytes where a box header belongs")]
            }
            var headerLen: UInt64 = 8
            if boxSize == 1 {
                guard let ext = read(fh, at: offset + 8, count: 8), ext.count == 8 else {
                    return [Check("box-chain", .failed, "unreadable 64-bit box size at offset \(offset)")]
                }
                boxSize = be64(ext, 0); headerLen = 16
            } else if boxSize == 0 {
                boxSize = end - offset          // "extends to EOF" — legal for a final box
            }
            guard boxSize >= headerLen else {
                return [Check("box-chain", .failed,
                              "box '\(type)' at offset \(offset) declares \(boxSize) B — smaller than its own header")]
            }
            guard offset + boxSize <= end else {
                return [Check("box-chain", .failed,
                              "truncated: box '\(type)' at offset \(offset) declares \(boxSize) B but the file ends \(offset + boxSize - end) B short")]
            }
            if type == "ftyp", let brand = read(fh, at: offset + 8, count: 4).map({ fourCC($0, 0) }) {
                imageBrand = ["heic", "heix", "mif1", "msf1", "avif", "avis"].contains(brand)
            }
            tops.append(type)
            offset += boxSize
        }

        var checks = [Check("box-chain", .passed, "\(tops.count) top-level boxes chain exactly to EOF")]
        if imageBrand {
            checks.append(tops.contains("meta")
                ? Check("meta-present", .passed)
                : Check("meta-present", .failed, "image brand without a 'meta' box — undisplayable"))
        } else if tops.contains("mdat") || tops.contains("moof") {
            checks.append(tops.contains("moov")
                ? Check("moov-present", .passed)
                : Check("moov-present", .failed,
                        "media data without 'moov' — unfinalized recording or stripped index; unplayable"))
        }
        return checks
    }

    // MARK: - PNG chunk walk (CRC-verified)

    /// PNG carries its own integrity primitive: every chunk ends in a CRC32 over type+data. The walk
    /// verifies each one and requires IHDR-first, IEND-last, EOF-exact — so both truncation *and*
    /// interior bit-rot are deterministic failures. Costs one sequential read of the file.
    static func pngWalk(_ fh: FileHandle, fileSize end: UInt64) -> [Check] {
        var offset: UInt64 = 8      // past the 8-byte signature (sniffed)
        var first: String?
        var last = ""
        var count = 0

        while offset < end {
            guard end - offset >= 12,
                  let header = read(fh, at: offset, count: 8), header.count == 8 else {
                return [Check("png-chunks", .failed,
                              "truncated: \(end - offset) trailing bytes at EOF are not a chunk")]
            }
            let length = UInt64(be32(header, 0))
            let type = fourCC(header, 4)
            guard type.allSatisfy({ $0.isLetter && $0.isASCII }) else {
                return [Check("png-chunks", .failed, "invalid chunk type at offset \(offset)")]
            }
            guard length <= 0x7FFF_FFFF, offset + 12 + length <= end else {
                return [Check("png-chunks", .failed,
                              "truncated: chunk '\(type)' at offset \(offset) declares \(length) B but the file ends first")]
            }
            guard let payload = read(fh, at: offset + 8, count: Int(length)),
                  payload.count == Int(length),
                  let crcBytes = read(fh, at: offset + 8 + length, count: 4), crcBytes.count == 4 else {
                return [Check("png-chunks", .failed, "unreadable chunk '\(type)' at offset \(offset)")]
            }
            var crc = crc32(0, [UInt8](header[4..<8]))
            crc = crc32(crc, [UInt8](payload))
            guard crc == be32(crcBytes, 0) else {
                return [Check("png-chunks", .failed,
                              "CRC mismatch in chunk '\(type)' at offset \(offset) — payload bytes are damaged")]
            }
            if first == nil { first = type }
            last = type
            count += 1
            offset += 12 + length
        }

        guard first == "IHDR" else {
            return [Check("png-chunks", .failed, "first chunk is '\(first ?? "none")', not IHDR")]
        }
        guard last == "IEND" else {
            return [Check("png-chunks", .failed, "truncated: last chunk is '\(last)', not IEND")]
        }
        return [Check("png-chunks", .passed, "\(count) chunks, all CRCs verified, IEND at EOF")]
    }

    // MARK: - JPEG end-of-image check

    /// The classic truncation tell: a complete JPEG ends with the EOI marker (FFD9). Scanned in the
    /// final 4 KB because encoders legally append trailing metadata after it.
    static func jpegTail(_ fh: FileHandle, fileSize end: UInt64) -> [Check] {
        let window = UInt64(min(4096, end))
        guard let tail = read(fh, at: end - window, count: Int(window)), tail.count == Int(window) else {
            return [Check("jpeg-eoi", .failed, "unreadable file tail")]
        }
        let bytes = [UInt8](tail)
        for i in stride(from: bytes.count - 2, through: 0, by: -1) where bytes[i] == 0xFF && bytes[i + 1] == 0xD9 {
            return [Check("jpeg-eoi", .passed, "EOI marker present")]
        }
        return [Check("jpeg-eoi", .failed, "truncated: no EOI marker (FFD9) in the final \(window) B")]
    }

    // MARK: - Matroska / WebM element walk

    /// EBML elements declare their sizes; walking the chain against EOF catches truncation without
    /// loading the file. Stops honestly at an unknown-size element (legal for live-captured
    /// clusters) — everything walked up to that point still had to fit.
    static func ebmlWalk(_ fh: FileHandle, fileSize end: UInt64) -> [Check] {
        var offset: UInt64 = 0
        var walked = 0
        var stoppedEarly: String?

        while offset < end, walked < 2_000_000 {
            guard let id = readVINT(fh, at: offset, keepMarker: true) else {
                return [Check("ebml-elements", .failed, "invalid element ID at offset \(offset)")]
            }
            guard let size = readVINT(fh, at: offset + UInt64(id.length), keepMarker: false) else {
                return [Check("ebml-elements", .failed, "invalid element size at offset \(offset)")]
            }
            let headerLen = UInt64(id.length + size.length)
            walked += 1

            if size.isUnknown {
                // Unknown-size element (streaming Segment/Cluster): its extent is "to EOF" by
                // construction, so descend one level and keep walking children instead.
                if id.value == 0x1853_8067 {            // Segment — walk its children
                    offset += headerLen
                    continue
                }
                stoppedEarly = String(format: "0x%X", id.value)
                break
            }
            guard offset + headerLen + size.value <= end else {
                return [Check("ebml-elements", .failed,
                              String(format: "truncated: element 0x%X at offset %d declares %d B but the file ends %d B short",
                                     id.value, offset, size.value, offset + headerLen + size.value - end))]
            }
            if id.value == 0x1853_8067 {                // Segment with known size — walk children
                offset += headerLen
            } else {
                offset += headerLen + size.value
            }
        }

        let note = stoppedEarly.map { "walked \(walked) elements (stopped at unknown-size element \($0))" }
            ?? "\(walked) elements chain to EOF"
        return [Check("ebml-elements", .passed, note)]
    }

    // MARK: - Deep tier (decode-to-EOF)

    static func deepChecks(url: URL, format: Sniffed) async -> [Check] {
        switch format {
        case .png, .jpeg, .other("gif"), .other("tiff"), .other("bmp"), .other("webp"):
            return deepImageDecode(url)
        case .isobmff:
            // Movie vs image brand: let the frameworks decide — tracks mean AV, none means still.
            let hasTracks = ((try? await AVURLAsset(url: url).load(.tracks))?.isEmpty == false)
            return hasTracks ? await deepVideoDecode(url) : deepImageDecode(url)
        case .ebml:
            return await deepVideoDecode(url, matroska: true)
        case .other(let name):
            return [Check("decode", .skipped, "no deep decoder for \(name) in this tier")]
        case .unknown:
            return [Check("decode", .skipped, "unrecognized format")]
        }
    }

    /// Full-raster decode through ImageIO — header-only reads are exactly what deep mode must not
    /// do. Draws at native size (a truncated payload otherwise hides behind a subsampled decode).
    static func deepImageDecode(_ url: URL) -> [Check] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) >= 1 else {
            return [Check("decode", .failed, "ImageIO cannot open the file")]
        }
        let count = CGImageSourceGetCount(src)
        for index in Set([0, count - 1]) {
            guard let image = CGImageSourceCreateImageAtIndex(src, index, nil) else {
                return [Check("decode", .failed, "frame \(index) of \(count) does not decode")]
            }
            let status = CGImageSourceGetStatusAtIndex(src, index)
            guard status == .statusComplete else {
                return [Check("decode", .failed,
                              "frame \(index) decode status \(status.rawValue) (incomplete/invalid data)")]
            }
            // Force the full scan decode — CGImage creation alone is lazy.
            guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return [Check("decode", .failed, "cannot rasterize \(image.width)×\(image.height)")]
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return [Check("decode", .passed, "\(count) frame(s) fully rasterized")]
    }

    /// Decode every A/V sample to EOF and check the reader's *terminal status* — nil from
    /// `copyNextSampleBuffer()` alone cannot distinguish EOF from a mid-file abort (EMBED-005).
    /// On failure the check reports how far decode got: the triage number an incident wants.
    static func deepVideoDecode(_ url: URL, matroska: Bool = false) async -> [Check] {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks), !tracks.isEmpty else {
            return matroska
                ? [Check("decode", .skipped,
                         "decode verification for Matroska needs the demux path; the structural walk covers the element chain")]
                : [Check("decode", .failed, "no decodable tracks")]
        }
        guard let reader = try? AVAssetReader(asset: asset) else {
            return [Check("decode", .failed, "AVAssetReader cannot open the file")]
        }

        var outputs: [AVAssetReaderTrackOutput] = []
        for track in tracks {
            let settings: [String: Any]?
            switch track.mediaType {
            case .video: settings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            case .audio: settings = [AVFormatIDKey: kAudioFormatLinearPCM]
            default: continue                    // metadata/timecode tracks aren't integrity-bearing
            }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) { reader.add(out); outputs.append(out) }
        }
        guard !outputs.isEmpty, reader.startReading() else {
            return [Check("decode", .failed,
                          "reader refused to start: \(reader.error.map(String.init(describing:)) ?? "unknown")")]
        }

        // Round-robin drain — fully draining one track first would force the reader to buffer every
        // interleaved sample of the others.
        var samples = [Int](repeating: 0, count: outputs.count)
        var lastPTS = CMTime.zero
        var live = Array(outputs.indices)
        while !live.isEmpty {
            for i in live {
                if let sb = outputs[i].copyNextSampleBuffer() {
                    samples[i] += 1
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                    if pts.isNumeric, pts > lastPTS { lastPTS = pts }
                } else {
                    live.removeAll { $0 == i }
                    break                       // indices changed — restart the sweep
                }
            }
        }

        let total = samples.reduce(0, +)
        if reader.status == .failed {
            return [Check("decode", .failed,
                          String(format: "aborted after %d samples (t≈%.2fs): %@", total,
                                 lastPTS.seconds.isFinite ? lastPTS.seconds : 0,
                                 String(describing: reader.error)))]
        }
        return [Check("decode", .passed,
                      String(format: "%d samples across %d tracks decoded to EOF (t≈%.2fs)",
                             total, outputs.count, lastPTS.seconds.isFinite ? lastPTS.seconds : 0))]
    }

    // MARK: - Byte helpers

    private static func read(_ fh: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard count >= 0 else { return nil }
        guard count > 0 else { return Data() }
        try? fh.seek(toOffset: offset)
        return try? fh.read(upToCount: count)
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        let b = [UInt8](data)
        return (UInt32(b[offset]) << 24) | (UInt32(b[offset + 1]) << 16)
             | (UInt32(b[offset + 2]) << 8) | UInt32(b[offset + 3])
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        let b = [UInt8](data)
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(b[offset + i]) }
        return v
    }

    private static func fourCC(_ data: Data, _ offset: Int) -> String {
        let b = [UInt8](data)
        return String(bytes: b[offset..<offset + 4], encoding: .ascii) ?? "????"
    }

    /// EBML variable-length integer. `keepMarker` reads IDs (marker bit retained, per spec);
    /// otherwise sizes (marker stripped). `isUnknown` = all data bits set (size unknown).
    private static func readVINT(_ fh: FileHandle, at offset: UInt64, keepMarker: Bool)
        -> (value: UInt64, length: Int, isUnknown: Bool)? {
        guard let first = read(fh, at: offset, count: 1), first.count == 1 else { return nil }
        let b0 = first[first.startIndex]
        guard b0 != 0 else { return nil }
        let lengthFromBits = b0.leadingZeroBitCount + 1              // 1…8 for a nonzero byte
        guard let rest = read(fh, at: offset + 1, count: lengthFromBits - 1),
              rest.count == lengthFromBits - 1 else { return nil }
        var value = UInt64(b0)
        if !keepMarker { value &= (UInt64(0xFF) >> UInt64(lengthFromBits)) }
        for byte in rest { value = (value << 8) | UInt64(byte) }
        let dataBits = UInt64(lengthFromBits * 7)
        let allOnes = dataBits >= 64 ? UInt64.max : (UInt64(1) << dataBits) - 1
        return (value, lengthFromBits, !keepMarker && value == allOnes)
    }

    /// CRC-32 (zlib polynomial) — the PNG chunk checksum.
    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ seed: UInt32, _ bytes: [UInt8]) -> UInt32 {
        var c = seed ^ 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
