import XCTest
@testable import FounderOfficeCopilotCore

/// Covers SessionSearch's pure filtering/grouping logic directly - kept separate from
/// SessionSidebarView (a SwiftUI view, not part of this test target) for exactly this reason.
final class SessionSearchTests: XCTestCase {
    private func makeSession(
        title: String,
        daysAgo: Int,
        isArchived: Bool = false,
        summary: String? = nil,
        messages: [ChatMessage] = [],
        now: Date,
        calendar: Calendar = .current
    ) -> ChatSession {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return ChatSession(id: UUID(), title: title, createdAt: date, updatedAt: date, lastMessageAt: date, isPinned: false, isArchived: isArchived, summary: summary, messages: messages)
    }

    // MARK: Grouping

    func testGroupsIntoTodayYesterdayOlder() {
        let now = Date()
        let today = makeSession(title: "Today Chat", daysAgo: 0, now: now)
        let yesterday = makeSession(title: "Yesterday Chat", daysAgo: 1, now: now)
        let older = makeSession(title: "Old Chat", daysAgo: 10, now: now)

        let groups = SessionSearch.grouped([today, yesterday, older], query: "", now: now)

        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "Older"])
        XCTAssertEqual(groups[0].sessions.map(\.title), ["Today Chat"])
        XCTAssertEqual(groups[1].sessions.map(\.title), ["Yesterday Chat"])
        XCTAssertEqual(groups[2].sessions.map(\.title), ["Old Chat"])
    }

    func testEmptyGroupsAreOmittedEntirely() {
        let now = Date()
        let today = makeSession(title: "Only Today", daysAgo: 0, now: now)
        let groups = SessionSearch.grouped([today], query: "", now: now)
        XCTAssertEqual(groups.map(\.title), ["Today"])
    }

    func testArchivedSessionsAreExcludedFromGrouping() {
        let now = Date()
        let archived = makeSession(title: "Archived", daysAgo: 0, isArchived: true, now: now)
        let groups = SessionSearch.grouped([archived], query: "", now: now)
        XCTAssertTrue(groups.isEmpty)
    }

    /// TIME-OF-DAY INDEPENDENT, deliberately.
    ///
    /// This used to build both sessions by subtracting hours from `Date()`, which meant that
    /// between roughly 00:00 and 03:00 local time the "3 hours ago" session fell into
    /// YESTERDAY while the "1 hour ago" one was still TODAY. The two then landed in different
    /// groups, `groups.first` held a single session, and the test failed - a real failure of
    /// the fixture, not of `SessionSearch`. It was a documented, tolerated flake for a long
    /// time; a test that only passes for 21 hours a day is not a test.
    ///
    /// Anchoring `now` at midday and spacing the sessions an hour apart puts both firmly
    /// inside the same calendar day in every timezone, so this now exercises the ORDERING rule
    /// it was always meant to exercise, and nothing else.
    func testSortedByMostRecentFirstWithinAGroup() {
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let earlier = ChatSession(id: UUID(), title: "Earlier", createdAt: now, updatedAt: now, lastMessageAt: calendar.date(byAdding: .hour, value: -3, to: now), isPinned: false, isArchived: false, summary: nil, messages: [])
        let later = ChatSession(id: UUID(), title: "Later", createdAt: now, updatedAt: now, lastMessageAt: calendar.date(byAdding: .hour, value: -1, to: now), isPinned: false, isArchived: false, summary: nil, messages: [])

        let groups = SessionSearch.grouped([earlier, later], query: "", now: now)
        XCTAssertEqual(groups.first?.sessions.map(\.title), ["Later", "Earlier"])
    }

    // MARK: Filtering

    func testFilterMatchesTitleCaseInsensitively() {
        let now = Date()
        let session = makeSession(title: "Investor Meeting", daysAgo: 0, now: now)
        XCTAssertEqual(SessionSearch.filtered([session], query: "investor").count, 1)
        XCTAssertEqual(SessionSearch.filtered([session], query: "product").count, 0)
    }

    func testFilterMatchesSummary() {
        let now = Date()
        let session = makeSession(title: "Untitled", daysAgo: 0, summary: "Discussed federated learning", now: now)
        XCTAssertEqual(SessionSearch.filtered([session], query: "federated").count, 1)
    }

    func testFilterMatchesMessageText() {
        let now = Date()
        let messages = [ChatMessage(role: .heard, text: "Let's talk about the revised forecast")]
        let session = makeSession(title: "Untitled", daysAgo: 0, messages: messages, now: now)
        XCTAssertEqual(SessionSearch.filtered([session], query: "forecast").count, 1)
    }

    func testEmptyOrWhitespaceQueryReturnsEverythingUnfiltered() {
        let now = Date()
        let sessions = [makeSession(title: "A", daysAgo: 0, now: now), makeSession(title: "B", daysAgo: 0, now: now)]
        XCTAssertEqual(SessionSearch.filtered(sessions, query: "").count, 2)
        XCTAssertEqual(SessionSearch.filtered(sessions, query: "   ").count, 2)
    }

    func testGroupingAppliesTheSearchFilterFirst() {
        let now = Date()
        let matching = makeSession(title: "Investor Meeting", daysAgo: 0, now: now)
        let nonMatching = makeSession(title: "Product Strategy", daysAgo: 0, now: now)
        let groups = SessionSearch.grouped([matching, nonMatching], query: "investor", now: now)
        XCTAssertEqual(groups.first?.sessions.map(\.title), ["Investor Meeting"])
    }

    func testNoMatchesProducesNoGroups() {
        let now = Date()
        let session = makeSession(title: "Investor Meeting", daysAgo: 0, now: now)
        XCTAssertTrue(SessionSearch.grouped([session], query: "nonexistent", now: now).isEmpty)
    }
}
