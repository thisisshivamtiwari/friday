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

    let id = UUID()
    let role: Role
    var text: String
    let timestamp: Date = Date()
    /// True while a response is still streaming in
    var isStreaming: Bool = false
}
