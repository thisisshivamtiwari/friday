import XCTest
@testable import FounderOfficeCopilotCore

/// Covers ExtractionLLMClient's parsing logic as PURE functions against fixture bytes - no
/// network call, mirroring how GeminiResponseGenerator's buildContents/extractText are tested.
/// Real extraction QUALITY against the live model is covered by the manual Python protocol
/// script (AutomatedTests/api-protocol-scripts/test_extraction_quality.py), never here.
final class ExtractionLLMClientTests: XCTestCase {
    func testParseExtractionsDecodesAWellFormedEnvelope() {
        let json = """
        {"extractions": [
            {"type": "memoryEdge", "modality": "directStatement", "confidence": 0.7, "isExplicit": false, "subjectName": "self", "predicate": "prefers", "literalValue": "dark mode", "memoryCategory": "preference"}
        ]}
        """
        let candidates = ExtractionLLMClient.parseExtractions(from: Data(json.utf8))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.type, .memoryEdge)
        XCTAssertEqual(candidates.first?.modality, .directStatement)
        XCTAssertEqual(candidates.first?.subjectName, "self")
        XCTAssertEqual(candidates.first?.literalValue, "dark mode")
    }

    func testParseExtractionsHandlesMultipleCandidatesOfDifferentTypes() {
        let json = """
        {"extractions": [
            {"type": "memoryEdge", "modality": "directStatement", "confidence": 0.6, "isExplicit": false, "subjectName": "self", "predicate": "prefers", "literalValue": "dark mode", "memoryCategory": "preference"},
            {"type": "projectItem", "modality": "explicitTask", "confidence": 0.8, "isExplicit": false, "projectItemKind": "task", "name": "Compare methods", "projectItemStatus": "planned"},
            {"type": "decision", "modality": "explicitDecision", "confidence": 0.9, "isExplicit": false, "statement": "Use Bayesian calibration", "context": "XYZ algorithm"}
        ]}
        """
        let candidates = ExtractionLLMClient.parseExtractions(from: Data(json.utf8))
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates.map(\.type), [.memoryEdge, .projectItem, .decision])
    }

    func testParseExtractionsReturnsEmptyForEmptyExtractions() {
        let candidates = ExtractionLLMClient.parseExtractions(from: Data(#"{"extractions": []}"#.utf8))
        XCTAssertTrue(candidates.isEmpty)
    }

    func testParseExtractionsSkipsMalformedCandidatesRatherThanFailingTheWholeBatch() {
        let json = """
        {"extractions": [
            {"type": "memoryEdge", "modality": "directStatement", "confidence": 0.6, "isExplicit": false, "subjectName": "self", "predicate": "prefers", "literalValue": "dark mode", "memoryCategory": "preference"},
            {"type": "notARealType", "modality": "bogus"},
            {"type": "decision", "modality": "explicitDecision", "confidence": 0.9, "isExplicit": false, "statement": "Use Bayesian calibration"}
        ]}
        """
        let candidates = ExtractionLLMClient.parseExtractions(from: Data(json.utf8))
        // The malformed middle candidate is skipped; the two well-formed ones still parse.
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.map(\.type), [.memoryEdge, .decision])
    }

    func testParseExtractionsReturnsEmptyForCompletelyInvalidJSON() {
        let candidates = ExtractionLLMClient.parseExtractions(from: Data("not json at all".utf8))
        XCTAssertTrue(candidates.isEmpty)
    }

    func testParseExtractionsReturnsEmptyWhenTopLevelKeyIsMissing() {
        let candidates = ExtractionLLMClient.parseExtractions(from: Data(#"{"somethingElse": []}"#.utf8))
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: parseCandidates - unwrapping Gemini's outer response envelope

    func testParseCandidatesExtractsInnerJSONFromGeminiEnvelope() {
        let innerJSON = #"{"extractions": [{"type": "decision", "modality": "explicitDecision", "confidence": 0.85, "isExplicit": false, "statement": "Use Bayesian calibration"}]}"#
        // Gemini's real response shape: candidates[0].content.parts[0].text holds our JSON as a string.
        let escapedInner = innerJSON.replacingOccurrences(of: "\"", with: "\\\"")
        let envelope = """
        {"candidates": [{"content": {"parts": [{"text": "\(escapedInner)"}]}}]}
        """
        let candidates = ExtractionLLMClient.parseCandidates(from: Data(envelope.utf8))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.statement, "Use Bayesian calibration")
    }

    func testParseCandidatesReturnsEmptyForMalformedEnvelope() {
        let candidates = ExtractionLLMClient.parseCandidates(from: Data("{}".utf8))
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: Canonical ProjectItem names in the extraction prompt
    //
    // Two live populations produced zero Decision->ProjectItem links: the model never emitted
    // `relatedItemName` and paraphrased the item inside `statement`/`context` instead, in both
    // directions, which no safe deterministic string rule could bridge. The model is now GIVEN the
    // exact canonical names to choose from. These tests prove the PROMPT is correct - they cannot
    // prove a stochastic model will comply.

    private var canonicalSection: String {
        "EXISTING TRACKED PROJECT ITEMS FOR THIS PROJECT"
    }

    /// 1: the active project's item names appear in the instruction.
    func testExistingProjectItemNamesAreIncludedInThePrompt() {
        let instruction = ExtractionLLMClient.systemInstruction(existingProjectItemNames: [
            "Testing temperature scaling versus MC dropout",
            "Set up gridworld search-and-rescue environment",
        ])
        XCTAssertTrue(instruction.contains(canonicalSection))
        XCTAssertTrue(instruction.contains("- Testing temperature scaling versus MC dropout"))
        XCTAssertTrue(instruction.contains("- Set up gridworld search-and-rescue environment"))
    }

    /// CRITICAL FIXTURE 1 - the exact first live miss: the canonical name must be offered verbatim.
    func testCriticalFixtureTemperatureScalingCanonicalNameIsOffered() {
        let canonical = "Testing temperature scaling versus MC dropout"
        let instruction = ExtractionLLMClient.systemInstruction(existingProjectItemNames: [canonical])
        XCTAssertTrue(instruction.contains(canonical), "the model must be shown the exact item name")
        XCTAssertTrue(instruction.contains("MUST be the exact name from this list"))
    }

    /// CRITICAL FIXTURE 2 - the exact second live miss.
    func testCriticalFixtureTransientGroupDemandCanonicalNameIsOffered() {
        let canonical = "Split transient and group demand sub-models"
        let instruction = ExtractionLLMClient.systemInstruction(existingProjectItemNames: [canonical])
        XCTAssertTrue(instruction.contains(canonical))
        XCTAssertTrue(instruction.contains("MUST be the exact name from this list"))
    }

    /// 4/6: exact-copy requirement, and explicit bans on paraphrasing/inventing/combining.
    func testPromptRequiresExactCanonicalNamesAndForbidsParaphrasing() {
        let instruction = ExtractionLLMClient.systemInstruction(existingProjectItemNames: ["Gridworld Environment"])
        XCTAssertTrue(instruction.contains("copied character for character"))
        XCTAssertTrue(instruction.contains("Do not paraphrase a name"))
        XCTAssertTrue(instruction.contains("do not invent a new name"))
        XCTAssertTrue(instruction.contains("do not combine two of them into one"))
        XCTAssertTrue(instruction.contains("Do not infer a relationship merely because some words or topics overlap"))
    }

    /// 5: null is explicitly permitted, and the field stays optional in the schema spec.
    func testPromptPermitsNullAndKeepsRelatedItemNameOptional() {
        let instruction = ExtractionLLMClient.systemInstruction(existingProjectItemNames: ["Gridworld Environment"])
        XCTAssertTrue(instruction.contains("use null"))
        XCTAssertTrue(instruction.contains("If you are uncertain which one it is, use null"))
        XCTAssertTrue(instruction.contains("\"relatedItemName\" (optional, may be null"))
    }

    // MARK: Phase 4.3c - same-batch referencing
    //
    // The live probe measured the ONE variable that governs `relatedItemName` emission: given
    // names it may copy, the model emitted a non-null exact name 6/6 times; given an empty list,
    // 0/5. In a population starting from an empty store, a project's FIRST meeting has no tracked
    // items at all, so the only item a decision could name is one proposed in the very same
    // response - which the prompt previously never permitted. After the change, that case went
    // 0/5 -> 3/5, with 3/3 of the emitted names matching a same-batch item exactly and 0 invented.

    /// The base instruction (no tracked items - a project's first meeting) must still tell the
    /// model it may name an item it is proposing in this same response.
    func testBaseInstructionPermitsNamingASameBatchProjectItem() {
        let instruction = ExtractionLLMClient.systemInstruction
        XCTAssertTrue(instruction.contains("THIS SAME response"))
        XCTAssertTrue(instruction.contains("the exact \"name\" of a \"projectItem\" candidate"))
    }

    /// The permission must not weaken the exact-string rule the resolver depends on, and must not
    /// become an invitation to guess.
    func testSameBatchPermissionStillDemandsAnExactStringAndAllowsNull() {
        let instruction = ExtractionLLMClient.systemInstruction
        XCTAssertTrue(instruction.contains("MUST be an EXACT string, never a paraphrase"))
        XCTAssertTrue(instruction.contains("Copy whichever string you mean character for character"))
        XCTAssertTrue(instruction.contains("never guess, and never invent a name that appears nowhere else in your output"))
        XCTAssertTrue(instruction.contains("Use null if neither applies"))
    }

    /// The same-batch permission lives in the BASE instruction, so it is present whether or not a
    /// canonical list is appended - the empty-list case is precisely the one that needs it.
    func testSameBatchPermissionIsPresentWithAndWithoutACanonicalList() {
        for names in [[], ["Gridworld Environment"]] {
            let instruction = ExtractionLLMClient.systemInstruction(existingProjectItemNames: names)
            XCTAssertTrue(instruction.contains("THIS SAME response"), "missing for names=\(names)")
        }
    }

    /// With no items, the instruction is byte-identical to the base - no empty section, no change
    /// to existing behaviour.
    func testNoItemsMeansNoSectionAndAnUnchangedInstruction() {
        XCTAssertEqual(ExtractionLLMClient.systemInstruction(existingProjectItemNames: []), ExtractionLLMClient.systemInstruction)
        XCTAssertFalse(ExtractionLLMClient.systemInstruction.contains(canonicalSection))
        // Blank/whitespace names are filtered rather than emitted as empty bullets.
        XCTAssertEqual(ExtractionLLMClient.systemInstruction(existingProjectItemNames: ["  ", ""]), ExtractionLLMClient.systemInstruction)
    }

    /// 7: the response-parsing path is untouched by the prompt change - including an explicit
    /// null `relatedItemName`, which the schema must still accept. Uses the same envelope-building
    /// style as the existing parse tests above.
    func testCandidateParsingIsUnchangedByThePromptChange() {
        let innerJSON = #"{"extractions": [{"type": "decision", "modality": "explicitDecision", "confidence": 0.9, "isExplicit": false, "statement": "Adopt X", "relatedItemName": null}]}"#
        let escapedInner = innerJSON.replacingOccurrences(of: "\"", with: "\\\"")
        let envelope = """
        {"candidates": [{"content": {"parts": [{"text": "\(escapedInner)"}]}}]}
        """
        let candidates = ExtractionLLMClient.parseCandidates(from: Data(envelope.utf8))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.statement, "Adopt X")
        XCTAssertNil(candidates.first?.relatedItemName, "an explicit null must decode as nil, not fail the whole candidate")
    }

    // MARK: Phase 4.3 Cause 1 - structured relatedItemName
    //
    // Live diagnostics recorded `relatedItemName emitted 0/7` on a fresh population (and 0 on two
    // earlier runs) while the prompt asked for the field in prose only. These pin the request
    // shape that makes the key structurally mandatory while keeping null a valid answer.

    private func payload(names: [String] = []) -> [String: Any] {
        ExtractionLLMClient.buildRequestPayload(conversationText: "text", existingProjectItemNames: names)
    }

    private func candidateSchema() -> [String: Any] {
        let generationConfig = payload()["generationConfig"] as? [String: Any]
        let schema = generationConfig?["responseSchema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        let extractions = properties?["extractions"] as? [String: Any]
        return (extractions?["items"] as? [String: Any]) ?? [:]
    }

    /// 1: the outgoing request actually carries a response schema (it previously carried only
    /// `responseMimeType`, which is what let the model omit the field).
    func testRequestPayloadIncludesAResponseSchema() {
        let generationConfig = payload()["generationConfig"] as? [String: Any]
        XCTAssertEqual(generationConfig?["responseMimeType"] as? String, "application/json", "existing mime type is preserved")
        XCTAssertNotNil(generationConfig?["responseSchema"], "the schema is what makes relatedItemName structural")
        let schema = generationConfig?["responseSchema"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "OBJECT")
        XCTAssertEqual(schema?["required"] as? [String], ["extractions"])
        // The payload must remain serializable - a malformed schema would fail silently at
        // `JSONSerialization.data`, sending no body at all.
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload()))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload()))
    }

    /// 2 + 3: `relatedItemName` is present, is a string, and is REQUIRED but explicitly nullable -
    /// required so the key must appear, nullable so "no tracked item" stays expressible.
    func testRelatedItemNameIsRequiredAndNullableInTheDecisionSchema() {
        let properties = candidateSchema()["properties"] as? [String: Any]
        let related = properties?["relatedItemName"] as? [String: Any]
        XCTAssertNotNil(related, "relatedItemName must be declared")
        XCTAssertEqual(related?["type"] as? String, "STRING")
        XCTAssertEqual(related?["nullable"] as? Bool, true, "null must remain a valid answer - never force a link")
        let required = candidateSchema()["required"] as? [String] ?? []
        XCTAssertTrue(required.contains("relatedItemName"), "required is what forces the key to be emitted at all")
    }

    /// 4: every existing decision field survives, and nothing else was newly made required.
    func testExistingDecisionFieldsRemainInTheSchema() {
        let properties = candidateSchema()["properties"] as? [String: Any] ?? [:]
        for field in ["statement", "context", "reason", "madeByNames", "mentionedProjectName"] {
            XCTAssertNotNil(properties[field], "\(field) must still be declared")
        }
        // Other candidate types must keep working - the array is heterogeneous.
        for field in ["subjectName", "predicate", "literalValue", "memoryCategory",
                      "projectItemKind", "name", "itemDescription", "projectItemStatus"] {
            XCTAssertNotNil(properties[field], "\(field) must still be declared")
        }
        XCTAssertEqual(properties.count, 21, "the schema mirrors ExtractionCandidate's 21 decodable fields")
        // `type`/`modality`/`confidence`/`isExplicit` are non-optional on ExtractionCandidate, so
        // a response omitting any of them already failed to decode and was dropped; the schema
        // now states that instead of leaving it to chance. `relatedItemName` is the only field
        // whose optionality changed in the REQUEST, and it stays nullable.
        XCTAssertEqual(Set(candidateSchema()["required"] as? [String] ?? []),
                       ["type", "modality", "confidence", "isExplicit", "relatedItemName"],
                       "only decoder-mandatory fields plus relatedItemName are required")
        let madeBy = properties["madeByNames"] as? [String: Any]
        XCTAssertEqual(madeBy?["type"] as? String, "ARRAY")
    }

    /// 5: an explicit null still decodes to nil rather than failing the candidate.
    func testJSONWithNullRelatedItemNameStillDecodes() {
        let json = #"{"extractions": [{"type": "decision", "modality": "explicitDecision", "confidence": 0.9, "isExplicit": false, "statement": "Adopt X", "context": "calibration", "relatedItemName": null}]}"#
        let candidates = ExtractionLLMClient.parseExtractions(from: Data(json.utf8))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertNil(candidates.first?.relatedItemName)
        XCTAssertEqual(candidates.first?.statement, "Adopt X")
    }

    /// 6: a populated value decodes verbatim - no trimming, no normalization.
    func testJSONWithRealRelatedItemNameStillDecodes() {
        let json = #"{"extractions": [{"type": "decision", "modality": "explicitDecision", "confidence": 0.9, "isExplicit": false, "statement": "Reject conformal prediction", "relatedItemName": "Conformal prediction calibration gridworld runs"}]}"#
        let candidates = ExtractionLLMClient.parseExtractions(from: Data(json.utf8))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.relatedItemName, "Conformal prediction calibration gridworld runs",
                       "the exact canonical name must survive decoding unchanged")
    }

    /// 7: the canonical-name prompt block is untouched by the schema change, and still travels in
    /// the same request.
    func testCanonicalNamePromptIsUnchangedByTheSchemaChange() {
        let names = ["Conformal prediction calibration gridworld runs", "MC dropout calibration evaluation"]
        let systemInstruction = payload(names: names)["systemInstruction"] as? [String: Any]
        let parts = systemInstruction?["parts"] as? [[String: Any]]
        let text = parts?.first?["text"] as? String ?? ""
        XCTAssertEqual(text, ExtractionLLMClient.systemInstruction(existingProjectItemNames: names),
                       "the prompt must be exactly what it was before the schema existed")
        for name in names { XCTAssertTrue(text.contains(name)) }
        XCTAssertTrue(text.contains("copied character for character"))
        // With no items, the instruction is still byte-identical to the base one.
        let bare = ((payload()["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(bare, ExtractionLLMClient.systemInstruction)
    }

    /// 8: the conversation text and request envelope are unchanged - the schema is the ONLY
    /// difference, so nothing about what the model is asked to read has moved.
    func testConversationContentIsUnchangedByTheSchemaChange() {
        let contents = ExtractionLLMClient.buildRequestPayload(conversationText: "Alice: we decided X", existingProjectItemNames: [])["contents"] as? [[String: Any]]
        XCTAssertEqual(contents?.count, 1)
        XCTAssertEqual(contents?.first?["role"] as? String, "user")
        let parts = contents?.first?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, "Alice: we decided X")
    }
}
