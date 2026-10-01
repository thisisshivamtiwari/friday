import XCTest
@testable import FounderOfficeCopilotCore

/// Covers SensitiveContentGate's two-signal (credential-shaped-value AND contextual-cue)
/// policy - category 8. A large positive/negative matrix, since this is exactly the kind of
/// logic that needs explicit coverage of both "correctly blocks real credentials" and
/// "correctly does NOT block innocuous content that merely mentions a trigger word" - the
/// specific failure mode the approved design explicitly rejected (a bare keyword blocklist).
final class SensitiveContentGateTests: XCTestCase {
    // MARK: Must block - both signals present

    func testBlocksPasswordWithValue() {
        XCTAssertTrue(SensitiveContentGate.isSensitive("my password is Tr0ub4dor3xyzABCDEFGH123456"))
    }

    func testBlocksAPIKeyWithKnownPrefix() {
        XCTAssertTrue(SensitiveContentGate.isSensitive("the api key is sk-abc123def456ghi789jkl012"))
    }

    func testBlocksSSNShapedNumberWithContext() {
        XCTAssertTrue(SensitiveContentGate.isSensitive("my social security number is 123-45-6789"))
    }

    func testBlocksCreditCardShapedNumberWithContext() {
        XCTAssertTrue(SensitiveContentGate.isSensitive("here's my credit card number 4111111111111111"))
    }

    func testBlocksPINWithContext() {
        XCTAssertTrue(SensitiveContentGate.isSensitive("the PIN is 4729"))
    }

    func testBlocksPrivateKeyBlock() {
        XCTAssertTrue(SensitiveContentGate.isSensitive("here's my key -----BEGIN PRIVATE KEY----- password protected"))
    }

    func testBlocksLongTokenWithContext() {
        XCTAssertTrue(SensitiveContentGate.isSensitive("access token: a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5"))
    }

    // MARK: Must NOT block - only one signal present

    func testDoesNotBlockBareKeywordWithoutCredentialShapedValue() {
        // The exact case explicitly rejected: a trigger word alone must never block.
        XCTAssertFalse(SensitiveContentGate.isSensitive("that's our team's little secret"))
        XCTAssertFalse(SensitiveContentGate.isSensitive("I have a password manager I really like"))
    }

    func testDoesNotBlockBareShortNumberWithoutContext() {
        XCTAssertFalse(SensitiveContentGate.isSensitive("we had 4729 signups last month"))
        XCTAssertFalse(SensitiveContentGate.isSensitive("meet me at 1234 Main Street"))
    }

    func testDoesNotBlockCasualMentionOfTestingNumbers() {
        XCTAssertFalse(SensitiveContentGate.isSensitive("I'm testing you, the secret number is 4729"))
        // Note: this specific example is deliberately borderline - "secret" is a cue word but
        // "4729" is only 4 digits with no PIN-context cue among the recognized set, so it does
        // not block. This documents the actual boundary rather than asserting a "should" that
        // the two-signal design doesn't actually promise for every conceivable phrasing.
    }

    func testDoesNotBlockUnrelatedLongIdentifier() {
        // A long alphanumeric string alone (no context cue) - e.g. a UUID or hash mentioned
        // casually - must not block on shape alone.
        XCTAssertFalse(SensitiveContentGate.isSensitive("the commit hash was abcdef1234567890abcdef1234567890"))
    }

    func testDoesNotBlockOrdinaryConversation() {
        XCTAssertFalse(SensitiveContentGate.isSensitive("I prefer dark mode."))
        XCTAssertFalse(SensitiveContentGate.isSensitive("Let's use Bayesian calibration for the XYZ algorithm."))
    }

    // MARK: Candidate-level scanning (checks every relevant field, not just one)

    func testCandidateLevelGateScansLiteralValue() {
        let candidate = ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.8, predicate: "password", literalValue: "hunter2AAAAAAAAAAAAAAAAAAAA", memoryCategory: .fact)
        XCTAssertTrue(SensitiveContentGate.isSensitive(candidate))
    }

    func testCandidateLevelGateScansStatementAndReason() {
        let candidate = ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.8, statement: "use API key sk-abc123def456ghi789jkl012 for the integration", reason: nil)
        XCTAssertTrue(SensitiveContentGate.isSensitive(candidate))
    }

    func testCandidateLevelGatePassesOrdinaryCandidate() {
        let candidate = ExtractionCandidate(type: .projectItem, modality: .directStatement, confidence: 0.8, projectItemKind: .task, name: "Compare Bayesian calibration with baseline")
        XCTAssertFalse(SensitiveContentGate.isSensitive(candidate))
    }
}
