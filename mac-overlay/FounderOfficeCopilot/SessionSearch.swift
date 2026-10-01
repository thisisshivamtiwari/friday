import Foundation

/// Pure, UI-free session search/grouping logic for the sidebar - deliberately kept separate
/// from SessionSidebarView (a SwiftUI view, which per this project's convention is never part
/// of the test target - see AutomatedTests/README.md) so it's unit-testable without
/// instantiating any view. Same separation GeminiLiveMessageParser has from GeminiLiveClient.
///
/// Not a search index of any kind - just a case-insensitive substring filter over data that's
/// already fully in memory (ChatSessionManager loads every session and message at startup),
/// so there's nothing to build or maintain. Revisit only if that stops being true.
enum SessionSearch {
    struct Group {
        let title: String
        let sessions: [ChatSession]
    }

    /// Matches session title, summary, or any message's text - all cheap since it's an
    /// in-memory scan, no I/O.
    static func filtered(_ sessions: [ChatSession], query: String) -> [ChatSession] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sessions }
        return sessions.filter { session in
            if session.title.localizedCaseInsensitiveContains(trimmed) { return true }
            if let summary = session.summary, summary.localizedCaseInsensitiveContains(trimmed) { return true }
            return session.messages.contains { $0.text.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    /// Filters first, then groups the result into Today/Yesterday/Older (archived sessions
    /// excluded - they get their own disclosure section in the sidebar), most recent first
    /// within each group. Empty groups are omitted entirely rather than shown with a header
    /// and nothing under it. `now`/`calendar` are injectable for deterministic tests.
    static func grouped(_ sessions: [ChatSession], query: String, now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let nonArchived = filtered(sessions, query: query).filter { !$0.isArchived }
        let sorted = nonArchived.sorted { ($0.lastMessageAt ?? $0.createdAt) > ($1.lastMessageAt ?? $1.createdAt) }

        var today: [ChatSession] = []
        var yesterday: [ChatSession] = []
        var older: [ChatSession] = []
        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: now)

        for session in sorted {
            let date = session.lastMessageAt ?? session.createdAt
            if calendar.isDate(date, inSameDayAs: now) {
                today.append(session)
            } else if let yesterdayDate, calendar.isDate(date, inSameDayAs: yesterdayDate) {
                yesterday.append(session)
            } else {
                older.append(session)
            }
        }

        var groups: [Group] = []
        if !today.isEmpty { groups.append(Group(title: "Today", sessions: today)) }
        if !yesterday.isEmpty { groups.append(Group(title: "Yesterday", sessions: yesterday)) }
        if !older.isEmpty { groups.append(Group(title: "Older", sessions: older)) }
        return groups
    }
}
