import Foundation

// MARK: - Extraction LLM Client Protocol
/// Abstraction ExtractionCoordinator depends on, never the concrete network implementation -
/// this is what lets tests use a stubbed client (canned candidates, no network) while
/// production uses the real Gemini-backed one. Mirrors the `apiKeyProvider`/`store:` seam
/// pattern already used throughout this codebase.
protocol ExtractionLLMClientProtocol {
    /// `conversationText` is the batched, finalized turn text for ONE session's queued batch
    /// (see ExtractionCoordinator - batches are never mixed across sessions). Calls back with
    /// the raw candidates the model proposed - NOT yet gated, validated, deduplicated, or
    /// persisted; that all happens in ExtractionCoordinator after this returns.
    /// `existingProjectItemNames` are the canonical `ProjectItem.name` values ALREADY tracked for
    /// the active project of this batch's session - names only, never whole objects, and never
    /// another project's items. Empty when the session isn't linked to a project or it has no
    /// items yet. They let the model reference an existing item exactly instead of paraphrasing
    /// it, which is what makes `relatedItemName` resolvable downstream.
    func extract(
        conversationText: String,
        apiKey: String,
        model: String,
        existingProjectItemNames: [String],
        completion: @escaping (Result<[ExtractionCandidate], Error>) -> Void
    )
}

// MARK: - Extraction LLM Client
/// The real, network-backed implementation - a one-shot `generateContent` call (NOT the
/// streaming `streamGenerateContent` GeminiResponseGenerator uses - extraction needs one
/// complete, parseable JSON object, not progressive text) asking for structured JSON output.
/// Deliberately a separate, independent network client from GeminiResponseGenerator - the
/// response generator itself remains completely unaware this exists, per the approved
/// integration boundary.
final class ExtractionLLMClient: ExtractionLLMClientProtocol {
    private let urlSession = URLSession(configuration: .default)

