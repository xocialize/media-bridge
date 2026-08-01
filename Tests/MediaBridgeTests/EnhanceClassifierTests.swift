// The T4 classify half, pinned. The 2×2 matrix, the honest-degradation path when bitrate is
// unknown, and the rationale contract (numbers in the sentence — FORGE-UI §1.11).
// Calibration against the 9 real C7 titles lives in the T4 receipt (9/9 at real fps).
import Foundation
import Testing

@testable import MediaMeasure

@Suite("EnhanceClassifier")
struct EnhanceClassifierTests {

    func profile(_ w: Int, _ h: Int, fps: Double = 24, kbps: Double) -> SourceProfile {
        SourceProfile(width: w, height: h, frameRate: fps, videoBitsPerSecond: kbps * 1000)
    }

    @Test func theC7QuadrantsClassify() {
        // Archetypes at the corrected (real-fps) operating points.
        #expect(EnhanceClassifier.classify(profile(1279, 682, fps: 29.97, kbps: 810)).enhanceClass == .bitrateStarved)   // Joker
        #expect(EnhanceClassifier.classify(profile(624, 352, fps: 24, kbps: 1525)).enhanceClass == .resolutionLimited)   // BSG
        #expect(EnhanceClassifier.classify(profile(1920, 1080, fps: 23.98, kbps: 5600)).enhanceClass == .clean)          // Mandalorian
        // VHS-digitized: tiny AND starved — the customer-segment case with both defects at once.
        #expect(EnhanceClassifier.classify(profile(480, 360, fps: 30, kbps: 300)).enhanceClass == .mixed)
    }

    @Test func unknownBitrateDegradesHonestly() {
        let v = EnhanceClassifier.classify(SourceProfile(width: 624, height: 352, frameRate: 0,
                                                         videoBitsPerSecond: 0))
        #expect(v.enhanceClass == .resolutionLimited)
        #expect(v.bitrateAxisUnknown)
        #expect(v.rationale.contains("unknown"))
        let clean = EnhanceClassifier.classify(SourceProfile(width: 1920, height: 1080, frameRate: 24,
                                                             videoBitsPerSecond: 0))
        #expect(clean.enhanceClass == .clean)
        #expect(clean.bitrateAxisUnknown)
    }

    @Test func rationaleCarriesTheNumbers() {
        let v = EnhanceClassifier.classify(profile(1279, 682, fps: 29.97, kbps: 810))
        #expect(v.rationale.contains("1279x682"))
        #expect(v.rationale.contains("bits/px"))
        #expect(v.rationale.lowercased().contains("restore"))
    }

    @Test func thresholdsAreInjectable() {
        let strict = EnhanceThresholds(resolutionFloorPixels: 3_000_000, starvedBitsPerPixel: 0.01)
        let v = EnhanceClassifier.classify(profile(1920, 1080, kbps: 5600), thresholds: strict)
        #expect(v.enhanceClass == .resolutionLimited)   // 2.07 MP < 3 MP under the injected floor
    }

    @Test func boundaryIsExclusiveOnBothAxes() {
        // Exactly AT the threshold is not below it — the same class of trap as the seam-mask `<`
        // on a saturated percentile (pitfall 50a): state the comparison, test the boundary.
        let t = EnhanceThresholds(resolutionFloorPixels: 450_000, starvedBitsPerPixel: 0.09)
        let atFloor = SourceProfile(width: 750, height: 600, frameRate: 24,
                                    videoBitsPerSecond: 0.09 * 450_000 * 24)   // exactly 0.09 bpp
        let v = EnhanceClassifier.classify(atFloor, thresholds: t)
        #expect(v.enhanceClass == .clean, "450000 px and 0.090 bpp sit AT the thresholds, not below")
    }
}
