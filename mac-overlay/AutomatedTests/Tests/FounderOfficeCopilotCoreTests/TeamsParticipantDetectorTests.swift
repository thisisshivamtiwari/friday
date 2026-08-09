import XCTest
@testable import FounderOfficeCopilotCore

final class TeamsParticipantDetectorTests: XCTestCase {
    func testAcceptsPlausibleNames() {
        XCTAssertTrue(TeamsParticipantDetector.isPlausibleParticipantName("Shivam Tiwari"))
        XCTAssertTrue(TeamsParticipantDetector.isPlausibleParticipantName("Jo"))
    }

    func testRejectsUIChromeLabels() {
        XCTAssertFalse(TeamsParticipantDetector.isPlausibleParticipantName("Mute"))
        XCTAssertFalse(TeamsParticipantDetector.isPlausibleParticipantName("More options"))
        XCTAssertFalse(TeamsParticipantDetector.isPlausibleParticipantName("Remove from meeting"))
        XCTAssertFalse(TeamsParticipantDetector.isPlausibleParticipantName("Pin"))
        XCTAssertFalse(TeamsParticipantDetector.isPlausibleParticipantName("Raised hand"))
        XCTAssertFalse(TeamsParticipantDetector.isPlausibleParticipantName("Shivam Tiwari (you)"))
    }

    func testRejectsTooShortOrTooLongStrings() {
        XCTAssertFalse(TeamsParticipantDetector.isPlausibleParticipantName("A"))
        XCTAssertFalse(TeamsParticipantDetector.isPlausibleParticipantName(""))
        XCTAssertFalse(TeamsParticipantDetector.isPlausibleParticipantName(String(repeating: "x", count: 61)))
    }

    func testTrimsWhitespaceBeforeChecking() {
        XCTAssertTrue(TeamsParticipantDetector.isPlausibleParticipantName("  Shivam  "))
    }

    func testIsCaseInsensitiveForChromeKeywords() {
        XCTAssertFalse(TeamsParticipantDetector.isPlausibleParticipantName("MUTE"))
    }
}
