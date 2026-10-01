import Foundation
import Combine

// MARK: - Chat Session Manager
/// Owns every ChatSession and is the sole place messages get written - AIEngineController no
/// longer holds a `messages` array itself, it delegates here. This is what makes multi-chat
/// possible without touching the audio/Gemini pipeline at all: this class has NO reference to
/// AIEngineController, GeminiLiveClient, or GeminiResponseGenerator anywhere in its API, so
/// nothing it does can restart a connection or interrupt capture - not by convention, by
/// construction.
///
/// Two independent notions of "which session," per explicit design decision:
/// - `recordingSessionID` - the session live transcription/responses write into. Only ever
///   changes via beginRecording()/endRecording(), driven by Start/Stop listening.
/// - `viewingSessionID` - whatever the user is currently browsing in the UI. Free to change
///   at any time via switchViewing(), completely independent of recording.
///
/// Nothing is ever hard-deleted by the normal flows here (archive, not delete) - matching the
/// same "nothing silently removed" rule the chat history itself has always had.
final class ChatSessionManager: ObservableObject {
    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var recordingSessionID: UUID?
    @Published private(set) var viewingSessionID: UUID

    /// Explicitly designated via `recordHere(_:)` - "the next call to beginRecording()
    /// should use this session," nothing more. Deliberately NOT `@Published`: nothing needs
    /// to react to it beyond the sidebar (via `sidebarViewModel`'s existing structural
    /// snapshot mechanism), and adding a 4th `@Published` field here would widen what
    /// invalidates PrivateOverlayView for no reason - it doesn't touch recording or
    /// content at all until `beginRecording()` actually consumes it.
    private(set) var pendingRecordingSessionID: UUID?

    /// Derived, read-only projection for the sidebar - see SidebarViewModel's own doc
    /// comment. Only this file may write to it (`update` is `fileprivate`).
    let sidebarViewModel = SidebarViewModel()

    private let store: ChatSessionStore
    /// Tracks the in-progress "heard"/"response" bubble WITHIN the recording session, so
    /// streamed deltas append to the same message instead of creating a new one per chunk.
    /// There's only ever one pair of these, not one per session, because writes only ever
    /// target the single current recording session.
    private var activeHeardIndex: Int?
    private var activeResponseIndex: Int?

    /// `store` defaults to a real on-disk Core Data store; tests inject
    /// `ChatSessionStore(inMemory: true)` so they never touch the real app's saved history -
    /// same seam pattern as AIEngineController's `apiKeyProvider`.
    init(store: ChatSessionStore = ChatSessionStore()) {
        self.store = store
        let loaded = store.loadAllSessions()
        if let mostRecent = loaded.max(by: { $0.updatedAt < $1.updatedAt }) {
            sessions = loaded
            viewingSessionID = mostRecent.id
        } else {
            let bootstrap = Self.makeSession(title: Self.autoTitle())
            sessions = [bootstrap]
            viewingSessionID = bootstrap.id
            store.createSession(bootstrap)
        }
        refreshSidebarViewModel()
    }

    // MARK: Viewing (UI browsing - never touches recording)

