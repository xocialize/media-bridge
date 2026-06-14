import CoreVideo
import Foundation

/// decode → (optional) `FrameProcessor` → encode. The processor is ForgeOptimizer's
/// chain reused unchanged; `nil` is a passthrough. `convert` emits one frame; multi-page
/// (PDF) / multi-frame (TIFF) sources fan out to per-page files via `convertSequence`
/// (PRD §7). Animated GIF→video is the FormatBridge handoff (ADR-0022), not here.
final class StillConversionOrchestratorImpl: StillConversionOrchestrating, @unchecked Sendable {

    private let decoder: any StillDecoding
    private let encoder: any StillEncoding

    init(decoder: any StillDecoding, encoder: any StillEncoding) {
        self.decoder = decoder
        self.encoder = encoder
    }

    func convert(input: URL, output: URL, settings: StillEncoderSettings,
                 frameProcessor: (any FrameProcessor)?) throws {
        let (frames, meta) = try decodeChecked(input)
        let processed = try run(frames[0], processor: frameProcessor, alpha: meta.alpha)
        try encoder.encode(processed, settings: settings, metadata: meta, to: output)
    }

    @discardableResult
    func convertSequence(input: URL, output: URL, settings: StillEncoderSettings,
                         frameProcessor: (any FrameProcessor)?) throws -> [URL] {
        let (frames, meta) = try decodeChecked(input)
        if frames.count == 1 {
            try convert(input: input, output: output, settings: settings, frameProcessor: frameProcessor)
            return [output]
        }
        let dir = output.deletingLastPathComponent()
        let stem = output.deletingPathExtension().lastPathComponent
        let ext = output.pathExtension
        var written: [URL] = []
        written.reserveCapacity(frames.count)
        for (i, frame) in frames.enumerated() {
            let processed = try run(frame, processor: frameProcessor, alpha: meta.alpha)
            let page = dir.appendingPathComponent(String(format: "%@-%03d", stem, i + 1))
                          .appendingPathExtension(ext)
            try encoder.encode(processed, settings: settings, metadata: meta, to: page)
            written.append(page)
        }
        return written
    }

    private func decodeChecked(_ input: URL) throws -> (frames: [CVPixelBuffer], metadata: StillMetadata) {
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ImageBridgeError.fileNotFound(input.path)
        }
        let result = try decoder.decode(url: input)
        guard !result.frames.isEmpty else { throw ImageBridgeError.decodeFailed("no frames decoded") }
        return result
    }

    private func run(_ buffer: CVPixelBuffer, processor: (any FrameProcessor)?,
                     alpha: AlphaMode) throws -> CVPixelBuffer {
        FrameRun.run(buffer, processor: processor, alpha: alpha)
    }
}
