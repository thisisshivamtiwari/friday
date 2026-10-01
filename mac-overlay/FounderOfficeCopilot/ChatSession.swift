import Foundation

// MARK: - Chat Session
/// A single persistent conversation - a container for ChatMessages, independent of Gemini's
/// own connection lifecycle. Exactly one session is ever the "recording" session at a time
/// (see ChatSessionManager.recordingSessionID) - the one live transcription and responses
/// write into - while the user may separately "view" (browse) any session at all, including
/// old ones, without that affecting what's actively being recorded.
/// https://developer.apple.com/documentation/foundation/uuid
struct ChatSession: Identifiable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var lastMessageAt: Date?
    var isPinned: Bool
    var isArchived: Bool
    var summary: String?
    var messages: [ChatMessage]
}
