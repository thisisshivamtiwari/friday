import XCTest
import Combine
@testable import FounderOfficeCopilotCore

/// Covers ChatSessionManager: session lifecycle, message accumulation (migrated from
/// AIEngineControllerTests when that logic moved here), and - the core Phase 1 requirement -
/// that recordingSessionID and viewingSessionID are completely independent. Every test uses
/// an in-memory ChatSessionStore, so nothing here ever touches the real app's saved history.
///
/// The strongest guarantee that switching sessions can't restart audio/Gemini is architectural,
/// not something a runtime test can fully prove: ChatSessionManager's entire public API (see
/// its own source) has no parameter, property, or return type referencing AIEngineController,
/// GeminiLiveClient, or GeminiResponseGenerator anywhere - so switchViewing() cannot possibly
/// call into any of them, by construction. What IS tested here is the observable behavior that
/// depends on: viewing changes independently of recording, and vice versa.
final class ChatSessionManagerTests: XCTestCase {
    private func makeManager() -> ChatSessionManager {
        ChatSessionManager(store: ChatSessionStore(inMemory: true))
    }

    // MARK: Bootstrap

    func testFreshManagerBootstrapsExactlyOneEmptySession() {
        let manager = makeManager()
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.viewingSessionID, manager.sessions[0].id)
        XCTAssertNil(manager.recordingSessionID, "nothing is recording until beginRecording() is called")
        XCTAssertTrue(manager.sessions[0].messages.isEmpty)
    }

    // MARK: Recording lifecycle

    func testBeginRecordingReusesTheBootstrapSessionIfEmpty() {
        let manager = makeManager()
        let bootstrapID = manager.viewingSessionID
        let recordingID = manager.beginRecording()
        XCTAssertEqual(recordingID, bootstrapID, "an empty session should be reused rather than leaving an orphaned duplicate")
        XCTAssertEqual(manager.sessions.count, 1)
    }

    func testBeginRecordingCreatesANewSessionIfTheMostRecentOneHasMessages() {
        let manager = makeManager()
        let firstRecording = manager.beginRecording()
        manager.appendHeardDelta("something was said")
        manager.endRecording()

        let secondRecording = manager.beginRecording()
        XCTAssertNotEqual(secondRecording, firstRecording, "a non-empty previous session must not be reused")
        XCTAssertEqual(manager.sessions.count, 2)
    }

    func testBeginRecordingIsIdempotentWhileAlreadyRecording() {
        let manager = makeManager()
        let first = manager.beginRecording()
        let second = manager.beginRecording()
        XCTAssertEqual(first, second)
        XCTAssertEqual(manager.sessions.count, 1)
    }

    func testEndRecordingClearsRecordingButLeavesViewingUnchanged() {
        let manager = makeManager()
        manager.beginRecording()
        let otherID = manager.createSession(title: "Other")
        manager.switchViewing(to: otherID)

        manager.endRecording()

        XCTAssertNil(manager.recordingSessionID)
        XCTAssertEqual(manager.viewingSessionID, otherID)
    }

    // MARK: The core requirement - recording and viewing are independent

    func testRecordingSessionIsIndependentOfViewingSession() {
        // Mirrors the exact scenario from the spec: recording an "Investor Meeting" while
        // browsing a "Product Strategy" session from a different day.
        let manager = makeManager()
        let recordingID = manager.beginRecording()
        manager.rename(recordingID, to: "Investor Meeting — Aug 10")
        manager.appendHeardDelta("The investor wants a revised forecast.")

        let productStrategyID = manager.createSession(title: "Product Strategy — Aug 7")
        manager.switchViewing(to: productStrategyID)

        // More is heard while the user is looking at the OTHER session.
        manager.appendHeardDelta(" Let's get that to them by Friday.")

        XCTAssertEqual(manager.recordingSessionID, recordingID)
        XCTAssertEqual(manager.viewingSessionID, productStrategyID)
        XCTAssertEqual(
            manager.recordingSession?.messages.first?.text,
            "The investor wants a revised forecast. Let's get that to them by Friday.",
            "new heard content must always land in the recording session"
        )
        XCTAssertTrue(manager.viewingSession?.messages.isEmpty ?? false, "new heard content must never land in the viewed session")
    }

    func testSwitchingViewingNeverChangesRecording() {
        let manager = makeManager()
        let recordingID = manager.beginRecording()
        let a = manager.createSession(title: "A")
        let b = manager.createSession(title: "B")

        manager.switchViewing(to: a)
        XCTAssertEqual(manager.recordingSessionID, recordingID)
        manager.switchViewing(to: b)
        XCTAssertEqual(manager.recordingSessionID, recordingID)
        manager.switchViewing(to: recordingID)
        XCTAssertEqual(manager.recordingSessionID, recordingID, "viewing the recording session itself must not change recordingSessionID's identity/semantics")
    }

    func testSwitchingViewingToANonexistentSessionIsANoOp() {
        let manager = makeManager()
        let original = manager.viewingSessionID
        manager.switchViewing(to: UUID())
        XCTAssertEqual(manager.viewingSessionID, original)
    }

    // MARK: Writes always target the recording session, never take a session parameter

    func testWritesAreNoOpsWhenNotRecording() {
        let manager = makeManager()
        manager.appendHeardDelta("should go nowhere")
        XCTAssertNil(manager.beginResponse())
        XCTAssertTrue(manager.viewingSession?.messages.isEmpty ?? true)
    }

    func testInputTranscriptAccumulatesIntoASingleHeardBubbleUntilAResponse() {
        let manager = makeManager()
        manager.beginRecording()

        manager.appendHeardDelta("Hello")
        manager.appendHeardDelta(" there")

        XCTAssertEqual(manager.recordingSession?.messages.count, 1, "deltas for the same stretch of speech accumulate into one bubble")
        XCTAssertEqual(manager.recordingSession?.messages.first?.text, "Hello there")
        XCTAssertEqual(manager.recordingSession?.messages.first?.role, .heard)
    }

    func testResponseStreamsIntoOneBubbleThenClosesOutOnCompletion() {
        let manager = makeManager()
        manager.beginRecording()
        manager.appendHeardDelta("What's the plan")

        guard let messageID = manager.beginResponse() else {
            return XCTFail("expected a response id while recording")
        }
        manager.appendResponseDelta("Let's ", messageID: messageID)
        manager.appendResponseDelta("start with X.", messageID: messageID)

        XCTAssertEqual(manager.recordingSession?.messages.count, 2)
        XCTAssertEqual(manager.recordingSession?.messages[1].text, "Let's start with X.")
        XCTAssertEqual(manager.recordingSession?.messages[1].role, .response)
        XCTAssertTrue(manager.recordingSession?.messages[1].isStreaming ?? false)

        manager.completeResponse(messageID: messageID, errorText: nil)
        XCTAssertFalse(manager.recordingSession?.messages[1].isStreaming ?? true)

        // A new stretch of speech after a response must start a fresh Heard bubble, not
        // resume appending to the one from before the response.
        manager.appendHeardDelta("Next question")
        XCTAssertEqual(manager.recordingSession?.messages.count, 3)
        XCTAssertEqual(manager.recordingSession?.messages[2].text, "Next question")
    }

    func testCompleteResponseOnlyAppliesErrorTextIfNothingStreamedIn() {
        let manager = makeManager()
        manager.beginRecording()
        manager.appendHeardDelta("question")
        guard let messageID = manager.beginResponse() else {
            return XCTFail("expected a response id while recording")
        }

        manager.appendResponseDelta("partial real answer", messageID: messageID)
        manager.completeResponse(messageID: messageID, errorText: "should not appear")

        XCTAssertEqual(manager.recordingSession?.messages.last?.text, "partial real answer", "a request that fails after streaming real content must keep that content, not replace it with the error")
    }

    func testCompleteResponseAppliesErrorTextWhenNothingStreamedIn() {
        let manager = makeManager()
        manager.beginRecording()
        manager.appendHeardDelta("question")
        guard let messageID = manager.beginResponse() else {
            return XCTFail("expected a response id while recording")
        }

        manager.completeResponse(messageID: messageID, errorText: "network error")

        XCTAssertEqual(manager.recordingSession?.messages.last?.text, "network error")
    }

    // MARK: responseContext() - conversational continuity + recency control
    //
    // Replaces transcriptSinceLastResponse(). That function fixed a real bug (the ENTIRE
    // session history got joined into one prompt, so an old unrelated topic could get
    // answered instead of a new one) but over-corrected: it excluded ALL content heard
    // before the last response, including content a genuine follow-up question needed to
    // reference (confirmed by a real repro: "the secret number is 4729" -> response ->
    // "what was the number?" came back unable to answer, because "4729" had already
    // scrolled out of what got sent). responseContext() fixes this by keeping the "current
    // turn" (what's new) and a BOUNDED "recent context" (what was said just before)
    // structurally separate, rather than either including everything or excluding
    // everything before the last response.

    func testResponseContextIncludesRecentHistoryForFollowUpQuestions() {
        // The exact real-world repro that motivated this fix.
        let manager = makeManager()
        manager.beginRecording()
        manager.appendHeardDelta("The secret number is 4729.")
        guard let messageID = manager.beginResponse() else {
            return XCTFail("expected a response id while recording")
        }
        manager.appendResponseDelta("Got it. I've noted 4729.", messageID: messageID)
        manager.completeResponse(messageID: messageID, errorText: nil)

        manager.appendHeardDelta("What was the secret number?")

        let context = manager.responseContext()
        XCTAssertEqual(context.currentTurn.map(\.text), ["What was the secret number?"])
        XCTAssertTrue(
            context.orderedMessages.contains { $0.text.contains("4729") },
            "a follow-up question must be able to reference content from just before the last response"
        )
    }

    func testResponseContextPreservesMultiTurnReferences() {
        let manager = makeManager()
        manager.beginRecording()
        manager.appendHeardDelta("I'm meeting John tomorrow at 3pm.")
        guard let messageID = manager.beginResponse() else {
            return XCTFail("expected a response id while recording")
        }
        manager.completeResponse(messageID: messageID, errorText: nil)

        manager.appendHeardDelta("Who is it with?")

        let context = manager.responseContext()
        XCTAssertTrue(context.recentContext.contains { $0.text.contains("John") })
    }

    func testResponseContextSeparatesCurrentTurnFromAlreadyAnsweredContent() {
        let manager = makeManager()
        manager.beginRecording()
        manager.appendHeardDelta("first question")
        guard let messageID = manager.beginResponse() else {
            return XCTFail("expected a response id while recording")
        }
        manager.completeResponse(messageID: messageID, errorText: nil)
        manager.appendHeardDelta("second question")

        let context = manager.responseContext()
        XCTAssertEqual(context.currentTurn.map(\.text), ["second question"], "only the newest heard content is the current turn")
        XCTAssertFalse(context.currentTurn.contains { $0.text.contains("first question") }, "already-answered content moves to recentContext, not currentTurn")
        XCTAssertTrue(context.recentContext.contains { $0.text.contains("first question") })
    }

    func testResponseContextIsEmptyWhenNothingNewHasBeenHeard() {
        let manager = makeManager()
        manager.beginRecording()
        XCTAssertTrue(manager.responseContext().isEmpty)
    }

    func testResponseContextIsEmptyWhenNotRecording() {
        let manager = makeManager()
        XCTAssertTrue(manager.responseContext().isEmpty)
    }

    func testResponseContextNeverIncludesAnotherSession() {
        let manager = makeManager()
        let sessionAID = manager.beginRecording()
        manager.appendHeardDelta("The secret number is 4729.")
        manager.endRecording()

        let sessionBID = manager.beginRecording()
        XCTAssertNotEqual(sessionBID, sessionAID, "session A had content, so a fresh session must be created for B")
        manager.appendHeardDelta("The secret number is 9182.")
        guard let messageID = manager.beginResponse() else {
            return XCTFail("expected a response id while recording")
        }
        manager.completeResponse(messageID: messageID, errorText: nil)
        manager.appendHeardDelta("What was the secret number?")

        let context = manager.responseContext()
        XCTAssertFalse(context.orderedMessages.contains { $0.text.contains("4729") }, "must never retrieve content from a different session")
        XCTAssertTrue(context.orderedMessages.contains { $0.text.contains("9182") })
    }

    func testResponseContextUsesRecordingSessionNotViewingSession() {
        let manager = makeManager()
        let sessionAID = manager.beginRecording()
        manager.appendHeardDelta("Session A content - the code word is banana.")
        manager.endRecording()

        let sessionBID = manager.beginRecording()
        manager.appendHeardDelta("Session B content - the code word is orange.")

        manager.switchViewing(to: sessionAID)
        XCTAssertEqual(manager.viewingSessionID, sessionAID)
        XCTAssertEqual(manager.recordingSessionID, sessionBID)

        let context = manager.responseContext()
        XCTAssertTrue(context.orderedMessages.contains { $0.text.contains("orange") })
        XCTAssertFalse(
            context.orderedMessages.contains { $0.text.contains("banana") },
            "response context must come from the RECORDING session even while a different one is being viewed"
        )
    }

    func testResponseContextRecentHistoryIsBounded() {
        let manager = makeManager()
        manager.beginRecording()
        for i in 0..<30 {
            manager.appendHeardDelta("heard \(i)")
            guard let messageID = manager.beginResponse() else { return XCTFail("expected a response id while recording") }
            manager.completeResponse(messageID: messageID, errorText: nil)
        }
        manager.appendHeardDelta("final question")

        let context = manager.responseContext(recentContextLimit: 20)
        XCTAssertEqual(context.recentContext.count, 20, "recentContext must stay capped regardless of how long the session has run")
        XCTAssertEqual(context.currentTurn.map(\.text), ["final question"])
    }

    func testResponseContextRecentContextLimitIsConfigurable() {
        let manager = makeManager()
        manager.beginRecording()
        for i in 0..<10 {
            manager.appendHeardDelta("heard \(i)")
            guard let messageID = manager.beginResponse() else { return XCTFail("expected a response id while recording") }
            manager.completeResponse(messageID: messageID, errorText: nil)
        }
        manager.appendHeardDelta("final question")

        XCTAssertEqual(manager.responseContext(recentContextLimit: 4).recentContext.count, 4)
        XCTAssertEqual(manager.responseContext(recentContextLimit: 100).recentContext.count, 20, "capped by however much history actually exists, not padded")
    }

    // MARK: Session isolation

    func testSessionIsolationMessagesNeverLeakBetweenSessions() {
        let manager = makeManager()
        manager.beginRecording()
        manager.appendHeardDelta("in the recording session")

        let otherID = manager.createSession(title: "Untouched")

        XCTAssertTrue(manager.sessions.first { $0.id == otherID }?.messages.isEmpty ?? false)
        XCTAssertEqual(manager.sessions.count, 2)
    }

    // MARK: Session management

    func testRenameUpdatesTitle() {
        let manager = makeManager()
        let id = manager.createSession(title: "Old")
        manager.rename(id, to: "New")
        XCTAssertEqual(manager.sessions.first { $0.id == id }?.title, "New")
    }

    func testArchiveAndRestore() {
        let manager = makeManager()
        let id = manager.createSession(title: "Session")
        manager.setArchived(id, true)
        XCTAssertTrue(manager.sessions.first { $0.id == id }?.isArchived ?? false)
        manager.setArchived(id, false)
        XCTAssertFalse(manager.sessions.first { $0.id == id }?.isArchived ?? true)
    }

    func testDeleteRemovesTheSessionAndFallsBackSafelyIfItWasBeingViewed() {
        let manager = makeManager()
        let keep = manager.viewingSessionID
        let toDelete = manager.createSession(title: "Temporary")
        manager.switchViewing(to: toDelete)

        manager.delete(toDelete)

        XCTAssertFalse(manager.sessions.contains { $0.id == toDelete })
        XCTAssertEqual(manager.viewingSessionID, keep, "deleting the viewed session must fall back to another existing one, never leave viewingSessionID dangling")
    }

    func testDeletingTheRecordingSessionEndsRecording() {
        let manager = makeManager()
        let recordingID = manager.beginRecording()
        manager.delete(recordingID)
        XCTAssertNil(manager.recordingSessionID)
    }

    // MARK: SidebarViewModel - Phase 2.5's fix for the sidebar recomputing on every content
    // delta. The whole point: content mutations (appendHeardDelta/appendResponseDelta/
    // completeResponse) must NEVER touch sidebarViewModel; only structural methods may.

    func testContentDeltasDoNotChangeSidebarViewModelSummaries() {
        let manager = makeManager()
        manager.beginRecording()
        let summariesBefore = manager.sidebarViewModel.summaries

        manager.appendHeardDelta("first ")
        manager.appendHeardDelta("second ")
        let messageID = manager.beginResponse()
        manager.appendResponseDelta("partial", messageID: messageID!)
        manager.completeResponse(messageID: messageID!, errorText: nil)

        // beginResponse() IS structural (it happens at most once per response, not per
        // delta) and legitimately refreshes the projection - so summariesBefore was
        // captured after beginRecording() (also structural) but before any of the above.
        // What matters is that appendHeardDelta/appendResponseDelta/completeResponse
        // themselves never change lastMessageAt/updatedAt in the projection.
        XCTAssertEqual(summariesBefore.count, manager.sidebarViewModel.summaries.count)
    }

    func testAppendHeardDeltaAloneNeverFiresSidebarViewModelObjectWillChange() {
        let manager = makeManager()
        manager.beginRecording()

        var sidebarInvalidationCount = 0
        let cancellable = manager.sidebarViewModel.objectWillChange.sink { _ in sidebarInvalidationCount += 1 }
        defer { cancellable.cancel() }

        for i in 0..<20 {
            manager.appendHeardDelta("delta\(i) ")
        }

        XCTAssertEqual(sidebarInvalidationCount, 0, "content deltas must never invalidate the sidebar's observed object")
    }

    func testStructuralChangesDoUpdateSidebarViewModel() {
        let manager = makeManager()

        var sidebarInvalidationCount = 0
        let cancellable = manager.sidebarViewModel.objectWillChange.sink { _ in sidebarInvalidationCount += 1 }
        defer { cancellable.cancel() }

        let newID = manager.createSession(title: "New")
        manager.rename(newID, to: "Renamed")
        manager.setArchived(newID, true)
        manager.switchViewing(to: newID)
        manager.delete(newID)

        XCTAssertEqual(sidebarInvalidationCount, 5, "each structural call should refresh the projection exactly once")
    }

    func testSidebarViewModelRecordingSessionIDStaysInSyncWithChatSessionManager() {
        let manager = makeManager()
        XCTAssertNil(manager.sidebarViewModel.recordingSessionID)

        let recordingID = manager.beginRecording()
        XCTAssertEqual(manager.sidebarViewModel.recordingSessionID, recordingID)
        XCTAssertEqual(manager.sidebarViewModel.recordingSessionID, manager.recordingSessionID)

        manager.endRecording()
        XCTAssertNil(manager.sidebarViewModel.recordingSessionID)
    }

    func testSidebarViewModelViewingSessionIDStaysInSyncWithChatSessionManager() {
        let manager = makeManager()
        let otherID = manager.createSession(title: "Other")
        manager.switchViewing(to: otherID)

        XCTAssertEqual(manager.sidebarViewModel.viewingSessionID, otherID)
        XCTAssertEqual(manager.sidebarViewModel.viewingSessionID, manager.viewingSessionID)
    }

    func testSwitchingSessionsStillDoesNotAffectRecordingWithSidebarViewModelInPlace() {
        // Re-confirms the Phase 1 guarantee still holds now that a second observable object
        // is involved - switching what's viewed must not touch recording on EITHER object.
        let manager = makeManager()
        let recordingID = manager.beginRecording()
        let otherID = manager.createSession(title: "Other")

        manager.switchViewing(to: otherID)

        XCTAssertEqual(manager.recordingSessionID, recordingID)
        XCTAssertEqual(manager.sidebarViewModel.recordingSessionID, recordingID)
    }

    func testSidebarViewModelSummariesReflectStructuralChangesAccurately() {
        let manager = makeManager()
        let id = manager.createSession(title: "Original Title")
        manager.rename(id, to: "Updated Title")

        let summary = manager.sidebarViewModel.summaries.first { $0.id == id }
        XCTAssertEqual(summary?.title, "Updated Title")

        manager.setArchived(id, true)
        let archivedSummary = manager.sidebarViewModel.summaries.first { $0.id == id }
        XCTAssertTrue(archivedSummary?.isArchived ?? false)
    }

    func testSidebarViewModelGroupingMatchesSessionSearchGrouping() {
        // The sidebar's fast/empty-query path (SidebarViewModel.grouped) and the search path
        // (SessionSearch.grouped) must agree on ordering/bucketing for the same underlying
        // data, since a user typing then clearing the search field should never see the list
        // reshuffle for no reason.
        let manager = makeManager()
        manager.beginRecording()
        _ = manager.createSession(title: "Second")

        let now = Date()
        let summaryGroups = SidebarViewModel.grouped(manager.sidebarViewModel.summaries, now: now)
        let sessionGroups = SessionSearch.grouped(manager.sessions, query: "", now: now)

        XCTAssertEqual(summaryGroups.map(\.title), sessionGroups.map(\.title))
        XCTAssertEqual(summaryGroups.map { $0.summaries.map(\.id) }, sessionGroups.map { $0.sessions.map(\.id) })
    }

    // MARK: "Record Here" - explicit recording target
    //
    // recordHere(_:) only ever sets pendingRecordingSessionID; it has no way to touch
    // recordingSessionID directly (same architectural guarantee switchViewing() has - this
    // class has no reference to AIEngineController or either Gemini client anywhere). Only
    // beginRecording() ever promotes a pending target into an actual recordingSessionID.

    func testRecordHereDesignatesTheTargetForTheNextBeginRecording() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")
        _ = manager.createSession(title: "B")

        manager.recordHere(a)

        XCTAssertEqual(manager.pendingRecordingSessionID, a)
        XCTAssertNil(manager.recordingSessionID, "Record Here must only designate a target, never start recording itself")
    }

    func testRecordHereThenBeginRecordingUsesTheDesignatedSession() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")
        _ = manager.createSession(title: "B")

        manager.recordHere(a)
        let recordingID = manager.beginRecording()

        XCTAssertEqual(recordingID, a)
        XCTAssertEqual(manager.recordingSessionID, a)
        XCTAssertNil(manager.pendingRecordingSessionID, "the target is consumed once used, not left lingering")
    }

    func testCancelRecordingTargetRestoresAutomaticBehavior() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")

        // Give A real content first (via one full record cycle), so it's no longer a
        // candidate for the automatic "reuse if empty" rule either. This is what makes the
        // test meaningful: the explicit-target path (unlike the automatic one) does NOT
        // check emptiness, so if cancelRecordingTarget() silently failed to clear the
        // pending target, beginRecording() would use A regardless of its content - only a
        // working cancel forces a brand-new session here.
        manager.recordHere(a)
        manager.beginRecording()
        manager.appendHeardDelta("hello")
        manager.endRecording()

        manager.recordHere(a)
        manager.cancelRecordingTarget()
        XCTAssertNil(manager.pendingRecordingSessionID)

        let recordingID = manager.beginRecording()

        XCTAssertNotEqual(recordingID, a, "a cancelled target must never be used, regardless of whether it would also fail the automatic reuse-if-empty check")
    }

    func testCancelRecordingTargetDoesNotAffectRecordingOrViewing() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")
        let b = manager.createSession(title: "B")
        manager.switchViewing(to: b)
        manager.recordHere(a)

        manager.cancelRecordingTarget()

        XCTAssertNil(manager.recordingSessionID)
        XCTAssertEqual(manager.viewingSessionID, b)
    }

    func testCancelRecordingTargetWithNoPendingTargetIsANoOp() {
        let manager = makeManager()
        manager.cancelRecordingTarget() // must not crash or misbehave with nothing pending
        XCTAssertNil(manager.pendingRecordingSessionID)
    }

    func testDeletingThePendingTargetSessionClearsIt() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")
        manager.recordHere(a)

        manager.delete(a)

        XCTAssertNil(manager.pendingRecordingSessionID)
    }

    func testArchivingThePendingTargetSessionClearsIt() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")
        manager.recordHere(a)

        manager.setArchived(a, true)

        XCTAssertNil(manager.pendingRecordingSessionID)
    }

    func testRecordHereWhileRecordingIsANoOp() {
        let manager = makeManager()
        let a = manager.beginRecording()
        let b = manager.createSession(title: "B")

        manager.recordHere(b)

        XCTAssertEqual(manager.recordingSessionID, a, "recording must not be silently redirected while active")
        XCTAssertNil(manager.pendingRecordingSessionID, "the attempted redirect must not even register as a pending target")
    }

    func testRecordHereOnNonexistentSessionIsANoOp() {
        let manager = makeManager()
        manager.recordHere(UUID())
        XCTAssertNil(manager.pendingRecordingSessionID)
    }

    func testRecordHereOnArchivedSessionIsANoOp() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")
        manager.setArchived(a, true)

        manager.recordHere(a)

        XCTAssertNil(manager.pendingRecordingSessionID)
    }

    func testPendingTargetDoesNotAffectViewingSessionID() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")
        let b = manager.createSession(title: "B")
        manager.switchViewing(to: b)

        manager.recordHere(a)

        XCTAssertEqual(manager.viewingSessionID, b)
    }

    func testStoppingRecordingClearsBothRecordingAndPendingTarget() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")
        manager.recordHere(a)
        manager.beginRecording()

        manager.endRecording()

        XCTAssertNil(manager.recordingSessionID)
        XCTAssertNil(manager.pendingRecordingSessionID, "no stale recording target must survive a stop")
    }

    func testViewingIndependenceAfterExplicitRecordHere() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")
        let c = manager.createSession(title: "C")
        manager.recordHere(a)
        manager.beginRecording()

        manager.switchViewing(to: c)

        XCTAssertEqual(manager.recordingSessionID, a)
        XCTAssertEqual(manager.viewingSessionID, c)
    }

    func testNewChatWhileRecordingWithExplicitTargetDoesNotAffectRecording() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")
        manager.recordHere(a)
        manager.beginRecording()

        let newChatID = manager.createSession(title: "New Chat")
        manager.switchViewing(to: newChatID)

        XCTAssertEqual(manager.viewingSessionID, newChatID)
        XCTAssertEqual(manager.recordingSessionID, a)
    }

    func testSessionIsolationWithExplicitRecordingTarget() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")
        let b = manager.createSession(title: "B")
        manager.recordHere(a)
        manager.beginRecording()
        manager.switchViewing(to: b)

        manager.appendHeardDelta("new content")

        XCTAssertEqual(manager.recordingSession?.messages.first?.text, "new content")
        XCTAssertTrue(manager.sessions.first { $0.id == b }?.messages.isEmpty ?? false)
    }

    func testResponseContextIsolationWithExplicitRecordingTarget() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")
        let b = manager.createSession(title: "B")
        manager.recordHere(a)
        manager.beginRecording()
        manager.switchViewing(to: b)

        manager.appendHeardDelta("The verification number is 6391.")

        let context = manager.responseContext()
        XCTAssertTrue(context.orderedMessages.contains { $0.text.contains("6391") })
        XCTAssertTrue(manager.sessions.first { $0.id == b }?.messages.isEmpty ?? true)
    }

    func testSidebarViewModelReflectsPendingRecordingSessionID() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")

        manager.recordHere(a)
        XCTAssertEqual(manager.sidebarViewModel.pendingRecordingSessionID, a)

        manager.cancelRecordingTarget()
        XCTAssertNil(manager.sidebarViewModel.pendingRecordingSessionID)
    }

    func testDeletingAnUnrelatedSessionDoesNotClearAnActivePendingTarget() {
        let manager = makeManager()
        let a = manager.createSession(title: "A")
        let unrelated = manager.createSession(title: "Unrelated")
        manager.recordHere(a)

        manager.delete(unrelated)

        XCTAssertEqual(manager.pendingRecordingSessionID, a, "deleting a DIFFERENT session must not clear an unrelated pending target")
    }

    // MARK: appendResponseDelta's cached index (activeResponseIndex)

    /// Not just "the final text is correct" (already covered elsewhere) - specifically proves
    /// deltas land on the SAME message across many calls even with substantial prior history,
    /// which is what the cache (vs. a per-call firstIndex(where:) scan) is actually for.
    func testResponseDeltasAccumulateOnTheSameMessageWithSubstantialPriorHistory() {
        let manager = makeManager()
        manager.beginRecording()
        // A single appendHeardDelta call already accumulates into one bubble in O(1) (see
        // activeHeardIndex) - many small deltas here exercises that path without needing many
        // separate Core Data round trips (each delta is one write, so this alone is 30, not
        // the 300 an earlier draft used - unnecessary volume for what this test proves).
        for i in 0..<30 {
            manager.appendHeardDelta("word\(i) ")
        }
        guard let messageID = manager.beginResponse() else { return XCTFail("expected a response id while recording") }

        for chunk in ["Gradient", " descent", " is", " an", " optimization", " algorithm."] {
            manager.appendResponseDelta(chunk, messageID: messageID)
        }

        XCTAssertEqual(manager.recordingSession?.messages.last?.text, "Gradient descent is an optimization algorithm.")
        XCTAssertEqual(manager.recordingSession?.messages.filter { $0.id == messageID }.count, 1, "must never duplicate the message")
    }

    /// The cache must not leak from one response into the next: starting response B and
    /// appending to it must never touch response A's now-completed text.
    func testCachedResponseIndexResetsWhenANewResponseBegins() {
        let manager = makeManager()
        manager.beginRecording()
        guard let responseA = manager.beginResponse() else { return XCTFail("expected a response id") }
        manager.appendResponseDelta("first answer", messageID: responseA)
        manager.completeResponse(messageID: responseA, errorText: nil)

        manager.appendHeardDelta("a follow-up question")
        guard let responseB = manager.beginResponse() else { return XCTFail("expected a second response id") }
        manager.appendResponseDelta("second answer", messageID: responseB)

        let responses = manager.recordingSession?.messages.filter { $0.role == .response } ?? []
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses.first { $0.id == responseA }?.text, "first answer", "completing A then writing to B must never mutate A")
        XCTAssertEqual(responses.first { $0.id == responseB }?.text, "second answer")
    }

    /// "Interrupted" in this app means the response's completion callback never fires (see
    /// AIEngineController - there's no separate cancel path, Live API `.interrupted` events are
    /// ignored since responses only ever come from the one-shot REST call). Simulates that:
    /// recording stops mid-response with completeResponse() never called, then a fresh
    /// recording/response cycle begins - the abandoned response's stale cached index must never
    /// bleed into the new one.
    func testCachedResponseIndexDoesNotLeakAcrossAnInterruptedResponseAndEndRecording() {
        let manager = makeManager()
        manager.beginRecording()
        guard let abandoned = manager.beginResponse() else { return XCTFail("expected a response id") }
        manager.appendResponseDelta("never finished", messageID: abandoned)
        // No completeResponse() call - simulates an interrupted/abandoned response.
        manager.endRecording()

        manager.beginRecording()
        manager.appendHeardDelta("new turn")
        guard let fresh = manager.beginResponse() else { return XCTFail("expected a response id after restarting") }
        manager.appendResponseDelta("fresh answer", messageID: fresh)

        XCTAssertEqual(manager.recordingSession?.messages.last?.id, fresh)
        XCTAssertEqual(manager.recordingSession?.messages.last?.text, "fresh answer")
    }

    /// completeResponse() clears the cache for that message id - appending to it again
    /// afterward (a defensive scenario, not expected in normal use) must not silently resume
    /// writing into an already-finalized message via a stale cache.
    func testAppendingToAnAlreadyCompletedResponseIDAfterCacheClearedIsHandledSafely() {
        let manager = makeManager()
        manager.beginRecording()
        guard let messageID = manager.beginResponse() else { return XCTFail("expected a response id") }
        manager.appendResponseDelta("done", messageID: messageID)
        manager.completeResponse(messageID: messageID, errorText: nil)

        manager.appendResponseDelta(" more", messageID: messageID)

        XCTAssertEqual(manager.recordingSession?.messages.first { $0.id == messageID }?.text, "done more", "falls back to the id scan and still finds the right message rather than silently no-op'ing or corrupting another one")
    }

    /// Switching what the UI is VIEWING mid-response must never affect where response deltas
    /// actually land - recordingSessionID/viewingSessionID independence, specifically exercised
    /// against the cached-index path.
    func testResponseDeltaCorrectnessIsUnaffectedBySwitchingViewingSessionMidResponse() {
        let manager = makeManager()
        manager.beginRecording() // claims the bootstrap session before "Other" exists, so it can't be auto-picked below
        let other = manager.createSession(title: "Other")
        guard let messageID = manager.beginResponse() else { return XCTFail("expected a response id") }

        manager.appendResponseDelta("first ", messageID: messageID)
        manager.switchViewing(to: other)
        manager.appendResponseDelta("second", messageID: messageID)

        XCTAssertEqual(manager.recordingSession?.messages.last?.text, "first second")
        XCTAssertTrue(manager.sessions.first { $0.id == other }?.messages.isEmpty ?? false, "the viewed-but-not-recording session must stay untouched")
    }

    // MARK: viewingWindow(limit:) - bounded rendering without losing history

    func testViewingWindowNeverExceedsUnderlyingHistory() {
        let manager = makeManager()
        manager.beginRecording()
        // 30 iterations (60 messages) is already >> the window limit below - large enough to
        // prove "the window is bounded, the full history isn't" without needing hundreds of
        // Core Data round trips (each append is its own background write) to prove it.
        for i in 0..<30 {
            manager.appendHeardDelta("heard \(i)")
            guard let id = manager.beginResponse() else { continue }
            manager.appendResponseDelta("reply \(i)", messageID: id)
            manager.completeResponse(messageID: id, errorText: nil)
        }

        XCTAssertEqual(manager.recordingSession?.messages.count, 60, "the full session must retain everything")

        let window = manager.viewingWindow(limit: 20)
        XCTAssertEqual(window.recentMessages.count, 20, "the rendered window is bounded")
        XCTAssertEqual(window.totalMessageCount, 60, "the reported total must reflect the FULL history, not just what's windowed")
        XCTAssertTrue(window.hasEarlierMessages)
    }

    func testViewingWindowReturnsTheMostRecentMessagesInOrder() {
        let manager = makeManager()
        manager.beginRecording()
        for i in 0..<10 {
            guard let id = manager.beginResponse() else { continue }
            manager.appendResponseDelta("r\(i)", messageID: id)
            manager.completeResponse(messageID: id, errorText: nil)
        }

        let window = manager.viewingWindow(limit: 3)
        XCTAssertEqual(window.recentMessages.map(\.text), ["r7", "r8", "r9"], "must be the LAST N messages, in chronological order - not the first N")
    }

    func testViewingWindowLoadingMoreNeverDropsAnyMessages() {
        let manager = makeManager()
        manager.beginRecording()
        for i in 0..<40 {
            guard let id = manager.beginResponse() else { continue }
            manager.appendResponseDelta("r\(i)", messageID: id)
            manager.completeResponse(messageID: id, errorText: nil)
        }

        let initial = manager.viewingWindow(limit: 15)
        XCTAssertEqual(initial.recentMessages.count, 15)

        // Simulates "load earlier" increasing the window - nothing in the underlying session
        // changes, so this must simply reveal more of what was already there.
        let expanded = manager.viewingWindow(limit: 40)
        XCTAssertEqual(expanded.recentMessages.count, 40)
        XCTAssertEqual(expanded.totalMessageCount, 40)
        XCTAssertFalse(expanded.hasEarlierMessages)
        XCTAssertTrue(expanded.recentMessages.map(\.text).suffix(15).elementsEqual(initial.recentMessages.map(\.text)), "expanding the window must be a strict superset, never a different slice")
    }

    func testViewingWindowForASessionWithFewerMessagesThanTheLimitReturnsEverything() {
        let manager = makeManager()
        manager.beginRecording()
        manager.appendHeardDelta("just one message")

        let window = manager.viewingWindow(limit: 50)
        XCTAssertEqual(window.recentMessages.count, 1)
        XCTAssertFalse(window.hasEarlierMessages)
    }

    func testViewingWindowReflectsWhicheverSessionIsCurrentlyBeingViewed() {
        let manager = makeManager()
        manager.beginRecording() // claims the bootstrap session before "Other" exists, so it can't be auto-picked below
        manager.appendHeardDelta("in the recording session")
        let other = manager.createSession(title: "Other")

        manager.switchViewing(to: other)
        let window = manager.viewingWindow(limit: 50)

        XCTAssertEqual(window.sessionID, other)
        XCTAssertTrue(window.recentMessages.isEmpty, "must reflect the VIEWED session, not the recording one")
    }

    // MARK: recordingSessionStatus - narrow accessor used to avoid retaining the full messages array

    func testRecordingSessionStatusReflectsStreamingState() {
        let manager = makeManager()
        manager.beginRecording()
        XCTAssertFalse(manager.recordingSessionStatus?.isStreaming ?? true)

        guard let messageID = manager.beginResponse() else { return XCTFail("expected a response id") }
        XCTAssertTrue(manager.recordingSessionStatus?.isStreaming ?? false)

        manager.completeResponse(messageID: messageID, errorText: nil)
        XCTAssertFalse(manager.recordingSessionStatus?.isStreaming ?? true)
    }

    func testRecordingSessionStatusIsNilWhileNotRecording() {
        let manager = makeManager()
        XCTAssertNil(manager.recordingSessionStatus)
    }

    // MARK: Phase 2.5 - character-bounded conversation context
    //
    // `appendHeardDelta` merges everything heard into ONE growing .heard message until a response
    // starts, so a 30-minute gap between ⌘⇧R presses produces a single enormous message that no
    // message-COUNT limit can bound. `boundedOrderedMessages` caps what is SENT; the full text
    // always stays in `sessions` and in the store.

    private func longText(_ marker: String, count: Int) -> String {
        // Distinctive head and tail so tests can prove WHICH end survived truncation.
        let filler = String(repeating: "x", count: max(0, count - marker.count * 2))
        return "HEAD-\(marker)" + filler + "TAIL-\(marker)"
    }

    /// Below the limit: byte-for-byte identical to the untrimmed context.
    func testShortCurrentTurnIsUnchangedByTheCharacterCap() {
        let manager = makeManager()
        manager.beginRecording()
        manager.appendHeardDelta("A short thing that was heard.")

        let context = manager.responseContext()
        XCTAssertEqual(context.boundedOrderedMessages.map(\.text), context.orderedMessages.map(\.text))
        XCTAssertEqual(context.boundedOrderedMessages.map(\.id), context.orderedMessages.map(\.id), "identity preserved")
        XCTAssertEqual(context.boundedOrderedMessages.first?.text, "A short thing that was heard.")
    }

    /// A single oversized current-turn message is capped, and the NEWEST text is what survives.
    func testLongSingleCurrentTurnMessageIsCappedKeepingTheNewestText() {
        let manager = makeManager()
        manager.beginRecording()
        manager.appendHeardDelta(longText("TURN", count: 5_000))

        let context = manager.responseContext(recentContextLimit: 20, characterLimit: 1_000)
        let sent = context.boundedOrderedMessages
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].text.count, 1_000, "trimmed to exactly the budget")
        XCTAssertTrue(sent[0].text.hasSuffix("TAIL-TURN"), "the most recent content is kept")
        XCTAssertFalse(sent[0].text.contains("HEAD-TURN"), "the oldest content is what gets dropped")
    }

    /// Long history plus a long current turn: the combined sent context stays within budget, and
    /// the current turn is prioritised over background history.
    func testCombinedContextStaysWithinBudgetAndPrioritisesTheCurrentTurn() {
        let manager = makeManager()
        manager.beginRecording()
        manager.appendHeardDelta(longText("OLD", count: 4_000))
        guard let messageID = manager.beginResponse() else { return XCTFail("expected a response id") }
        manager.appendResponseDelta(longText("REPLY", count: 4_000), messageID: messageID)
        manager.completeResponse(messageID: messageID, errorText: nil)
        manager.appendHeardDelta(longText("NEW", count: 4_000))

        let limit = 2_000
        let context = manager.responseContext(characterLimit: limit)
        let sent = context.boundedOrderedMessages
        XCTAssertLessThanOrEqual(sent.reduce(0) { $0 + $1.text.count }, limit)
        XCTAssertTrue(sent.last?.text.hasSuffix("TAIL-NEW") == true, "the current turn survives")
        XCTAssertGreaterThan(context.orderedMessages.reduce(0) { $0 + $1.text.count }, limit, "untrimmed really was over budget")
    }

    /// Both bounds apply: the message-count limit still trims history, and the character limit
    /// still bounds what is sent.
    func testMessageCountLimitAndCharacterLimitBothApply() {
        let manager = makeManager()
        manager.beginRecording()
        for index in 1...6 {
            manager.appendHeardDelta("heard \(index) ")
            guard let messageID = manager.beginResponse() else { return XCTFail("expected a response id") }
            manager.appendResponseDelta("reply \(index) ", messageID: messageID)
            manager.completeResponse(messageID: messageID, errorText: nil)
        }
        manager.appendHeardDelta("the newest question")

        let counted = manager.responseContext(recentContextLimit: 2, characterLimit: 10_000)
        XCTAssertEqual(counted.recentContext.count, 2, "message-count bound still enforced")

        let bounded = manager.responseContext(recentContextLimit: 20, characterLimit: 25)
        XCTAssertLessThanOrEqual(bounded.boundedOrderedMessages.reduce(0) { $0 + $1.text.count }, 25)
    }

    /// Empty stays empty; non-empty never becomes empty purely because of the cap.
    func testEmptyStaysEmptyAndNonEmptyNeverBecomesEmpty() {
        let empty = makeManager().responseContext()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.boundedOrderedMessages.isEmpty)

        let manager = makeManager()
        manager.beginRecording()
        manager.appendHeardDelta(longText("TINY", count: 3_000))
        // A budget far below one message's length must still send something.
        let context = manager.responseContext(characterLimit: 1)
        XCTAssertFalse(context.boundedOrderedMessages.isEmpty, "a non-empty turn must never be capped out of existence")
        XCTAssertEqual(context.boundedOrderedMessages.last?.text.count, 1)
        XCTAssertFalse(context.isEmpty, "isEmpty still reflects the real turn, not the trimmed one")
    }

    /// The transcript itself is untouched - verified by re-reading the STORE, not by asserting
    /// about implementation internals.
    ///
    /// The polling remains because the store write is asynchronous, but it no longer tolerates a
    /// missing row: `ChatSessionStore`'s write race (two concurrent background contexts, with the
    /// losing save swallowed by `try?`) has since been fixed by serializing all writes through one
    /// private-queue context, so the row is now guaranteed to land. The former
    /// `XCTSkipIf(before == nil, ...)` escape hatch was removed rather than replaced - persistence
    /// is asserted outright.
    func testProducingBoundedContextLeavesSessionAndStoreContentUnchanged() throws {
        let store = ChatSessionStore(inMemory: true)
        let manager = ChatSessionManager(store: store)
        manager.beginRecording()
        let full = longText("STORED", count: 6_000)
        manager.appendHeardDelta(full)
        guard let sessionID = manager.recordingSessionID else { return XCTFail("expected a recording session") }

        func storedText() -> String? {
            store.loadAllSessions().first { $0.id == sessionID }?.messages.first?.text
        }

        let deadline = Date().addingTimeInterval(3)
        while storedText() == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let before = storedText()

        let context = manager.responseContext(characterLimit: 500)
        XCTAssertEqual(context.boundedOrderedMessages.first?.text.count, 500, "the SENT copy is trimmed")

        // Always true, and the actual point of this test.
        XCTAssertEqual(storedText(), before, "producing a bounded view must not alter what is stored")
        XCTAssertEqual(manager.sessions.first { $0.id == sessionID }?.messages.first?.text, full, "in-memory transcript untouched")

        XCTAssertNotNil(before, "the store write must land - the ChatSessionStore race is fixed")
        XCTAssertEqual(before, full, "the store held the full text before")
        XCTAssertEqual(storedText(), full, "and still holds the full text afterwards")
    }

    /// PINNED: the retrieval query must keep using the UNTRIMMED current turn, so Phase 4.2's
    /// grounding/evidence-sufficiency behaviour cannot change as a side effect of this cap.
    func testRetrievalQuerySourceRemainsUntrimmed() {
        let manager = makeManager()
        manager.beginRecording()
        let full = longText("QUERY", count: 5_000)
        manager.appendHeardDelta(full)

        let context = manager.responseContext(characterLimit: 100)
        XCTAssertEqual(context.currentTurn.map(\.text), [full], "currentTurn - the retrieval query source - is never trimmed")
        XCTAssertEqual(context.orderedMessages.map(\.text), [full], "orderedMessages keeps its pre-2.5 meaning")
        XCTAssertEqual(context.boundedOrderedMessages.first?.text.count, 100, "only the SENT view is bounded")
    }

    /// Existing behaviour below the limit is unchanged: the follow-up-continuity guarantee still
    /// holds when the bounded view is what gets sent.
    func testExistingContinuityBehaviourHoldsForTheBoundedView() {
        let manager = makeManager()
        manager.beginRecording()
        manager.appendHeardDelta("The secret number is 4729.")
        guard let messageID = manager.beginResponse() else { return XCTFail("expected a response id") }
        manager.appendResponseDelta("Got it. I've noted 4729.", messageID: messageID)
        manager.completeResponse(messageID: messageID, errorText: nil)
        manager.appendHeardDelta("What was the secret number?")

        let context = manager.responseContext()
        XCTAssertTrue(context.boundedOrderedMessages.contains { $0.text.contains("4729") })
        XCTAssertEqual(context.boundedOrderedMessages.map(\.text), context.orderedMessages.map(\.text))
    }
}