    func extract(
        conversationText: String,
        apiKey: String,
        model: String,
        existingProjectItemNames: [String],
        completion: @escaping (Result<[ExtractionCandidate], Error>) -> Void
    ) {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            completion(.failure(URLError(.badURL)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        request.httpBody = try? JSONSerialization.data(
            withJSONObject: Self.buildRequestPayload(
                conversationText: conversationText,
                existingProjectItemNames: existingProjectItemNames
            )
        )

        let task = urlSession.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.failure(NSError(domain: "ExtractionLLMClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])))
                return
            }
            guard let data else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            completion(.success(Self.parseCandidates(from: data)))
        }
        task.resume()
    }

    /// Explains the task, the exact output shape, and the modality vocabulary the model must
    /// use - tuned via the manual Python verification script
    /// (AutomatedTests/api-protocol-scripts/test_extraction_quality.py), not by XCTest (no
    /// deterministic assertion can validate real model judgment - see that script's own doc
    /// comment).
    static let systemInstruction = """
    You extract structured, durable facts and project state from a snippet of conversation \
    for "Friday", an always-listening personal assistant. Most conversation contains nothing \
    worth extracting - when in doubt, extract nothing.

    Output ONLY a single JSON object of the exact shape below - no markdown fences, no \
    commentary, nothing else:

    {"extractions": [ { ...candidate... }, ... ]}

    Each candidate has:
    - "type": one of "memoryEdge", "projectItem", "decision"
    - "modality": one of "directStatement", "explicitDecision", "explicitTask", "suggestion", \
    "speculation", "question", "hypothetical", "inference", "contradiction", "uncertain"
    - "confidence": 0.0 to 1.0, how sure you are this is true and stable
    - "isExplicit": true ONLY if the speaker directly asked to be remembered ("remember \
    that...")

    NEVER output a candidate for a question or a hypothetical ("how does X work?", "what if we \
    used X?") - if the ENTIRE snippet is only questions/hypotheticals/small talk, output \
    {"extractions": []}.

    Hedged, uncertain, or merely suggested content ("maybe", "I think", "what if", "should we") \
    must be tagged "suggestion", "speculation", or "uncertain", never "directStatement" or \
    "explicitDecision".

    For "memoryEdge" (a durable fact/preference/goal/relationship about a person, not about a \
    project's own work): "subjectName" ("self" for the user speaking about themselves, or a \
    person/org name), "subjectKind" (self/person/organization/project/place/concept/tool/other, \
    only if subjectName is new), "predicate" (short verb phrase, e.g. "prefers", "works-at"), \
    "objectName" (another entity name, if the value is itself a nameable thing) OR \
    "literalValue" (a plain value, if not), "memoryCategory" \
    (identity/preference/goal/fact/relationship/project/contact/other).

    For "projectItem" (a task/objective/requirement/experiment/result/milestone/risk/open \
    question/component belonging to a specific project's work): "projectItemKind" \
    (task/objective/researchQuestion/component/requirement/artifact/milestone/openQuestion/\
    risk/experiment/result), "name" (short label), "itemDescription" (optional detail), \
    "projectItemStatus" (proposed/planned/active/inProgress/blocked/completed/achieved/\
    resolved/abandoned), "relatedItemName" (optional - e.g. a result's experiment), \
    "mentionedProjectName" (the project name if one was explicitly said, else omit).

    For "decision" (an explicit, decisive choice about approach/method): "statement" (what was \
    decided), "context" (what it concerns, e.g. a component name), "reason" (optional), \
    "relatedItemName" (optional, may be null - the tracked ProjectItem this decision is about; \
    see the EXISTING TRACKED PROJECT ITEMS section below when one is supplied), \
    "madeByNames" (people who made it), "mentionedProjectName" (if explicitly said).

    "relatedItemName" MUST be an EXACT string, never a paraphrase, and it has exactly two valid \
    non-null sources. It is either the exact name of an item listed under EXISTING TRACKED \
    PROJECT ITEMS below (when that section is present), OR the exact "name" of a "projectItem" \
    candidate you are emitting in THIS SAME response - a decision is very often about a piece of \
    work first identified in the very same conversation, which has no tracked item yet. Copy \
    whichever string you mean character for character. Use null if neither applies, or if you \
    are uncertain which item it is - never guess, and never invent a name that appears nowhere \
    else in your output.
    """

    /// The system instruction for one request, including the active project's canonical item
    /// names when there are any. Two live populations produced zero `relatedItemID` links because
    /// the model never emitted `relatedItemName` and paraphrased the item in `statement`/`context`
    /// instead; no deterministic string rule could bridge that safely in both directions, so the
    /// model is now GIVEN the exact strings to choose from and told to copy one verbatim or
    /// answer null. `relatedItemName` stays optional and explicitly null-capable - this changes
    /// what the model is shown, never what the schema requires.
    ///
    /// `names` is always the ACTIVE PROJECT's items only; see `ExtractionCoordinator`, which
    /// derives them from `projectManager.items(forProject:)` for the batch's own session. When
    /// empty, no section is emitted at all and the instruction is byte-identical to the base.
    static func systemInstruction(existingProjectItemNames names: [String]) -> String {
        let canonical = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !canonical.isEmpty else { return systemInstruction }

        let list = canonical.map { "- \($0)" }.joined(separator: "\n")
        return systemInstruction + """


        EXISTING TRACKED PROJECT ITEMS FOR THIS PROJECT
        Existing tracked ProjectItems for this project are listed below. When a decision concerns \
        one of them, "relatedItemName" MUST be the exact name from this list, copied character for \
        character. Do not paraphrase a name, do not shorten or expand it, do not invent a new name, \
        and do not combine two of them into one. If no listed item is the subject of the decision, \
        use null. If you are uncertain which one it is, use null. Do not infer a relationship \
        merely because some words or topics overlap - the listed item must actually be what the \
        decision is about.

        \(list)
        """
    }

    // MARK: Request payload (Phase 4.3)
    //
    // HISTORY, CORRECTED BY MEASUREMENT. Three live populations emitted `relatedItemName` 0 times
    // out of 7, 7 and 6 decision candidates, and this schema was added on the hypothesis that the
    // cause was a missing `responseSchema` - the field was described only in prose, so the model
    // was assumed to be omitting the key outright.
    //
    // A controlled live probe (`LiveExtractionSchemaProbeTests`, 12 MEASURED requests against the
    // real Phase 4.2 transcripts and the CleanFixture's real item names) FALSIFIED that
    // hypothesis. The `relatedItemName` key was present in 17 of 17 decision candidates - INCLUDING
    // the schema-OFF control arm, which emitted non-null names 4 times out of 5. The schema was
    // never what governed emission.
    //
    // The single variable that governs it is whether the model is given names it may copy:
    //
    //     canonical names supplied  ->  6/6 decisions carried a non-null, EXACT-canonical name
    //     canonical names empty     ->  0/5 decisions carried a non-null name
    //
    // Zero invented names in either arm. So the 0/7, 0/7, 0/6 was not a defect in the model or the
    // prompt: in a population starting from an EMPTY store, three of the four meetings are their
    // project's FIRST meeting, so no tracked item exists yet and `null` is the only correct answer.
    // What was actually missing is the case below - a decision about work identified in the very
    // same batch, which the prompt never told the model it was allowed to name. That gap is closed
    // in `systemInstruction` above, and it stays an EXACT-string rule, so a name matching nothing
    // simply fails to resolve and yields no link (precision is preserved structurally, not by
    // fuzzy matching).
    //
    // The schema is KEPT regardless, on its own independent merit: `type`, `modality`,
    // `confidence` and `isExplicit` are non-optional on `ExtractionCandidate`, so a response
    // omitting any of them silently fails to decode and the whole candidate is dropped. Declaring
    // them required aligns the wire contract with the decoder. It is no longer claimed to be the
    // fix for emission.
    //
    // Deliberately NOT enum-constrained: `type`, `modality`, `projectItemStatus` etc. are declared
    // as plain strings even though the decoder maps them onto Swift enums. Hard-coding every case
    // list here would duplicate five enums that live in protected foundation files and would
    // silently start rejecting responses the moment one of them gained a case. The prompt already
    // enumerates the allowed values, and `parseExtractions` already drops a candidate whose raw
    // value doesn't decode - that behaviour is unchanged.
    //
    // One flat item schema mirrors `ExtractionCandidate` itself, which is one flat struct with a
    // `type` discriminator rather than a sum type, so no union/`anyOf` construct is needed.
    static func buildRequestPayload(conversationText: String, existingProjectItemNames: [String]) -> [String: Any] {
        [
            "contents": [["role": "user", "parts": [["text": conversationText]]]],
            "systemInstruction": ["parts": [["text": systemInstruction(existingProjectItemNames: existingProjectItemNames)]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": responseSchema,
            ],
        ]
    }

    /// The OpenAPI-subset schema Gemini's `v1beta` `generateContent` accepts under
    /// `generationConfig.responseSchema`. Same raw-REST dictionary style the rest of this file and
    /// `SyntheticGenerationClient` already use - no SDK, no new dependency, no API version change.
    static let responseSchema: [String: Any] = {
        func string(nullable: Bool = true) -> [String: Any] { ["type": "STRING", "nullable": nullable] }

        let candidate: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                // Shared
                "type": ["type": "STRING", "nullable": false],
                "modality": ["type": "STRING", "nullable": false],
                "confidence": ["type": "NUMBER", "nullable": false],
                "isExplicit": ["type": "BOOLEAN", "nullable": true],
                "mentionedProjectName": string(),
                // memoryEdge
                "subjectName": string(),
                "subjectKind": string(),
                "predicate": string(),
                "objectName": string(),
                "objectKind": string(),
                "literalValue": string(),
                "memoryCategory": string(),
                // projectItem
                "projectItemKind": string(),
                "name": string(),
                "itemDescription": string(),
                "projectItemStatus": string(),
                // Shared by projectItem and decision - the whole point of this schema.
                "relatedItemName": string(),
                // decision
                "statement": string(),
                "context": string(),
                "reason": string(),
                "madeByNames": ["type": "ARRAY", "nullable": true, "items": ["type": "STRING"]],
            ],
            // `relatedItemName` is required so the key is always present; it stays nullable so
            // "no tracked item is the subject" remains expressible.
            //
            // The other four mirror what the DECODER already demands: `type`, `modality`,
            // `confidence` and `isExplicit` are non-optional on `ExtractionCandidate`, so a
            // response omitting any of them fails to decode and that candidate is silently
            // dropped. `isExplicit` in particular is easy to omit and was never requested by name
            // in the prompt. Declaring them required aligns the schema with the decoder instead of
            // relying on the model to guess; it does not make any previously-optional field
            // mandatory.
            "required": ["type", "modality", "confidence", "isExplicit", "relatedItemName"],
        ]

        return [
            "type": "OBJECT",
            "properties": ["extractions": ["type": "ARRAY", "items": candidate]],
            "required": ["extractions"],
        ]
    }()

    /// Extracts the model's text response from Gemini's response envelope, then parses THAT
    /// text as the candidate JSON. Split out as its own function (not inline in the dataTask
    /// closure) purely so it's directly unit-testable against fixture response bytes, without
    /// a network call - same pattern GeminiResponseGenerator already uses for
    /// buildContents/extractText.
    static func parseCandidates(from responseData: Data) -> [ExtractionCandidate] {
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let responseCandidates = json["candidates"] as? [[String: Any]],
              let first = responseCandidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first,
              let innerData = text.data(using: .utf8) else {
            return []
        }
        return parseExtractions(from: innerData)
    }

    /// Parses the model's OWN JSON output (`{"extractions": [...]}`) - lenient: if the whole
    /// envelope fails to decode, falls back to decoding each candidate independently and
    /// skipping malformed ones, so one bad candidate never discards an entire otherwise-valid
    /// batch.
    static func parseExtractions(from data: Data) -> [ExtractionCandidate] {
        struct Envelope: Decodable { let extractions: [ExtractionCandidate] }

        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return envelope.extractions
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawExtractions = json["extractions"] as? [[String: Any]] else {
            return []
        }
        return rawExtractions.compactMap { dict in
            guard let itemData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? JSONDecoder().decode(ExtractionCandidate.self, from: itemData)
        }
    }
}
