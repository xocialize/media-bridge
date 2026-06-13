import XCTest
@testable import MediaImport

final class SupportGateTests: XCTestCase {
    func testNativeVideoCodecs() {
        XCTAssertEqual(SupportGate.status(forCodecID: "V_MPEG4/ISO/AVC"), .nativeVideo)
        XCTAssertEqual(SupportGate.status(forCodecID: "V_MPEGH/ISO/HEVC"), .nativeVideo)
        XCTAssertEqual(SupportGate.status(forCodecID: "V_AV1"), .nativeVideo)
    }

    func testNativeAudioCodecs() {
        XCTAssertEqual(SupportGate.status(forCodecID: "A_OPUS"), .nativeAudio)
        XCTAssertEqual(SupportGate.status(forCodecID: "A_FLAC"), .nativeAudio)
        XCTAssertEqual(SupportGate.status(forCodecID: "A_ALAC"), .nativeAudio)
        XCTAssertEqual(SupportGate.status(forCodecID: "A_AAC"), .nativeAudio)
        XCTAssertEqual(SupportGate.status(forCodecID: "A_AAC/MPEG4/LC"), .nativeAudio)   // suffixed
        XCTAssertEqual(SupportGate.status(forCodecID: "A_PCM/INT/LIT"), .nativeAudio)
    }

    func testDeferredCodecs() {
        for id in ["V_VP9", "V_VP8", "A_VORBIS", "A_AC3", "A_EAC3", "A_DTS", "A_TRUEHD",
                   "V_MPEG1", "V_MPEG2"] {
            XCTAssertEqual(SupportGate.status(forCodecID: id), .deferred, "\(id) should defer")
        }
    }
}
