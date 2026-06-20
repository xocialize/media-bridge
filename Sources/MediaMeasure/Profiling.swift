import Foundation

/// Env-gated profiling for the video optimize path. Set **`FORGE_PROFILE=1`** to emit stderr timing — where
/// the wall-clock actually goes (transcode vs scoring, and within scoring: frame decode+convert vs the GPU
/// SSIMULACRA2 math) plus whether the Metal scorer engages. Zero overhead when off.
enum MediaProfile {
    static let on = ProcessInfo.processInfo.environment["FORGE_PROFILE"] != nil

    static func log(_ message: @autoclosure () -> String) {
        guard on else { return }
        FileHandle.standardError.write(Data(("[forge-profile] " + message() + "\n").utf8))
    }

    static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }
}