    /// Switches what the UI displays. Deliberately does nothing else - no audio, no Gemini,
    /// no recording-state change of any kind. If `sessionID` doesn't exist, this is a no-op.
    func switchViewing(to sessionID: UUID) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        viewingSessionID = sessionID
        refreshSidebarViewModel()
    }

    var viewingSession: ChatSession? {
        sessions.first { $0.id == viewingSessionID }
    }

    // MARK: Session lifecycle (create/rename/archive/restore/delete)

    @discardableResult
    func createSession(title: String? = nil) -> UUID {
        let session = Self.makeSession(title: title ?? Self.autoTitle())
        sessions.append(session)
        store.createSession(session)
        refreshSidebarViewModel()
        return session.id
    }

    func rename(_ sessionID: UUID, to title: String) {
        mutate(sessionID) { $0.title = title }
    }

    func setArchived(_ sessionID: UUID, _ archived: Bool) {
        mutate(sessionID) { $0.isArchived = archived }
        if archived, pendingRecordingSessionID == sessionID {
            pendingRecordingSessionID = nil
            refreshSidebarViewModel()
        }
    }

    /// A real, permanent delete - separate from archive, expected to be rare and explicit.
    /// If the deleted session happened to be recording, viewing, or the pending recording
    /// target, all three fall back safely (recording just ends; a pending target is simply
    /// cleared; viewing falls back to whatever's left, or a fresh bootstrap session if that
    /// was the very last one).
    func delete(_ sessionID: UUID) {
        sessions.removeAll { $0.id == sessionID }
        store.deleteSession(sessionID)
        if recordingSessionID == sessionID {
            recordingSessionID = nil
            activeHeardIndex = nil
            activeResponseIndex = nil
        }
        if pendingRecordingSessionID == sessionID {
            pendingRecordingSessionID = nil
        }
        if viewingSessionID == sessionID {
            if let fallback = sessions.max(by: { $0.updatedAt < $1.updatedAt }) {
                viewingSessionID = fallback.id
            } else {
                let bootstrap = Self.makeSession(title: Self.autoTitle())
                sessions = [bootstrap]
                viewingSessionID = bootstrap.id
                store.createSession(bootstrap)
            }
        }
        refreshSidebarViewModel()
    }

    // MARK: Explicit recording target ("Record Here")

    /// Designates `sessionID` as where the NEXT call to `beginRecording()` should record
    /// into - does NOT start recording itself. No audio, no Gemini, no `recordingSessionID`
    /// change here at all: this class has no reference to AIEngineController or either
    /// Gemini client anywhere, so that's not just a rule this method follows, it's not
    /// something it's even capable of doing. A hard no-op while recording is already active
    /// (never silently redirects an in-progress recording - see beginRecording()'s doc
    /// comment for the "stop, then re-target, then start again" flow this enforces) or for a
    /// nonexistent/archived session.
    func recordHere(_ sessionID: UUID) {
        guard recordingSessionID == nil else { return }
        guard let session = sessions.first(where: { $0.id == sessionID }), !session.isArchived else { return }
        pendingRecordingSessionID = sessionID
        refreshSidebarViewModel()
    }

    /// Clears an explicit recording target without touching anything else - recording state,
    /// viewing state, and the audio/Gemini lifecycle are all completely unaffected. A no-op
    /// if there's no pending target to cancel.
    func cancelRecordingTarget() {
        guard pendingRecordingSessionID != nil else { return }
        pendingRecordingSessionID = nil
        refreshSidebarViewModel()
    }

    // MARK: Recording lifecycle (driven by AIEngineController.start()/stop())

    /// Idempotent - if already recording, returns the existing recording session. Otherwise,
    /// in priority order:
    /// 1. An explicit target from `recordHere(_:)`, if one is set and still valid (still
    ///    exists, not archived) - consumed exactly once, cleared here whether or not it was
    ///    usable, so a stale pointer (its session got deleted/archived meanwhile) never
    ///    lingers past this call.
    /// 2. Otherwise, the original automatic rule, byte-for-byte unchanged: reuse the most
    ///    recently updated session if it's completely empty (avoids leaving an orphaned blank
    ///    session behind from e.g. a Stop-then-immediately-Start blip, or from the very first
    ///    launch's bootstrap session), or create a fresh one if the most recent session
    ///    already has content.
    @discardableResult
    func beginRecording() -> UUID {
        if let recordingSessionID { return recordingSessionID }

        activeHeardIndex = nil
        activeResponseIndex = nil

        if let target = pendingRecordingSessionID {
            pendingRecordingSessionID = nil
            if sessions.contains(where: { $0.id == target && !$0.isArchived }) {
                recordingSessionID = target
                refreshSidebarViewModel()
                return target
            }
        }

        if let mostRecent = sessions.filter({ !$0.isArchived }).max(by: { $0.updatedAt < $1.updatedAt }),
           mostRecent.messages.isEmpty {
            recordingSessionID = mostRecent.id
            refreshSidebarViewModel()
            return mostRecent.id
        }

        // createSession() already calls refreshSidebarViewModel() once; refreshing again
        // right after picks up the recordingSessionID assignment too, at negligible extra
        // cost for what's already a low-frequency, user/lifecycle-driven event.
        let newID = createSession()
        recordingSessionID = newID
        refreshSidebarViewModel()
        return newID
    }

    /// Ends recording - `recordingSessionID` becomes nil, `viewingSessionID` is untouched.
    /// The session itself is NOT deleted or archived; it just stops receiving new content
    /// until beginRecording() runs again. Also clears any pending recording target: by
    /// construction this should already be nil here (recordHere() refuses to set one while
    /// recording, and beginRecording() always consumes/clears it before recording starts),
    /// but clearing it explicitly makes "no stale target survives a stop" true by reading
    /// this method alone, not by tracing through those guards elsewhere.
    func endRecording() {
        recordingSessionID = nil
        pendingRecordingSessionID = nil
        activeHeardIndex = nil
        activeResponseIndex = nil
        refreshSidebarViewModel()
    }

    var recordingSession: ChatSession? {
        recordingSessionID.flatMap { id in sessions.first { $0.id == id } }
    }

    /// Identity/streaming status for the recording session, WITHOUT exposing its `messages`
    /// array to the caller - see `viewingWindow(limit:)` below for why this matters. UI chrome
    /// that only needs "is Friday actively responding" / "what's the live session's title"
    /// should read this instead of the full `recordingSession`.
    struct RecordingSessionStatus {
        let id: UUID
        let title: String
        let isStreaming: Bool
    }

    var recordingSessionStatus: RecordingSessionStatus? {
        guard let recordingSessionID, let session = sessions.first(where: { $0.id == recordingSessionID }) else { return nil }
        return RecordingSessionStatus(id: session.id, title: session.title, isStreaming: session.messages.last?.isStreaming ?? false)
    }

    /// A bounded, independent snapshot of the viewed session's most recent messages, for
    /// long-chat rendering performance - see the diagnosis this implements for the full
    /// reasoning. Two things make this different from just reading `viewingSession.messages`:
    ///
    /// 1. Only the trailing `limit` messages are materialized, so a view that renders this
    ///    (e.g. a `ForEach`) has O(limit) work to do regardless of how long the session
    ///    actually is - `ForEach`'s diff/construct cost is proportional to what it's GIVEN, not
    ///    to the session's true length.
    /// 2. `Array(session.messages.suffix(limit))` allocates fresh, independent storage - it
    ///    does NOT alias `sessions[index].messages`'s backing buffer. That matters because
    ///    SwiftUI retains the view tree from the previous render (including whatever arrays it
    ///    captured) while diffing against the next one; if that captured array shared storage
    ///    with `sessions[index].messages`, the next `appendHeardDelta`/`appendResponseDelta`
    ///    mutation would force a copy-on-write copy of the ENTIRE underlying array before
    ///    writing. Returning an independent copy here means the view layer never holds a live
    ///    reference to the manager's backing storage, so that copy never has a reason to
    ///    happen - measured directly while diagnosing this (see the performance report).
    struct ViewingWindow {
        let sessionID: UUID?
        let title: String?
        let totalMessageCount: Int
        let recentMessages: [ChatMessage]

        var hasEarlierMessages: Bool { totalMessageCount > recentMessages.count }
    }

    func viewingWindow(limit: Int) -> ViewingWindow {
        guard let session = viewingSession else {
            return ViewingWindow(sessionID: nil, title: nil, totalMessageCount: 0, recentMessages: [])
        }
        return ViewingWindow(
            sessionID: session.id,
            title: session.title,
            totalMessageCount: session.messages.count,
            recentMessages: Array(session.messages.suffix(limit))
        )
    }

    // MARK: Writes - ALWAYS target recordingSessionID. None of these take a session
    // parameter, by design: there is no way to accidentally write into the viewed session
    // instead of the recording one, because the API doesn't accept a session argument at all.

    func appendHeardDelta(_ delta: String) {
        guard let recordingSessionID, let index = sessionIndex(recordingSessionID) else { return }
        if let messageIndex = activeHeardIndex, sessions[index].messages.indices.contains(messageIndex) {
            sessions[index].messages[messageIndex].text += delta
        } else {
            sessions[index].messages.append(ChatMessage(role: .heard, text: delta))
            activeHeardIndex = sessions[index].messages.count - 1
        }
        touch(index)
        let written = sessions[index].messages[activeHeardIndex!]
        store.appendOrUpdateMessage(written, sessionID: recordingSessionID)
        store.updateSessionMetadata(sessions[index])
    }

    /// Starts a new response bubble in the recording session and returns its id (nil if not
    /// currently recording). Also closes out the active heard bubble, so whatever's heard
    /// next starts a fresh one rather than appending onto pre-response content.
    @discardableResult
    func beginResponse() -> UUID? {
        guard let recordingSessionID, let index = sessionIndex(recordingSessionID) else { return nil }
        let message = ChatMessage(role: .response, text: "", isStreaming: true)
        sessions[index].messages.append(message)
        activeResponseIndex = sessions[index].messages.count - 1
        activeHeardIndex = nil
        touch(index)
        store.appendOrUpdateMessage(message, sessionID: recordingSessionID)
        return message.id
    }

    /// Mirrors `appendHeardDelta`'s `activeHeardIndex` cache: `activeResponseIndex` (set by
    /// `beginResponse()`, cleared by `completeResponse()`/`endRecording()`/`delete(_:)`) makes
    /// the common case O(1) instead of an O(n) `firstIndex(where:)` scan on every delta. The id
    /// check is a defensive fallback, not something expected to ever actually miss given the
    /// lifecycle above - if it ever did (a stale/wrong cache), this still self-heals via the
    /// scan rather than silently writing into the wrong message.
    func appendResponseDelta(_ delta: String, messageID: UUID) {
        guard let recordingSessionID, let index = sessionIndex(recordingSessionID) else { return }
        let messageIndex: Int
        if let cached = activeResponseIndex,
           sessions[index].messages.indices.contains(cached),
           sessions[index].messages[cached].id == messageID {
            messageIndex = cached
        } else if let found = sessions[index].messages.firstIndex(where: { $0.id == messageID }) {
            messageIndex = found
            activeResponseIndex = found
        } else {
            return
        }
        sessions[index].messages[messageIndex].text += delta
        store.appendOrUpdateMessage(sessions[index].messages[messageIndex], sessionID: recordingSessionID)
    }

    /// `errorText` is only applied if the message is still empty - a request that streamed in
    /// a real answer before failing partway through keeps that answer, per the "nothing ever
    /// silently replaced" rule.
    func completeResponse(messageID: UUID, errorText: String?) {
        guard let recordingSessionID, let index = sessionIndex(recordingSessionID),
              let messageIndex = sessions[index].messages.firstIndex(where: { $0.id == messageID }) else { return }
        if let errorText, sessions[index].messages[messageIndex].text.isEmpty {
            sessions[index].messages[messageIndex].text = errorText
        }
        sessions[index].messages[messageIndex].isStreaming = false
        if activeResponseIndex == messageIndex { activeResponseIndex = nil }
        store.appendOrUpdateMessage(sessions[index].messages[messageIndex], sessionID: recordingSessionID)
    }

    /// The default cap on `recentContext` - see `responseContext(recentContextLimit:)`.
    /// ~10 heard/response pairs' worth of prior conversation, enough for realistic follow-up
    /// questions without growing unbounded over a long session.
    static let defaultRecentContextLimit = 20

    /// Phase 2.5 - the character ceiling for the conversation text actually SENT to the response
    /// generator. Counted in characters, matching `ContextEngine`'s existing
    /// `maxEvidenceCharacterBudget` convention rather than inventing a token estimator.
    ///
    /// Why a character bound is needed on top of `defaultRecentContextLimit`: `appendHeardDelta`
    /// merges everything heard into ONE growing `.heard` message until a response starts, so the
    /// "current turn" is typically a single message, and a 30-minute gap between ⌘⇧R presses
    /// makes that one message enormous. A message-COUNT limit cannot bound it; only a
    /// character-level cap can.
    ///
    /// 24,000 characters is roughly 6k tokens of conversation - comfortably more than any normal
    /// stretch of speech between two responses, while keeping a pathological session bounded.
    /// Deliberately not user-configurable in this phase.
    static let defaultConversationCharacterLimit = 24_000

    /// The full context for a new response, scoped exclusively to the recording session -
    /// NEVER the viewed session, NEVER another ChatSession. Two parts, kept structurally
    /// separate rather than flattened into one blob:
    ///
    /// - `recentContext`: up to `recentContextLimit` messages immediately BEFORE the current
    ///   turn - bounded conversational history, so a follow-up question ("what was the
    ///   number?") can be resolved against what was actually just discussed.
    /// - `currentTurn`: everything `.heard` since the last response (what
    ///   `transcriptSinceLastResponse()` used to compute alone) - the actual new content
    ///   being answered.
    ///
    /// This replaces sending either "the whole session" (the original bug: an old, unrelated
    /// topic could get answered instead of the new one, because everything was flattened
    /// into one undifferentiated blob) or "only what's brand new" (the bug this fixes: a
    /// follow-up question about something said just before the last response had no way to
    /// reference it, since that content was excluded by construction). Bounding
    /// `recentContext` is what keeps this from regressing back to the original bug at long
    /// session lengths - it grows the context a little for continuity, not without limit.
    func responseContext(
        recentContextLimit: Int = ChatSessionManager.defaultRecentContextLimit,
        characterLimit: Int = ChatSessionManager.defaultConversationCharacterLimit
    ) -> ResponseContext {
        guard let session = recordingSession else {
            return ResponseContext(recentContext: [], currentTurn: [], characterLimit: characterLimit)
        }

        let lastResponseIndex = session.messages.lastIndex { $0.role == .response }
        let currentTurnStart = lastResponseIndex.map { $0 + 1 } ?? 0

        let currentTurn: [ChatMessage]
        if currentTurnStart < session.messages.count {
            currentTurn = session.messages[currentTurnStart...].filter { $0.role == .heard }
        } else {
            currentTurn = []
        }

        let recentContext = Array(session.messages[..<currentTurnStart].suffix(recentContextLimit))
        return ResponseContext(recentContext: recentContext, currentTurn: currentTurn, characterLimit: characterLimit)
    }

    // MARK: Helpers

    private func sessionIndex(_ id: UUID) -> Int? {
        sessions.firstIndex { $0.id == id }
    }

    /// A single combined assignment rather than two separate property writes - each write to
    /// `sessions` (a `@Published` array) fires one Combine `objectWillChange`, so this halves
    /// how many times PrivateOverlayView (which legitimately needs to observe every content
    /// delta) gets invalidated per call, found via direct measurement while diagnosing this
    /// phase's performance problem: `appendHeardDelta` was firing 3 invalidations per delta
    /// (the text write, then two here) before this fix.
    private func touch(_ index: Int) {
        var session = sessions[index]
        let now = Date()
        session.updatedAt = now
        session.lastMessageAt = now
        sessions[index] = session
    }

    private func mutate(_ sessionID: UUID, _ body: (inout ChatSession) -> Void) {
        guard let index = sessionIndex(sessionID) else { return }
        body(&sessions[index])
        sessions[index].updatedAt = Date()
        store.updateSessionMetadata(sessions[index])
        refreshSidebarViewModel()
    }

    /// Pushes a fresh structural snapshot into `sidebarViewModel` - called from every
    /// structural mutation method above (init, switchViewing, createSession, mutate via
    /// rename/setArchived, delete, beginRecording, endRecording, recordHere,
    /// cancelRecordingTarget), and ONLY those - never from
    /// appendHeardDelta/appendResponseDelta/completeResponse below, which is the entire point.
    private func refreshSidebarViewModel() {
        sidebarViewModel.update(
            summaries: sessions.map(SidebarViewModel.SessionSummary.init),
            recordingSessionID: recordingSessionID,
            viewingSessionID: viewingSessionID,
            pendingRecordingSessionID: pendingRecordingSessionID
        )
    }

    private static func makeSession(title: String) -> ChatSession {
        let now = Date()
        return ChatSession(
            id: UUID(),
            title: title,
            createdAt: now,
            updatedAt: now,
            lastMessageAt: nil,
            isPinned: false,
            isArchived: false,
            summary: nil,
            messages: []
        )
    }

    private static func autoTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Chat — \(formatter.string(from: Date()))"
    }
}

