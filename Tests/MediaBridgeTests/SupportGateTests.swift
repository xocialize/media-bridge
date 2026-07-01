import XCTest
@testable import MediaImport

final class SupportGateTests: XCTestCase {
    func testNativeVideoCodecs() {
        XCTAssertEqual(SupportGate.status(forCodecID: "V_MPEG4/ISO/AVC"), .nativeVideo)
        XCTAssertEqual(SupportGate.status(forCodecID: "V_MPEGH/ISO/HEVC"), .nativeVideo)
        XCTAssertEqual(SupportGate.status(forCodecID: "V_AV1"), .nativeVideo)
        XCTAssertEqual(SupportGate.status(forCodecID: "V_MPEG2"), .nativeVideo)   // Phase D
        XCTAssertEqual(SupportGate.status(forCodecID: "V_MPEG1"), .nativeVideo)   // Phase D
    }

    func testNativeAudioCodecs() {
        XCTAssertEqual(SupportGate.status(forCodecID: "A_OPUS"), .nativeAudio)
        XCTAssertEqual(SupportGate.status(forCodecID: "A_FLAC"), .nativeAudio)
        XCTAssertEqual(SupportGate.status(forCodecID: "A_ALAC"), .nativeAudio)
        XCTAssertEqual(SupportGate.status(forCodecID: "A_AAC"), .nativeAudio)
        XCTAssertEqual(SupportGate.status(forCodecID: "A_AAC/MPEG4/LC"), .nativeAudio)   // suffixed
        XCTAssertEqual(SupportGate.status(forCodecID: "A_PCM/INT/LIT"), .nativeAudio)
    }

    // Phase A: AC-3 / E-AC-3 / MPEG Layer I-III decode natively via AudioToolbox (no dependency).
    func testNativeAudioDolbyAndMPEG() {
        for id in ["A_AC3", "A_EAC3", "A_MPEG/L1", "A_MPEG/L2", "A_MPEG/L3"] {
            XCTAssertEqual(SupportGate.status(forCodecID: id), .nativeAudio, "\(id) is native audio")
        }
    }

    func testDeferredCodecs() {
        // VP9 included: no native VideoToolbox decoder on Apple Silicon (verified) — stays deferred.
        for id in ["V_VP9", "V_VP8", "A_VORBIS", "A_DTS", "A_TRUEHD"] {
            XCTAssertEqual(SupportGate.status(forCodecID: id), .deferred, "\(id) should defer")
        }
    }
}
