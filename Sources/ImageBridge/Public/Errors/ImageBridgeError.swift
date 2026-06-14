import Foundation

public enum ImageBridgeError: Error, Sendable, CustomStringConvertible {
    case unsupportedFormat(String)
    case decodeFailed(String)
    case encodeFailed(String)
    case fileNotFound(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let s): return "unsupported image format: \(s)"
        case .decodeFailed(let s): return "image decode failed: \(s)"
        case .encodeFailed(let s): return "image encode failed: \(s)"
        case .fileNotFound(let s): return "file not found: \(s)"
        }
    }
}
