import XCTest
@testable import FounderOfficeCopilotCore

/// Covers `GeminiResponseGenerator.buildContents(from:)` directly - the pure, network-free
/// piece that turns a ChatSessionManager.ResponseContext's ordered messages into Gemini's
/// multi-turn `contents` array. The actual network call isn't unit-tested (same convention
/// as everywhere else in this project - see AutomatedTests/README.md), but this mapping is
/// exactly the part responsible for conversational continuity actually working, so it's
/// tested precisely.
final class GeminiResponseGeneratorTests: XCTestCase {
    private func text(_ contents: [[String: Any]], at index: Int) -> String? {
        guard index < contents.count, let parts = contents[index]["parts"] as? [[String: Any]] else { return nil }
        return parts.first?["text"] as? String
    }

    func testMapsHeardToUserAndResponseToModel() {
        let context = [
            ChatMessage(role: .heard, text: "hello"),
            ChatMessage(role: .response, text: "hi there")
        ]
        let contents = GeminiResponseGenerator.buildContents(from: context)

        XCTAssertEqual(contents.count, 2)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        XCTAssertEqual(text(contents, at: 0), "hello")
        XCTAssertEqual(contents[1]["role"] as? String, "model")
        XCTAssertEqual(text(contents, at: 1), "hi there")
    }

    func testAlternatingHistoryStaysFullyAlternating() {
        let context = [
            ChatMessage(role: .heard, text: "q1"),
            ChatMessage(role: .response, text: "a1"),
            ChatMessage(role: .heard, text: "q2"),
            ChatMessage(role: .response, text: "a2"),
            ChatMessage(role: .heard, text: "q3")
        ]
        let contents = GeminiResponseGenerator.buildContents(from: context)
        XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model", "user", "model", "user"])
    }

    func testMergesConsecutiveSameRoleMessagesDefensively() {
        // Shouldn't happen under normal ChatSessionManager operation (see its doc comment),
        // but the wire format requires alternation, so this must never send two consecutive
        // same-role turns even if it somehow occurs.
        let context = [
            ChatMessage(role: .heard, text: "first"),
            ChatMessage(role: .heard, text: "second"),
            ChatMessage(role: .response, text: "answer")
        ]
        let contents = GeminiResponseGenerator.buildContents(from: context)

        XCTAssertEqual(contents.count, 2, "two consecutive .heard messages must merge into one user turn")
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        XCTAssertEqual(text(contents, at: 0), "first\nsecond")
        XCTAssertEqual(contents[1]["role"] as? String, "model")
    }

    func testMergesConsecutiveResponseMessagesToo() {
        let context = [
            ChatMessage(role: .heard, text: "question"),
            ChatMessage(role: .response, text: "part one"),
            ChatMessage(role: .response, text: "part two")
        ]
        let contents = GeminiResponseGenerator.buildContents(from: context)
        XCTAssertEqual(contents.count, 2)
        XCTAssertEqual(text(contents, at: 1), "part one\npart two")
    }

    func testEmptyContextProducesEmptyContents() {
        XCTAssertTrue(GeminiResponseGenerator.buildContents(from: []).isEmpty)
    }

    // MARK: Phase 3 - optional screen frame (Option B)
    //
    // One still is attached to the newest USER turn at response time. With no frame the payload
    // must be byte-for-byte what it was before Phase 3, which is what makes "permission denied /
    // capture failed / macOS 13" degrade silently to the existing text-only request.

    private var sampleJPEG: Data { Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46]) }

    func testNoScreenFrameProducesTheExistingPayloadUnchanged() {
        let context = [
            ChatMessage(role: .heard, text: "first"),
            ChatMessage(role: .response, text: "reply"),
            ChatMessage(role: .heard, text: "second"),
        ]
        let withoutArgument = GeminiResponseGenerator.buildContents(from: context)
        let explicitNil = GeminiResponseGenerator.buildContents(from: context, screenFrameJPEG: nil)

        XCTAssertEqual(NSArray(array: withoutArgument), NSArray(array: explicitNil), "nil frame must change nothing")
        for turn in explicitNil {
            let parts = turn["parts"] as? [[String: Any]] ?? []
            XCTAssertTrue(parts.allSatisfy { $0["inlineData"] == nil }, "no inlineData part may appear without a frame")
            XCTAssertEqual(parts.count, 1)
        }
    }

    func testScreenFrameAddsExactlyOneJPEGInlineDataPart() {
        let context = [ChatMessage(role: .heard, text: "what is on screen?")]
        let contents = GeminiResponseGenerator.buildContents(from: context, screenFrameJPEG: sampleJPEG)

        let parts = contents.last?["parts"] as? [[String: Any]] ?? []
        let inline = parts.compactMap { $0["inlineData"] as? [String: Any] }
        XCTAssertEqual(inline.count, 1, "exactly one image part")
        XCTAssertEqual(inline.first?["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(inline.first?["data"] as? String, sampleJPEG.base64EncodedString())
        XCTAssertEqual(parts.first?["text"] as? String, "what is on screen?", "the text part is untouched")
    }

    func testScreenFrameAttachesToTheNewestUserTurnOnly() {
        let context = [
            ChatMessage(role: .heard, text: "old question"),
            ChatMessage(role: .response, text: "old answer"),
            ChatMessage(role: .heard, text: "newest question"),
        ]
        let contents = GeminiResponseGenerator.buildContents(from: context, screenFrameJPEG: sampleJPEG)

        XCTAssertEqual(contents.count, 3)
        func inlineCount(_ index: Int) -> Int {
            ((contents[index]["parts"] as? [[String: Any]]) ?? []).filter { $0["inlineData"] != nil }.count
        }
        XCTAssertEqual(inlineCount(0), 0, "not the older user turn")
        XCTAssertEqual(inlineCount(1), 0, "never a model turn")
        XCTAssertEqual(inlineCount(2), 1, "only the newest user turn")
        XCTAssertEqual(contents[2]["role"] as? String, "user")
    }

    func testEmptyFrameDataIsTreatedAsNoFrame() {
        let context = [ChatMessage(role: .heard, text: "hello")]
        let contents = GeminiResponseGenerator.buildContents(from: context, screenFrameJPEG: Data())
        XCTAssertEqual(NSArray(array: contents), NSArray(array: GeminiResponseGenerator.buildContents(from: context)))
    }

    func testImageBytesAreNotCountedAsPhase25TextCharacters() {
        // A large frame must not shrink the text that Phase 2.5's character budget allows.
        let manager = ChatSessionManager(store: ChatSessionStore(inMemory: true))
        manager.beginRecording()
        manager.appendHeardDelta(String(repeating: "t", count: 500))
        let bounded = manager.responseContext(characterLimit: 1_000).boundedOrderedMessages

        let bigFrame = Data(repeating: 0xAB, count: 200_000)
        let contents = GeminiResponseGenerator.buildContents(from: bounded, screenFrameJPEG: bigFrame)

        let textCharacters = contents.reduce(0) { total, turn in
            total + ((turn["parts"] as? [[String: Any]]) ?? []).reduce(0) { $0 + (($1["text"] as? String)?.count ?? 0) }
        }
        XCTAssertEqual(textCharacters, 500, "text is unaffected by image size")
        XCTAssertEqual(bounded.map(\.text), [String(repeating: "t", count: 500)], "the bounded text view is unchanged by Phase 3")
    }
}
