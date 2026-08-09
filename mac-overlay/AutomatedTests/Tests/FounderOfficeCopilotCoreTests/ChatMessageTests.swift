import XCTest
@testable import FounderOfficeCopilotCore

final class ChatMessageTests: XCTestCase {
    func testDefaultIsStreamingIsFalse() {
        let message = ChatMessage(role: .heard, text: "hello")
        XCTAssertFalse(message.isStreaming)
    }

    func testEachMessageGetsAUniqueID() {
        let a = ChatMessage(role: .heard, text: "a")
        let b = ChatMessage(role: .heard, text: "a")
        XCTAssertNotEqual(a.id, b.id, "two messages with identical content must still be distinct entries in the feed")
    }

    func testRolesAreDistinct() {
        let roles: [ChatMessage.Role] = [.heard, .response]
        XCTAssertEqual(Set(roles.map { "\($0)" }).count, roles.count, "each role case should be distinguishable")
    }
}
