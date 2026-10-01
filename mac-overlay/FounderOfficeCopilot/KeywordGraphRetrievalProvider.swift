import Foundation

// MARK: - Keyword/Graph Retrieval Provider
/// The V1 `RetrievalProvider` - keyword/exact matching, entity matching, shallow UUID graph
/// traversal (decision supersession chains), temporal filtering, and project filtering. NO
/// embeddings, NO vector database, NO network calls of any kind - every method reads only
/// already-loaded in-memory state from `MemoryManager`/`ProjectManager`/`ChatSessionManager`,
/// never issuing a fresh Core Data query or scanning full conversation history.
///
/// Project isolation is enforced structurally: `retrieveProjectItems`/`retrieveDecisions`/
/// `retrieveProjectEvents`/`retrieveEpisodes` all return empty immediately when
/// `query.activeProjectID` is nil - there is no code path here that falls back to scanning
/// across all projects.
final class KeywordGraphRetrievalProvider: RetrievalProvider {
    private let memoryManager: MemoryManager
    private let projectManager: ProjectManager
    private let chatSessionManager: ChatSessionManager

    init(memoryManager: MemoryManager, projectManager: ProjectManager, chatSessionManager: ChatSessionManager) {
        self.memoryManager = memoryManager
        self.projectManager = projectManager
        self.chatSessionManager = chatSessionManager
    }

    // MARK: Memory

    func retrieveMemories(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<MemoryEdge>] {
        let candidates = memoryManager.edges.filter { edge in
            guard !edge.isPinned, edge.status != .forgotten else { return false }
            return TemporalStatus.isAdmissible(status: TemporalStatus.classify(memoryEdgeStatus: edge.status), intent: query.temporalIntent)
        }
        return topK(candidates.map { scoreMemoryEdge($0, query: query) }, limit: limit)
    }

    func retrieveProceduralInstructions(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<MemoryEdge>] {
        // Pinned instructions are always eligible regardless of topical keyword match - they
        // still get scored (for ordering/budget purposes later) but are never filtered out by
        // relevance the way normal facts are.
        let candidates = memoryManager.edges.filter { $0.isPinned && $0.status == .active }
        return topK(candidates.map { scoreMemoryEdge($0, query: query) }, limit: limit)
    }

    private func scoreMemoryEdge(_ edge: MemoryEdge, query: RetrievalQuery) -> ScoredEvidence<MemoryEdge> {
        let subjectName = memoryManager.entity(id: edge.subjectEntityID)?.name ?? ""
        let objectName = edge.objectEntityID.flatMap { memoryManager.entity(id: $0)?.name } ?? ""
        let renderedText = "\(subjectName) \(edge.predicate) \(edge.literalValue ?? objectName)"
            .trimmingCharacters(in: .whitespaces)
        let factors = RelevanceScoring.Factors(
            keywordOverlap: RelevanceScoring.keywordOverlap(query: query.text, text: renderedText),
            projectMatch: false,
            recency: RelevanceScoring.recencyScore(date: edge.lastConfirmedAt, now: query.now),
            confidence: Double(edge.confidence),
            isPinned: edge.isPinned,
            confirmationCount: edge.confirmationCount,
            relationshipProximity: 0
        )
        return ScoredEvidence(
            value: edge,
            source: .memoryEdge(edge.id),
            score: RelevanceScoring.score(factors),
            temporalStatus: TemporalStatus.classify(memoryEdgeStatus: edge.status),
            provenance: Provenance(sourceSessionID: edge.sourceSessionID, sourceMessageIDs: edge.sourceMessageIDs, timestamp: edge.lastConfirmedAt),
            renderedText: renderedText
        )
    }

    // MARK: Project Items

    func retrieveProjectItems(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<ProjectItem>] {
        guard let projectID = query.activeProjectID else { return [] }
        let candidates = projectManager.items(forProject: projectID).filter { item in
            TemporalStatus.isAdmissible(status: TemporalStatus.classify(projectItemStatus: item.status), intent: query.temporalIntent)
        }
        let scored = candidates.map { item -> ScoredEvidence<ProjectItem> in
            let renderedText = "\(item.name) \(item.description ?? "")".trimmingCharacters(in: .whitespaces)
            let factors = RelevanceScoring.Factors(
                keywordOverlap: RelevanceScoring.keywordOverlap(query: query.text, text: renderedText),
                projectMatch: true,
                recency: RelevanceScoring.recencyScore(date: item.lastUpdatedAt, now: query.now),
                confidence: Double(item.confidence),
                isPinned: false,
                confirmationCount: 0,
                relationshipProximity: 0
            )
            return ScoredEvidence(
                value: item,
                source: .projectItem(item.id),
                score: RelevanceScoring.score(factors),
                temporalStatus: TemporalStatus.classify(projectItemStatus: item.status),
                provenance: Provenance(sourceSessionID: item.sourceSessionID, sourceMessageIDs: item.sourceMessageIDs, timestamp: item.lastUpdatedAt),
                renderedText: renderedText
            )
        }
        return topK(scored, limit: limit)
    }

    // MARK: Decisions (includes shallow supersession-chain graph traversal)