// MARK: - Response Context
/// The result of `ChatSessionManager.responseContext(recentContextLimit:)` - see its doc
/// comment for why this is two parts instead of one flattened string.
struct ResponseContext {
    let recentContext: [ChatMessage]
    /// The FULL, untrimmed content heard since the last response. Deliberately never trimmed:
    /// this is what the retrieval query is derived from (`AIEngineController.requestResponse()`
    /// -> `retrievedContextText(forCurrentTurn:)`), and Phase 4.2's grounding/evidence-
    /// sufficiency behaviour keys off that query text. Phase 2.5's character cap applies ONLY to
    /// what is sent to the response generator - see `boundedOrderedMessages`.
    let currentTurn: [ChatMessage]
    /// Character ceiling for `boundedOrderedMessages`; see
    /// `ChatSessionManager.defaultConversationCharacterLimit`.
    let characterLimit: Int

    init(recentContext: [ChatMessage], currentTurn: [ChatMessage], characterLimit: Int = ChatSessionManager.defaultConversationCharacterLimit) {
        self.recentContext = recentContext
        self.currentTurn = currentTurn
        self.characterLimit = characterLimit
    }

    /// Nothing new has been heard since the last response - `requestResponse()` treats this
    /// as a no-op, same as the old `transcriptSinceLastResponse()` being empty did.
    var isEmpty: Bool { currentTurn.isEmpty }

