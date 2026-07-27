import XCTest
@testable import MediaMeasure

/// BRIDGE-061. The video floor gates on a percentile over a *sample*, and a receipt that prints one
/// number cannot say so. "Every frame cleared 80" and "p10 cleared 80 while the worst frame was 61" are
/// both defensible guarantees and they are not the same guarantee.
///
/// These assert the *shape* of the claim, which is what was wrong — the numbers were always computed.
final class VideoAggregationTests: XCTestCase {

    private func aggregation(p10: Double = 81.3, mean: Double = 88.0, minimum: Double = 61.2,
                             scored: Int = 42, total: Int = 900) -> VideoQualityTarget.Aggregation {
        .init(percentile: 10, percentileScore: p10, mean: mean, minimum: minimum,
              framesScored: scored, frameCount: total)
    }

    /// The summary must name the percentile, the worst frame, and the sample — the three things a bare
    /// score hides. Asserting on content rather than exact formatting so wording can improve.
    func testSummaryStatesPercentileMinimumAndSampleSize() {
        let s = aggregation().summary
        XCTAssertTrue(s.contains("p10"), "must say WHICH percentile: \(s)")
        XCTAssertTrue(s.contains("81.3"), "must state the gating score: \(s)")
        XCTAssertTrue(s.contains("61.2"), "must state the worst frame — the number a mean would hide: \(s)")
        XCTAssertTrue(s.contains("42") && s.contains("900"), "must state scored/total frames: \(s)")
    }

    /// The failure being guarded: reporting the mean, which is generous, instead of the percentile the
    /// floor actually gated on.
    func testGatingScoreIsThePercentileNotTheMean() {
        let a = aggregation(p10: 81.3, mean: 88.0)
        XCTAssertEqual(a.percentileScore, 81.3)
        XCTAssertNotEqual(a.percentileScore, a.mean,
                          "the guarantee is the percentile; a mean would overstate it")
    }

    /// A fully-scored clip must be distinguishable from a sampled one.
    func testFullScoringIsDistinguishableFromSampling() {
        XCTAssertTrue(aggregation(scored: 900, total: 900).summary.contains("900/900"))
        XCTAssertTrue(aggregation(scored: 42, total: 900).summary.contains("42/900"))
    }

    /// The minimum can sit below the floor while the guarantee still holds — that is exactly why it must
    /// be printed rather than implied.
    func testMinimumMayBeBelowTheFloorAndIsStillReported() {
        let a = aggregation(p10: 81.3, minimum: 61.2)
        XCTAssertLessThan(a.minimum, 80.0)
        XCTAssertGreaterThanOrEqual(a.percentileScore, 80.0)
        XCTAssertTrue(a.summary.contains("61.2"))
    }
}
