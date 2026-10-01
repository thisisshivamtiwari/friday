import XCTest
@testable import FounderOfficeCopilotCore

/// Covers ExtractionCandidate's plain value-type behavior and, most importantly,
/// ModalityPolicy's pure rules - the single most load-bearing logic in the whole extraction
/// pipeline (category 1: modality). No Core Data, no network, no ExtractionCoordinator here.
final class ExtractionCandidateTests: XCTestCase {
    // MARK: Category 1 - modality

    func testAllModalityValuesAreDistinct() {
        let all = ExtractionCandidate.Modality.allCases
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
        for modality: ExtractionCandidate.Modality in [.directStatement, .explicitDecision, .explicitTask, .suggestion, .speculation, .question, .hypothetical, .inference, .contradiction, .uncertain] {
            XCTAssertTrue(all.contains(modality))
        }
    }

    // MARK: Category 2/3 - question / hypothetical rejection

    func testQuestionsAreNeverPersistable() {
        XCTAssertFalse(ModalityPolicy.isEverPersistable(.question))
    }

    func testHypotheticalsAreNeverPersistable() {
        XCTAssertFalse(ModalityPolicy.isEverPersistable(.hypothetical))
    }

    func testInferenceAloneIsNeverPersistable() {
        // "Inference may ONLY resolve references... must never be the sole basis for creating
        // a new asserted fact" - a top-level .inference candidate is never persisted directly.
        XCTAssertFalse(ModalityPolicy.isEverPersistable(.inference))
    }

    func testDirectStatementExplicitDecisionExplicitTaskAreAlwaysPersistable() {
        for modality: ExtractionCandidate.Modality in [.directStatement, .explicitDecision, .explicitTask, .suggestion, .speculation, .contradiction, .uncertain] {
            XCTAssertTrue(ModalityPolicy.isEverPersistable(modality), "\(modality) must be eligible for persistence (subject to confidence/other gates)")
        }
    }

    // MARK: Category 4 - speculation/suggestion handling

    func testSuggestionAndSpeculationCapConfidence() {
        XCTAssertLessThanOrEqual(ModalityPolicy.effectiveConfidence(rawConfidence: 0.9, modality: .suggestion), 0.3)
        XCTAssertLessThanOrEqual(ModalityPolicy.effectiveConfidence(rawConfidence: 0.9, modality: .speculation), 0.3)
        XCTAssertLessThanOrEqual(ModalityPolicy.effectiveConfidence(rawConfidence: 0.9, modality: .uncertain), 0.3)
    }

    func testSuggestionAndSpeculationNeverExceedTheirOwnRawConfidenceWhenAlreadyLow() {
        // Capping must never RAISE a low confidence, only ever lower a high one.
        XCTAssertEqual(ModalityPolicy.effectiveConfidence(rawConfidence: 0.1, modality: .suggestion), 0.1)
    }

    func testDirectStatementConfidenceIsNeverCapped() {
        XCTAssertEqual(ModalityPolicy.effectiveConfidence(rawConfidence: 0.9, modality: .directStatement), 0.9)
    }

    func testSuggestionAndSpeculationNeverAllowActiveDecision() {
        XCTAssertFalse(ModalityPolicy.allowsActiveDecision(.suggestion))
        XCTAssertFalse(ModalityPolicy.allowsActiveDecision(.speculation))
        XCTAssertFalse(ModalityPolicy.allowsActiveDecision(.uncertain))
    }

    func testExplicitDecisionAllowsActiveDecision() {
        XCTAssertTrue(ModalityPolicy.allowsActiveDecision(.explicitDecision))
    }

    func testSuggestionAndSpeculationNeverAllowCompletedStatus() {
        XCTAssertFalse(ModalityPolicy.allowsCompletedStatus(.suggestion))
        XCTAssertFalse(ModalityPolicy.allowsCompletedStatus(.speculation))
    }

    func testDirectStatementAllowsCompletedStatus() {
        XCTAssertTrue(ModalityPolicy.allowsCompletedStatus(.directStatement))
    }

    // MARK: Codable round-trip (needed for real LLM JSON parsing - see ExtractionLLMClientTests)

    func testCandidateEncodesAndDecodesRoundTrip() throws {
        let candidate = ExtractionCandidate(
            type: .memoryEdge,
            modality: .directStatement,
            confidence: 0.7,
            isExplicit: true,
            subjectName: "self",
            predicate: "prefers",
            literalValue: "dark mode",
            memoryCategory: .preference
        )
        let data = try JSONEncoder().encode(candidate)
        let decoded = try JSONDecoder().decode(ExtractionCandidate.self, from: data)
        XCTAssertEqual(decoded, candidate)
    }

    func testCandidateInitializerAppliesDefaults() {
        let candidate = ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.8)
        XCTAssertFalse(candidate.isExplicit)
        XCTAssertNil(candidate.subjectName)
        XCTAssertNil(candidate.statement)
    }
}