    /// All turns in chronological order, UNTRIMMED - unchanged from before Phase 2.5, and still
    /// what `ContextEngine` reads for `currentConversation`.
    var orderedMessages: [ChatMessage] { recentContext + currentTurn }

    /// What actually gets sent to the response generator: the same chronological messages,
    /// bounded to `characterLimit` in total.
    ///
    /// Trimming rules, in priority order:
    /// 1. The CURRENT TURN is the content being answered, so it is filled first and is the last
    ///    thing to be sacrificed. Recent history is background and is dropped/truncated first.
    /// 2. Within each part, the NEWEST content wins - messages are consumed newest-first, and a
    ///    message that only partially fits contributes its TAIL (its most recent characters).
    /// 3. A non-empty current turn never becomes empty: if the budget cannot fit even one
    ///    character, the newest message still contributes at least one.
    /// 4. Anything that fits entirely is passed through BYTE-FOR-BYTE, with its original id and
    ///    timestamp - below the limit this property is indistinguishable from `orderedMessages`.
    ///
    /// Truncated text carries no ellipsis or marker: nothing is invented into the prompt, and the
    /// budget stays exactly the budget. The full text always remains in `sessions` and in
    /// `ChatSessionStore` - this only bounds what is transmitted.
    var boundedOrderedMessages: [ChatMessage] {
        guard characterLimit > 0 else { return orderedMessages }
        let totalCharacters = orderedMessages.reduce(0) { $0 + $1.text.count }
        guard totalCharacters > characterLimit else { return orderedMessages }

        let (boundedTurn, remaining) = Self.fill(currentTurn, budget: characterLimit, guaranteeNonEmpty: true)
        let (boundedRecent, _) = Self.fill(recentContext, budget: remaining, guaranteeNonEmpty: false)
        return boundedRecent + boundedTurn
    }

