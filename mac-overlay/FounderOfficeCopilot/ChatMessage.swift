import Foundation

// MARK: - Chat Message
/// One entry in the live feed: either something heard (transcribed audio - your own voice
/// or anyone else's, mic or system audio, it's all just "what was said") or a response from
/// the assistant, generated on demand when triggered rather than automatically. There's no
/// "You" vs "Heard" distinction and no separate meeting/personal-assistant modes - this is a
/// single always-listening assistant that only speaks up when asked.
struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case heard
        case response
    }

    let id: UUID
    let role: Role
    var text: String
    let timestamp: Date
    /// True while a response is still streaming in
    var isStreaming: Bool

    /// `id`/`timestamp` default to freshly generated values, same as before this had an
    /// explicit initializer - existing call sites (`ChatMessage(role:text:)`) are unaffected.
    /// The explicit parameters exist so ChatSessionStore can restore a persisted message with
    /// its ORIGINAL identity and timestamp instead of minting new ones on every app relaunch.
    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date(), isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }
}
