import Foundation

public enum ImageBridgeError: Error, Sendable, CustomStringConvertible {
    case unsupportedFormat(String)
    case decodeFailed(String)
    case encodeFailed(String)
    case fileNotFound(String)
    /// The input is valid but this build cannot handle it *yet* — an uncalibrated camera body, a RAW
    /// variant Apple's decoder does not know. Distinct from `decodeFailed` on purpose: nothing is
    /// wrong with the user's file, so a host should say "not supported yet", not "failed".
    case deferred(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let s): return "unsupported image format: \(s)"
        case .decodeFailed(let s): return "image decode failed: \(s)"
        case .encodeFailed(let s): return "image encode failed: \(s)"
        case .fileNotFound(let s): return "file not found: \(s)"
        case .deferred(let s): return s
        }
    }
}