    /// Consumes `messages` newest-first until `budget` is exhausted, returning them back in
    /// chronological order along with the unused budget. A partially-fitting message keeps its
    /// tail; a message with no room left is dropped entirely (unless `guaranteeNonEmpty` forces
    /// the newest one to survive with at least one character).
    private static func fill(_ messages: [ChatMessage], budget: Int, guaranteeNonEmpty: Bool) -> ([ChatMessage], Int) {
        var remaining = max(0, budget)
        var kept: [ChatMessage] = []
        for message in messages.reversed() {
            let count = message.text.count
            if count <= remaining {
                kept.append(message)
                remaining -= count
                continue
            }
            let allowance = (remaining == 0 && guaranteeNonEmpty && kept.isEmpty) ? 1 : remaining
            if allowance > 0 {
                var truncated = message
                truncated.text = String(message.text.suffix(allowance))
                kept.append(truncated)
                remaining = 0
            }
            break
        }
        return (kept.reversed(), remaining)
    }
}

// MARK: - Sidebar View Model
/// A derived, READ-ONLY projection of ChatSessionManager for the sidebar - never an
/// independent source of truth. `update(...)` is `fileprivate`, so only code in THIS file
/// (ChatSessionManager's own structural mutation methods) can ever call it - enforced by the
/// compiler, not just by convention. SessionSidebarView observes only this object, never
/// ChatSessionManager itself, and never mutates it.
///
/// The entire reason this exists: `refreshSidebarViewModel()` is called from every
/// STRUCTURAL method (create/rename/archive/delete/beginRecording/endRecording/switchViewing)
/// and deliberately NEVER from `appendHeardDelta`/`appendResponseDelta`/`completeResponse`,
/// which fire many times a second during live transcription/response streaming. Measured
/// directly while diagnosing this: 100 simulated transcription deltas fired 300
/// `ChatSessionManager.objectWillChange` events (three separate `sessions` mutations per
/// delta) - every one of which used to re-invoke SessionSidebarView.body, including a full
/// sort + date-bucketing pass of every session. This object receives zero of those.
///
/// Considered and rejected: a Combine `$sessions.map{...}.removeDuplicates()` derived
/// publisher instead of a second object - doesn't actually solve the problem, since the
/// summary needs `lastMessageAt` for "2m ago" display, and that field legitimately changes on
/// every content delta (see `touch(_:)` above), so a value-equality dedupe would still pass
/// through on every delta unless it silently excluded that field from `==` - a subtler,
/// harder-to-audit rule than "there is a short, explicit list of methods that call update()".
final class SidebarViewModel: ObservableObject {
    struct SessionSummary: Identifiable, Equatable {
        let id: UUID
        var title: String
        let createdAt: Date
        var updatedAt: Date
        var lastMessageAt: Date?
        var isArchived: Bool
        var isPinned: Bool