    func retrieveDecisions(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<Decision>] {
        guard let projectID = query.activeProjectID else { return [] }
        let allDecisions = projectManager.decisions(forProject: projectID)

        var admissible = allDecisions.filter { decision in
            TemporalStatus.isAdmissible(status: TemporalStatus.classify(decisionStatus: decision.status), intent: query.temporalIntent)
        }

        // "Why did we change" / "when was this decided" - traverse the supersession chain
        // backward from each active decision, surfacing prior superseded decisions in the
        // SAME chain even if the base admissibility filter alone excluded them.
        if query.temporalIntent == .changeReason || query.temporalIntent == .whenDecided {
            let existingIDs = Set(admissible.map(\.id))
            var chained: [Decision] = []
            for decision in allDecisions where decision.status == .active {
                chained.append(contentsOf: supersessionChain(from: decision, in: allDecisions))
            }
            admissible += chained.filter { !existingIDs.contains($0.id) }
        }

        let scored = admissible.map { decision -> ScoredEvidence<Decision> in
            let renderedText = "\(decision.statement) \(decision.context ?? "") \(decision.reason ?? "")"
                .trimmingCharacters(in: .whitespaces)
            let factors = RelevanceScoring.Factors(
                keywordOverlap: RelevanceScoring.keywordOverlap(query: query.text, text: renderedText),
                projectMatch: true,
                recency: RelevanceScoring.recencyScore(date: decision.decidedAt, now: query.now),
                // Decision carries no confidence field of its own - a recorded decision is
                // treated as fully confident once persisted.
                confidence: 1.0,
                isPinned: false,
                confirmationCount: 0,
                relationshipProximity: 0
            )
            return ScoredEvidence(
                value: decision,
                source: .decision(decision.id),
                score: RelevanceScoring.score(factors),
                temporalStatus: TemporalStatus.classify(decisionStatus: decision.status),
                provenance: Provenance(sourceSessionID: decision.sourceSessionID, sourceMessageIDs: decision.sourceMessageIDs, timestamp: decision.decidedAt),
                renderedText: renderedText
            )
        }
        return topK(scored, limit: limit)
    }

    /// Follows `supersedes` links backward from `decision` until the chain ends - "shallow" in
    /// the sense that decision chains don't fan out or cycle by construction (each
    /// `supersedes` points at exactly one prior decision), so no arbitrary hop-count cap is
    /// needed; `seen` still guards against a malformed cycle defensively.
    private func supersessionChain(from decision: Decision, in decisions: [Decision]) -> [Decision] {
        var chain: [Decision] = []
        var current = decision
        var seen: Set<UUID> = [decision.id]
        while let priorID = current.supersedes,
              let prior = decisions.first(where: { $0.id == priorID }),
              !seen.contains(prior.id) {
            chain.append(prior)
            seen.insert(prior.id)
            current = prior
        }
        return chain
    }

    // MARK: Project Events

    func retrieveProjectEvents(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<ProjectEvent>] {
        guard let projectID = query.activeProjectID else { return [] }
        let scored = projectManager.events(forProject: projectID).map { event -> ScoredEvidence<ProjectEvent> in
            let factors = RelevanceScoring.Factors(
                keywordOverlap: RelevanceScoring.keywordOverlap(query: query.text, text: event.description),
                projectMatch: true,
                recency: RelevanceScoring.recencyScore(date: event.occurredAt, now: query.now),
                confidence: 1.0,
                isPinned: false,
                confirmationCount: 0,
                relationshipProximity: 0
            )
            return ScoredEvidence(
                value: event,
                source: .projectEvent(event.id),
                score: RelevanceScoring.score(factors),
                temporalStatus: .current,
                provenance: Provenance(sourceSessionID: event.sourceSessionID, sourceMessageIDs: event.sourceMessageIDs, timestamp: event.occurredAt),
                renderedText: event.description
            )
        }
        return topK(scored, limit: limit)
    }

    // MARK: Episodes

    func retrieveEpisodes(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<EpisodeSummary>] {
        guard let projectID = query.activeProjectID else { return [] }
        let sessionIDs = Set(projectManager.sessions(forProject: projectID))
        let episodes = sessionIDs.compactMap {
            EpisodeSummary.build(forSession: $0, chatSessionManager: chatSessionManager, projectManager: projectManager)
        }
        let scored = episodes.map { episode -> ScoredEvidence<EpisodeSummary> in
            let renderedText = ([episode.title, episode.checkpointSummary ?? ""] + episode.decisions.map(\.statement) + episode.projectItems.map(\.name))
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let factors = RelevanceScoring.Factors(
                keywordOverlap: RelevanceScoring.keywordOverlap(query: query.text, text: renderedText),
                projectMatch: true,
                recency: RelevanceScoring.recencyScore(date: episode.occurredAt, now: query.now),
                confidence: 1.0,
                isPinned: false,
                confirmationCount: 0,
                relationshipProximity: 0
            )
            return ScoredEvidence(
                value: episode,
                source: .episode(sessionID: episode.sessionID),
                score: RelevanceScoring.score(factors),
                temporalStatus: .current,
                provenance: Provenance(sourceSessionID: episode.sessionID, sourceMessageIDs: episode.sourceMessageIDs, timestamp: episode.occurredAt),
                renderedText: renderedText
            )
        }
        return topK(scored, limit: limit)
    }

    // MARK: Historical Evidence (resolve known references only - never an independent search)

    func retrieveHistoricalEvidence(for references: [EvidenceReference], limit: Int) -> [ScoredEvidence<ChatMessage>] {
        references.prefix(limit).compactMap { reference in
            guard let session = chatSessionManager.sessions.first(where: { $0.id == reference.sessionID }),
                  let message = session.messages.first(where: { $0.id == reference.messageID }) else { return nil }
            return ScoredEvidence(
                value: message,
                source: .chatMessage(sessionID: reference.sessionID, messageID: message.id),
                score: 1.0,
                temporalStatus: .current,
                provenance: Provenance(sourceSessionID: reference.sessionID, sourceMessageIDs: [message.id], timestamp: message.timestamp),
                renderedText: message.text
            )
        }
    }

    // MARK: Shared

    private func topK<T>(_ scored: [ScoredEvidence<T>], limit: Int) -> [ScoredEvidence<T>] {
        Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }
}
