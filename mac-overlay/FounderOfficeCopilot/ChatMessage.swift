import Foundation

// MARK: - Chat Message
/// One entry in the live meeting feed: either something heard (transcribed speech) or a
/// suggestion from the assistant. The overlay renders these as a scrollable chat instead
/// of fixed Topic/Suggestion/Timing boxes, so the whole session's history stays visible.
struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        /// The user's own mic, transcribed locally - never sent to Gemini directly
        case you
        /// Other meeting participants, via system audio output (Meeting mode)
        case heard
        /// "Say this" - a line to say to the room (Meeting mode)
        case suggestion
        /// A direct answer from the assistant (Personal Assistant mode)
        case assistantReply
    }

    let id = UUID()
    let role: Role
    var text: String
    let timestamp: Date = Date()
    /// True while an assistant suggestion/reply is still streaming in
    var isStreaming: Bool = false
}

/// Meeting mode: system audio (other participants) feeds Gemini, mic is local-only.
/// Personal Assistant mode: the user's own mic feeds Gemini directly - "as their master"
/// asking it something - and Gemini replies conversationally instead of staying silent.
enum AssistantMode {
    case meeting
    case personalAssistant
}