        init(_ session: ChatSession) {
            id = session.id
            title = session.title
            createdAt = session.createdAt
            updatedAt = session.updatedAt
            lastMessageAt = session.lastMessageAt
            isArchived = session.isArchived
            isPinned = session.isPinned
        }
    }

    struct SummaryGroup {
        let title: String
        let summaries: [SessionSummary]
    }

    /// Bundled into one struct behind a single `@Published` property rather than three
    /// separate `@Published` fields - each `@Published` assignment fires its own
    /// `objectWillChange`, so three separate fields would mean three invalidations per
    /// `update()` call instead of one (the exact class of bug `touch(_:)` above was fixed
    /// for - found here too, via the regression test written to prove this fix works).
    struct Snapshot {
        var summaries: [SessionSummary] = []
        var recordingSessionID: UUID?
        var viewingSessionID: UUID?
        var pendingRecordingSessionID: UUID?
    }

    @Published private(set) var snapshot = Snapshot()

    var summaries: [SessionSummary] { snapshot.summaries }
    var recordingSessionID: UUID? { snapshot.recordingSessionID }
    var viewingSessionID: UUID? { snapshot.viewingSessionID }
    /// The session designated via `recordHere(_:)` for the NEXT recording, if any - see
    /// ChatSessionManager.recordHere's doc comment. Nil whenever nothing has been designated,
    /// and always nil while actively recording (recordHere() refuses to set one then).
    var pendingRecordingSessionID: UUID? { snapshot.pendingRecordingSessionID }

