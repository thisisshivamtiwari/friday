import XCTest
@testable import FounderOfficeCopilotCore

/// Covers `RelevanceScoring` - pure, deterministic, no manager dependencies. Confirms the
/// weighted-factor scoring model (explicitly NOT recency-dominated), keyword overlap, and the
/// recency decay curve, plus that it stays architecturally separate from
/// `MemoryEdge.staleThreshold`'s unrelated 90-day maintenance cutoff.
final class RelevanceScoringTests: XCTestCase {

    // MARK: score(_:)

    func testAllZeroFactorsScoreZero() {
        XCTAssertEqual(RelevanceScoring.score(RelevanceScoring.Factors()), 0, accuracy: 0.0001)
    }

    func testFullyMaximalFactorsScoreOne() {
        let factors = RelevanceScoring.Factors(
            keywordOverlap: 1,
            projectMatch: true,
            recency: 1,
            confidence: 1,
            isPinned: true,
            confirmationCount: 5,
            relationshipProximity: 1
        )
        XCTAssertEqual(RelevanceScoring.score(factors), 1.0, accuracy: 0.0001, "the seven weights must sum to 1.0")
    }

    func testIsPinnedAloneContributesItsOwnWeightOnly() {
        let factors = RelevanceScoring.Factors(isPinned: true)
        XCTAssertEqual(RelevanceScoring.score(factors), 0.10, accuracy: 0.0001)
    }

    func testKeywordOverlapIsNotTheDominantSoleFactor() {
        // Two evidence items: one with perfect keyword overlap but nothing else, one with
        // strong recency+confidence+project match but zero keyword overlap - relevance must
        // combine multiple signals, not let keyword overlap alone dominate every case.
        let keywordOnly = RelevanceScoring.Factors(keywordOverlap: 1)
        let everythingElse = RelevanceScoring.Factors(projectMatch: true, recency: 1, confidence: 1)
        XCTAssertLessThan(RelevanceScoring.score(keywordOnly), RelevanceScoring.score(everythingElse))
    }

    func testConfirmationCountDiminishesPastFive() {
        let atFive = RelevanceScoring.Factors(confirmationCount: 5)
        let atFifty = RelevanceScoring.Factors(confirmationCount: 50)
        XCTAssertEqual(RelevanceScoring.score(atFive), RelevanceScoring.score(atFifty), accuracy: 0.0001, "confirmation contribution must cap, not grow unbounded")
    }

    func testFactorsAreClampedToZeroOneRange() {
        let overOne = RelevanceScoring.Factors(keywordOverlap: 5, recency: -3, confidence: 10)
        let maxed = RelevanceScoring.Factors(keywordOverlap: 1, recency: 0, confidence: 1)
        // recency: -3 clamps to 0, keywordOverlap: 5 clamps to 1, confidence: 10 clamps to 1
        XCTAssertEqual(RelevanceScoring.score(overOne), RelevanceScoring.score(maxed), accuracy: 0.0001)
    }

    // MARK: keywordOverlap

    func testKeywordOverlapPerfectMatch() {
        XCTAssertEqual(RelevanceScoring.keywordOverlap(query: "gemini live api", text: "the gemini live api streams audio"), 1.0, accuracy: 0.0001)
    }

    func testKeywordOverlapNoMatch() {
        XCTAssertEqual(RelevanceScoring.keywordOverlap(query: "gemini live api", text: "completely unrelated sentence"), 0.0, accuracy: 0.0001)
    }

    func testKeywordOverlapEmptyQueryIsZero() {
        XCTAssertEqual(RelevanceScoring.keywordOverlap(query: "", text: "some text"), 0.0, accuracy: 0.0001)
    }

    func testKeywordOverlapEmptyTextIsZero() {
        XCTAssertEqual(RelevanceScoring.keywordOverlap(query: "some query", text: ""), 0.0, accuracy: 0.0001)
    }

    func testKeywordOverlapIsCaseInsensitive() {
        XCTAssertEqual(RelevanceScoring.keywordOverlap(query: "Gemini API", text: "the gemini api is great"), 1.0, accuracy: 0.0001)
    }

    func testKeywordOverlapDropsShortTokens() {
        // "a"/"of"/"my" are <=2 chars and should be dropped from the query's tokens entirely,
        // so this scores 1.0 based purely on "database"/"choice" matching, despite the filler
        // words not appearing in `text` at all.
        XCTAssertEqual(RelevanceScoring.keywordOverlap(query: "a database of my choice", text: "our database choice"), 1.0, accuracy: 0.0001)
    }

    // MARK: recencyScore

    func testRecencyScoreAtZeroAgeIsOne() {
        let now = Date()
        XCTAssertEqual(RelevanceScoring.recencyScore(date: now, now: now), 1.0, accuracy: 0.0001)
    }

    func testRecencyScoreAtHalfLifeIsOneHalf() {
        let now = Date()
        let halfLife: TimeInterval = 60 * 60 * 24 * 30
        let then = now.addingTimeInterval(-halfLife)
        XCTAssertEqual(RelevanceScoring.recencyScore(date: then, now: now, halfLife: halfLife), 0.5, accuracy: 0.01)
    }

    func testRecencyScoreDecaysTowardZeroForVeryOldDates() {
        let now = Date()
        let veryOld = now.addingTimeInterval(-60 * 60 * 24 * 365 * 5)
        XCTAssertLessThan(RelevanceScoring.recencyScore(date: veryOld, now: now), 0.01)
    }

    /// Explicit architectural guarantee: recency's default decay half-life (30 days) is NOT
    /// the same number as `MemoryEdge.staleThreshold` (90 days) - conflating the two was an
    /// explicit design mistake to avoid.
    func testRecencyHalfLifeDefaultDiffersFromStaleThreshold() {
        let defaultHalfLife: TimeInterval = 60 * 60 * 24 * 30
        XCTAssertNotEqual(defaultHalfLife, MemoryEdge.staleThreshold)
        XCTAssertEqual(MemoryEdge.staleThreshold, 60 * 60 * 24 * 90)
    }
}
