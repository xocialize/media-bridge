import CoreVideo

/// Hook for AI frame processing (ForgeOptimizer or any custom pipeline).
///
/// FormatBridge accepts any `FrameProcessor` conformance via `FormatBridgeFactory.makeOrchestrator(frameProcessor:)`.
/// ForgeOptimizer's `ModelChain` conforms to this protocol, allowing the AI pipeline to be injected
/// without FormatBridge depending on CoreML or any model weights.
public protocol FrameProcessor: Sendable {
    func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer
}

/// Chains multiple processors in sequence.
public final class ModelChain: FrameProcessor, @unchecked Sendable {
    private let processors: [any FrameProcessor]

    public init(_ processors: [any FrameProcessor]) {
        self.processors = processors
    }

    public func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        processors.reduce(pixelBuffer) { buffer, processor in
            processor.process(buffer)
        }
    }
}