    fileprivate func update(summaries: [SessionSummary], recordingSessionID: UUID?, viewingSessionID: UUID, pendingRecordingSessionID: UUID?) {
        snapshot = Snapshot(
            summaries: summaries,
            recordingSessionID: recordingSessionID,
            viewingSessionID: viewingSessionID,
            pendingRecordingSessionID: pendingRecordingSessionID
        )
    }

    /// Groups summaries into Today/Yesterday/Older - no filtering, since this is only ever
    /// used for the empty-search-query display (see SessionSidebarView); an active search
    /// query reads full ChatSession content via SessionSearch instead, which is unchanged.
    static func grouped(_ summaries: [SessionSummary], now: Date = Date(), calendar: Calendar = .current) -> [SummaryGroup] {
        let nonArchived = summaries.filter { !$0.isArchived }
        let sorted = nonArchived.sorted { ($0.lastMessageAt ?? $0.createdAt) > ($1.lastMessageAt ?? $1.createdAt) }

        var today: [SessionSummary] = []
        var yesterday: [SessionSummary] = []
        var older: [SessionSummary] = []
        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: now)

        for summary in sorted {
            let date = summary.lastMessageAt ?? summary.createdAt
            if calendar.isDate(date, inSameDayAs: now) {
                today.append(summary)
            } else if let yesterdayDate, calendar.isDate(date, inSameDayAs: yesterdayDate) {
                yesterday.append(summary)
            } else {
                older.append(summary)
            }
        }

        var groups: [SummaryGroup] = []
        if !today.isEmpty { groups.append(SummaryGroup(title: "Today", summaries: today)) }
        if !yesterday.isEmpty { groups.append(SummaryGroup(title: "Yesterday", summaries: yesterday)) }
        if !older.isEmpty { groups.append(SummaryGroup(title: "Older", summaries: older)) }
        return groups
    }
}
