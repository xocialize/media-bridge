//
// FormatDescriptionFactory.swift — MediaImport
//
// CodecPrivate (avcC / hvcC) → CMVideoFormatDescription via the VideoToolbox parameter-set
// convenience APIs. Matroska stores H.264/HEVC samples AVCC length-prefixed and the parameter sets
// in CodecPrivate as raw NAL units (no start codes) — exactly what these APIs expect. See
// MEDIABRIDGE-PLAN.md §4 and mkv-import.md §4.
//

import CoreMedia
import Foundation

public enum FormatDescriptionError: Error, Equatable {
    case unsupportedCodec(String)
    case missingCodecPrivate(String)
    case malformed(String)
    case vt(OSStatus)
}

public enum FormatDescriptionFactory {

    /// Build a video format description for a natively-decodable codec. AV1 (`V_AV1`) is handled
    /// separately (manual `av1C`, no convenience API) — not yet implemented here.
    public static func makeVideo(codecID: String, codecPrivate: Data?) throws -> CMFormatDescription {
        switch codecID {
        case "V_MPEG4/ISO/AVC":
            guard let p = codecPrivate else { throw FormatDescriptionError.missingCodecPrivate("avcC") }
            return try makeAVC(avcC: [UInt8](p))
        case "V_MPEGH/ISO/HEVC":
            guard let p = codecPrivate else { throw FormatDescriptionError.missingCodecPrivate("hvcC") }
            return try makeHEVC(hvcC: [UInt8](p))
        default:
            throw FormatDescriptionError.unsupportedCodec(codecID)
        }
    }

    // MARK: - H.264 (avcC, ISO/IEC 14496-15)

    private static func makeAVC(avcC b: [UInt8]) throws -> CMFormatDescription {
        guard b.count >= 7, b[0] == 1 else { throw FormatDescriptionError.malformed("avcC header") }
        let nalLen = Int(b[4] & 0x03) + 1
        let numSPS = Int(b[5] & 0x1F)
        var i = 6
        var params: [[UInt8]] = []
        func readNAL() throws {
            guard i + 2 <= b.count else { throw FormatDescriptionError.malformed("avcC NAL len") }
            let len = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
            guard i + len <= b.count else { throw FormatDescriptionError.malformed("avcC NAL body") }
            params.append(Array(b[i..<i + len])); i += len
        }
        for _ in 0..<numSPS { try readNAL() }
        guard i < b.count else { throw FormatDescriptionError.malformed("avcC missing PPS count") }
        let numPPS = Int(b[i]); i += 1
        for _ in 0..<numPPS { try readNAL() }
        return try create(params: params, nalUnitHeaderLength: nalLen, hevc: false)
    }

    // MARK: - HEVC (hvcC, ISO/IEC 14496-15)

    private static func makeHEVC(hvcC b: [UInt8]) throws -> CMFormatDescription {
        guard b.count > 23, b[0] == 1 else { throw FormatDescriptionError.malformed("hvcC header") }
        let nalLen = Int(b[21] & 0x03) + 1
        let numArrays = Int(b[22])
        var i = 23
        var params: [[UInt8]] = []
        for _ in 0..<numArrays {
            guard i + 3 <= b.count else { throw FormatDescriptionError.malformed("hvcC array header") }
            i += 1                                   // array_completeness | NAL_unit_type
            let numNalus = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
            for _ in 0..<numNalus {
                guard i + 2 <= b.count else { throw FormatDescriptionError.malformed("hvcC NAL len") }
                let len = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
                guard i + len <= b.count else { throw FormatDescriptionError.malformed("hvcC NAL body") }
                params.append(Array(b[i..<i + len])); i += len
            }
        }
        return try create(params: params, nalUnitHeaderLength: nalLen, hevc: true)
    }

    // MARK: - VideoToolbox bridge

    private static func create(params: [[UInt8]], nalUnitHeaderLength: Int,
                               hevc: Bool) throws -> CMFormatDescription {
        guard !params.isEmpty else { throw FormatDescriptionError.malformed("no parameter sets") }

        // Stable copies so the base pointers outlive the API call.
        var blocks: [UnsafeMutablePointer<UInt8>] = []
        defer { blocks.forEach { $0.deallocate() } }
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        for p in params {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: p.count)
            p.withUnsafeBufferPointer { buf.update(from: $0.baseAddress!, count: p.count) }
            blocks.append(buf)
            pointers.append(UnsafePointer(buf))
            sizes.append(p.count)
        }

        var fmt: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { ss in
                hevc
                ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: params.count,
                    parameterSetPointers: pp.baseAddress!, parameterSetSizes: ss.baseAddress!,
                    nalUnitHeaderLength: Int32(nalUnitHeaderLength), extensions: nil,
                    formatDescriptionOut: &fmt)
                : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: params.count,
                    parameterSetPointers: pp.baseAddress!, parameterSetSizes: ss.baseAddress!,
                    nalUnitHeaderLength: Int32(nalUnitHeaderLength),
                    formatDescriptionOut: &fmt)
            }
        }
        guard status == noErr, let f = fmt else { throw FormatDescriptionError.vt(status) }
        return f
    }
}
