import XCTest
@testable import FounderOfficeCopilotCore

/// Covers ExtractionHeuristics' pure, local pre-filter logic - no network, no Core Data.
final class ExtractionHeuristicsTests: XCTestCase {
    func testEmptyTextIsNotWorthExtracting() {
        XCTAssertFalse(ExtractionHeuristics.isWorthExtracting(""))
        XCTAssertFalse(ExtractionHeuristics.isWorthExtracting("   "))
    }

    func testFillerPhrasesAreNotWorthExtracting() {
        for filler in ["yeah", "ok", "Okay", "no", "hmm", "sure", "thanks", "got it"] {
            XCTAssertFalse(ExtractionHeuristics.isWorthExtracting(filler), "'\(filler)' should be filtered out")
        }
    }

    func testSubstantiveStatementIsWorthExtracting() {
        XCTAssertTrue(ExtractionHeuristics.isWorthExtracting("I prefer Apple-style interfaces."))
        XCTAssertTrue(ExtractionHeuristics.isWorthExtracting("Let's use Bayesian calibration for the XYZ algorithm."))
    }

    func testVeryShortTextIsNotWorthExtracting() {
        XCTAssertFalse(ExtractionHeuristics.isWorthExtracting("React"))
    }

    func testExplicitMemoryRequestDetection() {
        XCTAssertTrue(ExtractionHeuristics.looksLikeExplicitMemoryRequest("Remember that my favorite color is blue."))
        XCTAssertTrue(ExtractionHeuristics.looksLikeExplicitMemoryRequest("Don't forget that I prefer dark mode."))
        XCTAssertFalse(ExtractionHeuristics.looksLikeExplicitMemoryRequest("I prefer dark mode."))
    }

    func testCorrectionDetection() {
        XCTAssertTrue(ExtractionHeuristics.looksLikeCorrection("No, that's wrong. I prefer Vue."))
        XCTAssertTrue(ExtractionHeuristics.looksLikeCorrection("That's not right."))
        XCTAssertTrue(ExtractionHeuristics.looksLikeCorrection("Actually, I meant something else."))
        XCTAssertFalse(ExtractionHeuristics.looksLikeCorrection("I prefer dark mode."))
    }
}
