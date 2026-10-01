import Foundation

/// Generates a response from a bounded, structured conversation context on demand - a
/// one-shot `streamGenerateContent` REST call (Server-Sent Events), deliberately NOT the
/// Live WebSocket. This is what makes "Respond Now" robust to the live transcription
/// connection dropping or reconnecting: the response is grounded in our own locally-stored
/// message history (never pruned, see AIEngineController/ChatSessionManager), not in a
/// fragile long-lived session's internal state. If that connection dies mid-listening, at
/// most a few seconds of transcription are lost - a response can still be generated from
/// everything captured before that.
///
/// Streaming (rather than plain `generateContent`) exists purely to fix perceived latency:
/// a non-streaming call blocks until the model has generated the ENTIRE answer before
/// sending back a single byte, so a multi-sentence reply can take several real seconds to
/// appear with nothing shown in between. Total generation time is about the same either
/// way, but streaming delivers the first words within a few hundred ms and fills in
/// progressively after that - the same feel the old Live-based replies had.
/// https://ai.google.dev/api/generate-content#method:-models.streamgeneratecontent
final class GeminiResponseGenerator {
    private let apiKey: String
    private let model: String
    private let urlSession = URLSession(configuration: .default)

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    /// `context` becomes a genuine multi-turn conversation in the request (`.heard` -> role
    /// "user", `.response` -> role "model"), not one flattened string - this is what lets
    /// Gemini resolve a follow-up question ("what was the number?") against an actual prior
    /// exchange, the same shape it's trained on, instead of parsing prose describing one. See
    /// ChatSessionManager.responseContext(recentContextLimit:) for how `context` is built
    /// (bounded recent history + the current turn) and why.
    ///
    /// `onPartialText` fires with each new DELTA of text as it streams in (not the
    /// cumulative text so far) - the caller appends it to whatever it's already
    /// accumulated, same pattern as the old Live textDelta events. `completion` fires
    /// exactly once when the stream ends, successfully or not; on failure, any text already
    /// delivered via onPartialText is NOT rolled back - the caller decides what, if
    /// anything, to show for a request that failed partway through.
    /// `screenFrameJPEG` (Phase 3, Option B) is an optional single still of what is on screen
    /// right now, attached to the newest user turn. Nil - the default - produces a request that
    /// is byte-for-byte identical to before Phase 3, which is what makes "permission denied /
    /// capture failed" degrade silently to the existing text-only path.
    func generate(
        systemInstruction: String,
        context: [ChatMessage],
        screenFrameJPEG: Data? = nil,
        onPartialText: @escaping (String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse") else {
            completion(.failure(URLError(.badURL)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let payload: [String: Any] = [
            "contents": Self.buildContents(from: context, screenFrameJPEG: screenFrameJPEG),
            "systemInstruction": [
                "parts": [["text": systemInstruction]]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        print("[GeminiResponse] Requesting streamed response for \(context.count) messages of context, model=\(model)")

        Task {
            do {
                let (bytes, response) = try await urlSession.bytes(for: request)

                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    var body = ""
                    for try await line in bytes.lines { body += line }
                    print("[GeminiResponse] HTTP \(http.statusCode): \(body.prefix(500))")
                    completion(.failure(NSError(domain: "GeminiResponseGenerator", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])))
                    return
                }

                var receivedAnyText = false
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let jsonText = String(line.dropFirst("data: ".count))
                    guard let data = jsonText.data(using: .utf8),
                          let delta = Self.extractText(from: data),
                          !delta.isEmpty else { continue }
                    receivedAnyText = true
                    onPartialText(delta)
                }

                print("[GeminiResponse] Stream finished (\(receivedAnyText ? "received text" : "no text"))")
                if receivedAnyText {
                    completion(.success(()))
                } else {
                    completion(.failure(NSError(domain: "GeminiResponseGenerator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Stream ended with no text"])))
                }
            } catch {
                print("[GeminiResponse] Streaming request failed: \(error)")
                completion(.failure(error))
            }
        }
    }

    /// Maps `.heard` -> "user" / `.response` -> "model" and merges any consecutive same-role
    /// messages into one turn - Gemini's `contents` array expects alternating roles. Normal
    /// operation already alternates strictly (ChatSessionManager only ever starts a new
    /// `.heard` message right after a `.response` closes the previous turn), so this merge
    /// should rarely if ever actually combine anything - it exists as a defensive guarantee
    /// against sending an invalid non-alternating request, not because it's expected to
    /// trigger regularly.
    ///
    /// `screenFrameJPEG`, when present, is appended as exactly ONE `inlineData` part on the
    /// NEWEST user turn - "here is what's on screen as I ask this". It is never merged into the
    /// text, never sent as its own turn, and never attached to a model turn. When nil, this
    /// function's output is unchanged from before Phase 3.
    static func buildContents(from context: [ChatMessage], screenFrameJPEG: Data? = nil) -> [[String: Any]] {
        var contents: [[String: Any]] = []
        for message in context {
            let role = message.role == .response ? "model" : "user"
            if let lastIndex = contents.indices.last,
               contents[lastIndex]["role"] as? String == role,
               var parts = contents[lastIndex]["parts"] as? [[String: Any]],
               let previousText = parts[0]["text"] as? String {
                parts[0]["text"] = previousText + "\n" + message.text
                contents[lastIndex]["parts"] = parts
            } else {
                contents.append(["role": role, "parts": [["text": message.text]]])
            }
        }

        if let screenFrameJPEG, !screenFrameJPEG.isEmpty,
           let newestUserTurn = contents.lastIndex(where: { $0["role"] as? String == "user" }),
           var parts = contents[newestUserTurn]["parts"] as? [[String: Any]] {
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": screenFrameJPEG.base64EncodedString()]])
            contents[newestUserTurn]["parts"] = parts
        }
        return contents
    }

    /// Each SSE `data:` line is itself a complete GenerateContentResponse chunk, the same
    /// shape a non-streaming generateContent call returns - so this extracts the delta text
    /// from one chunk the same way it would extract the whole answer from a single response.
    private static func extractText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return nil
        }
        return parts.compactMap { $0["text"] as? String }.joined()
    }
}
