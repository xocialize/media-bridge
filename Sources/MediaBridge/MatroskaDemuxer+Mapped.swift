//
// MatroskaDemuxer+Mapped.swift — MediaBridge
//
// The one way this package opens a Matroska/WebM file for demuxing.
//

import Foundation
import MatroskaDemux

extension MatroskaDemuxer {

    /// Open a Matroska/WebM file for demuxing over a **memory-mapped** `Data`.
    ///
    /// `MatroskaDemuxer` reads through `MemoryReader`, which indexes the `Data` it is given and
    /// never copies it, and `parseHeaders()` stops at the first Cluster. So the *shape* of the
    /// read decides the cost: a plain `Data(contentsOf:)` materialises the entire file into
    /// resident memory before a single EBML byte is parsed — a multi-GB MKV master costs a
    /// multi-GB allocation just to learn its track list (`probe`), and doubles the footprint of
    /// every normalize that then walks the packets anyway. A mapped `Data` faults in only the
    /// pages actually touched: the header pages for a probe, and file-backed, evictable pages
    /// for a full demux instead of an anonymous copy.
    ///
    /// `.mappedIfSafe` (not `.alwaysMapped`) is deliberate: Foundation falls back to a real read
    /// where a mapping could be torn out from under us (network / removable volumes), so a
    /// truncated source cannot turn into a `SIGBUS`. Inputs are read-only by contract at every
    /// call site (ForgeOptimizer's `OptimizeRequest.input` is never written), so a local mapping
    /// is safe for the demuxer's lifetime.
    ///
    /// Every `MatroskaDemuxer(data: Data(contentsOf:))` in this package routes through here —
    /// keep it that way, or the next probe re-introduces the whole-file read.
    static func mapped(_ url: URL) throws -> MatroskaDemuxer {
        MatroskaDemuxer(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }
}
