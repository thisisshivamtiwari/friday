import XCTest
@testable import FounderOfficeCopilotCore

/// Uses a dedicated test account name - never touches the real app's saved
/// "gemini-api-key" entry - and cleans up after itself.
final class KeychainStoreTests: XCTestCase {
    private let testAccount = "automated-tests-dummy-key-do-not-use"

    override func tearDown() {
        KeychainStore.delete(account: testAccount)
        super.tearDown()
    }

    func testSaveThenReadRoundTrips() {
        KeychainStore.saveString("test-value-123", account: testAccount)
        XCTAssertEqual(KeychainStore.readString(account: testAccount), "test-value-123")
    }

    func testReadBeforeSaveReturnsNil() {
        KeychainStore.delete(account: testAccount) // ensure clean slate
        XCTAssertNil(KeychainStore.readString(account: testAccount))
    }

    func testSaveOverwritesPreviousValue() {
        KeychainStore.saveString("first", account: testAccount)
        KeychainStore.saveString("second", account: testAccount)
        XCTAssertEqual(KeychainStore.readString(account: testAccount), "second")
    }

    func testDeleteRemovesTheValue() {
        KeychainStore.saveString("to-be-deleted", account: testAccount)
        KeychainStore.delete(account: testAccount)
        XCTAssertNil(KeychainStore.readString(account: testAccount))
    }

    func testDifferentAccountsAreIndependent() {
        let otherAccount = "automated-tests-dummy-key-2-do-not-use"
        defer { KeychainStore.delete(account: otherAccount) }

        KeychainStore.saveString("value-a", account: testAccount)
        KeychainStore.saveString("value-b", account: otherAccount)

        XCTAssertEqual(KeychainStore.readString(account: testAccount), "value-a")
        XCTAssertEqual(KeychainStore.readString(account: otherAccount), "value-b")
    }
}
