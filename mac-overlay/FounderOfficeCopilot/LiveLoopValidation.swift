#if DEBUG
import Foundation

// MARK: - Live Loop Validation
// DEVELOPER TOOLING (not product UI, unreachable from any menu). Drives the REAL core loop once
// and prints what actually happened, so "chat produces an answer with real, navigable sources"
// can be verified rather than assumed.
//
// It uses the production `AIEngineController.requestResponse()`, the production `ContextEngine`,
// the production `GeminiResponseGenerator` and the production `ResponseEvidenceStore`. Nothing is
// stubbed: if this prints sources, those sources came from a real retrieval over real stores.
@MainActor
enum LiveLoopValidation {
    /// `--validate-loop=<question> [--validate-stores=<dir>]`
    static func runIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let question = value(of: "--validate-loop", in: arguments) else { return false }

        let engine: AIEngineController
        if let directory = value(of: "--validate-stores", in: arguments) {
            let base = URL(fileURLWithPath: directory, isDirectory: true)
            engine = AIEngineController(
                chatSessionManager: ChatSessionManager(store: ChatSessionStore(storeURL: base.appendingPathComponent("ChatSessions.sqlite"))),
                memoryManager: MemoryManager(store: MemoryStore(storeURL: base.appendingPathComponent("Memory.sqlite"))),
                projectManager: ProjectManager(store: ProjectStore(storeURL: base.appendingPathComponent("Projects.sqlite")))
            )
        } else {
            engine = AIEngineController()
        }

        log("=== LIVE CORE-LOOP VALIDATION ===")
        log("question: \(question)")
        log("api key present: \(engine.hasAPIKey)")
        guard engine.hasAPIKey else { log("FAIL: no API key"); exit(1) }

        // Exactly what ChatView.send() does, including scoping the session to a project -
        // without which retrieval has nothing to scope to (ProjectResolution Tier 1).
        let sessionID = engine.chatSessionManager.beginRecording()
        if let projectName = value(of: "--validate-project", in: arguments),
           let project = engine.projectManager.projects.first(where: { $0.name.localizedCaseInsensitiveContains(projectName) }) {
            engine.projectManager.assignSession(sessionID, to: project.id)
            log("scoped to project: \(project.name)")
        }
        log("session: \(sessionID) (listening=\(engine.isListening) — typing must NOT need audio)")
        engine.chatSessionManager.appendHeardDelta(question)
        engine.requestResponse()

        var polls = 0
        func poll() {
            polls += 1
            let messages = engine.chatSessionManager.sessions.first { $0.id == sessionID }?.messages ?? []
            let response = messages.last { $0.role == .response }
            if let response, !response.isStreaming, !response.text.isEmpty {
                report(engine: engine, response: response)
                exit(0)
            }
            if polls > 90 { log("FAIL: no response after \(polls) polls"); exit(1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { poll() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { poll() }
        return true
    }

    private static func report(engine: AIEngineController, response: ChatMessage) {
        log("")
        log("--- ANSWER (\(response.text.count) chars) ---")
        log(response.text)

        let sources = engine.responseEvidence.references(for: response.id)
        log("")
        log("--- SOURCES: \(sources.count) ---")
        for source in sources {
            let entity = EntityReference(source)
            let target: String
            switch entity?.kind {
            case .decision(let id): target = "decision(\(id))"
            case .workItem(let id): target = "workItem(\(id))"
            case .project(let id): target = "project(\(id))"
            case .person(let id): target = "person(\(id))"
            case .conversation(let id): target = "conversation(\(id))"
            case nil: target = "NON-NAVIGABLE (no retrieval identifier)"
            }
            log("  [\(source.kind.label)] \(source.title)")
            log("      -> \(target)")
            // Independently confirm the target actually resolves in the stores.
            if let entity {
                let resolved: String
                switch entity.kind {
                case .decision(let id): resolved = engine.projectManager.decision(id: id)?.statement ?? "MISSING"
                case .workItem(let id): resolved = engine.projectManager.projectItem(id: id)?.name ?? "MISSING"
                case .project(let id): resolved = engine.projectManager.project(id: id)?.name ?? "MISSING"
                case .person(let id): resolved = engine.memoryManager.entities.first { $0.id == id }?.name ?? "MISSING"
                case .conversation(let id): resolved = engine.chatSessionManager.sessions.first { $0.id == id }?.title ?? "MISSING"
                }
                log("      resolves to: \(resolved)")
            }
        }
        log("")
        log("=== SUMMARY: answer=\(response.text.isEmpty ? "NO" : "YES") sources=\(sources.count) navigable=\(sources.compactMap(EntityReference.init).count) ===")
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix(flag + "=") }?.split(separator: "=", maxSplits: 1).last.map(String.init)
    }

    private static func log(_ message: String) { print(message); fflush(stdout) }
}
#endif
