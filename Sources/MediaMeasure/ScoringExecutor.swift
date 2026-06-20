import Foundation

/// Runs CPU-bound perceptual scoring (CGContext rasterization → SSIMULACRA2 → Metal dispatch) **off the
/// Swift cooperative pool** on a dedicated **`.utility`-QoS** queue.
///
/// Why: the host drives optimize from a `.userInitiated` Task. Calling the synchronous scorer directly on
/// that Task would block a high-QoS thread inside CoreGraphics/Metal's Default-QoS internal threads
/// (`CGContext.draw` in `SSIMULACRA2.linearRGB`) → a **priority inversion** (the benign EMBED-004
/// diagnostic). Awaiting this hop instead **suspends** the Task (no blocked thread) and runs the work at a
/// QoS at/below CoreGraphics's, so there is no high-on-low wait. It also keeps a multi-iteration scoring
/// search from starving the cooperative pool with long synchronous CPU work.
enum ScoringExecutor {
    private static let queue = DispatchQueue(label: "media-bridge.scoring",
                                             qos: .utility, attributes: .concurrent)

    /// Run `work` on the scoring queue and await its result. Propagates thrown errors.
    static func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }
}
