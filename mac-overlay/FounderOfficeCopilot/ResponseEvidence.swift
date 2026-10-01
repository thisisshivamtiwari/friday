import Foundation

// MARK: - Response Evidence
/// One source behind an answer, in a form the UI can show and navigate. Distinct from the
/// retrieval layer's own `EvidenceReference` (a raw ChatMessage pointer): this is the
/// user-facing concept - a decision, a work item, a conversation - not a storage address.
///
/// THE CRITICAL PROPERTY: this is derived from the `ContextPacket` that was genuinely assembled
/// for a specific response, and every reference carries the retrieval layer's own typed
/// `EvidenceSource` - a real `Decision`/`ProjectItem`/`ChatMessage` id. Sources are therefore
/// REAL and clickable by construction.
///
/// It is emphatically NOT reconstructed from the answer text. Parsing an answer for things that
/// look like citations would invent sources the model never saw and attach confident provenance
/// to a hallucination - the exact opposite of what this feature exists to provide. If the packet
/// held no evidence, this is empty, and the UI says so.
struct AnswerSource: Identifiable, Equatable {
    enum Kind: String {
        case decision
        case workItem
        case memory
        case conversation
        case episode
        /// A still of the screen, sent only when the user has enabled screen context.
        case screen

        /// The user-facing name. Deliberately plain English - the UI never shows internal
        /// vocabulary like "memoryEdge" or "ScoredEvidence".
        var label: String {
            switch self {
            case .decision: return "Decision"
            case .workItem: return "Work item"
            case .memory: return "Remembered fact"
            case .conversation: return "Conversation"
            case .episode: return "Past meeting"
            case .screen: return "Your screen"
            }
        }

        var icon: String {
            switch self {
            case .decision: return "checkmark.seal"
            case .workItem: return "checklist"
            case .memory: return "brain"
            case .conversation: return "text.bubble"
            case .episode: return "calendar"
            case .screen: return "display"
            }
        }
    }

    let id: String
    let kind: Kind
    /// The evidence's own text, as it was given to the model - not a paraphrase.
    let title: String
    /// Project name, date, or other locating detail. Nil when there genuinely isn't one.
    let subtitle: String?
    let timestamp: Date
    /// The retrieval layer's typed identifier. This is what makes a source navigable.
    /// The retrieval layer's typed identifier, or nil for a source that did not come from
    /// retrieval at all (the screen capture). A nil identifier is what makes such a source
    /// visible but non-navigable, rather than silently omitted.
    let source: EvidenceSource?
}

// MARK: - Builder

enum AnswerSourceBuilder {
    /// Flattens a `ContextPacket` into the references the UI shows, newest-first within kind and
    /// ordered by the layer's importance to a founder: decisions, then work, then remembered
    /// facts, then conversational provenance.
    ///
    /// `projectNameForItem`/`projectNameForDecision` are injected rather than looked up here so
    /// this stays a pure function - it is fully testable with no managers and no store.
    /// `currentSessionID` is the conversation the answer is being given IN. It is excluded,
    /// because citing the conversation you are currently having as a source for its own answer is
    /// circular: the user can already see it, and it crowds out the stored knowledge that
    /// actually justifies the claim. Observed live before this was added.
    static func references(
        from packet: ContextPacket,
        currentSessionID: UUID? = nil,
        projectNameForItem: (UUID) -> String? = { _ in nil },
        projectNameForDecision: (UUID) -> String? = { _ in nil },
        sessionTitle: (UUID) -> String? = { _ in nil }
    ) -> [AnswerSource] {
        var references: [AnswerSource] = []

        for evidence in packet.relevantDecisions {
            references.append(AnswerSource(
                id: "decision-\(evidence.value.id)",
                kind: .decision,
                title: evidence.value.statement,
                subtitle: projectNameForDecision(evidence.value.id) ?? evidence.value.context,
                timestamp: evidence.value.decidedAt,
                source: evidence.source
            ))
        }

        for evidence in packet.relevantProjectItems {
            references.append(AnswerSource(
                id: "item-\(evidence.value.id)",
                kind: .workItem,
                title: evidence.value.name,
                subtitle: projectNameForItem(evidence.value.id),
                timestamp: evidence.value.lastUpdatedAt,
                source: evidence.source
            ))
        }

        // Procedural instructions are standing behavioural rules, not subject-matter evidence,
        // so they are deliberately excluded - listing "always be concise" as a source for an
        // answer about calibration would be noise presented as provenance.
        for evidence in packet.relevantMemories {
            references.append(AnswerSource(
                id: "memory-\(evidence.value.id)",
                kind: .memory,
                title: evidence.renderedText,
                subtitle: nil,
                timestamp: evidence.provenance.timestamp,
                source: evidence.source
            ))
        }

        for evidence in packet.relevantEpisodes where evidence.value.sessionID != currentSessionID {
            references.append(AnswerSource(
                id: "episode-\(evidence.value.sessionID)",
                kind: .episode,
                title: evidence.value.title,
                subtitle: sessionTitle(evidence.value.sessionID),
                timestamp: evidence.value.occurredAt,
                source: evidence.source
            ))
        }

        // Verbatim past messages. Grouped BY CONVERSATION rather than listed per message: five
        // excerpts from one meeting is one source a founder recognises, not five.
        var seenSessions: Set<UUID> = []
        for evidence in packet.historicalEvidence {
            guard let sessionID = evidence.provenance.sourceSessionID, sessionID != currentSessionID,
                  seenSessions.insert(sessionID).inserted else { continue }
            references.append(AnswerSource(
                id: "session-\(sessionID)",
                kind: .conversation,
                title: sessionTitle(sessionID) ?? "Earlier conversation",
                subtitle: evidence.renderedText,
                timestamp: evidence.provenance.timestamp,
                source: evidence.source
            ))
        }

        // One entity is ONE source, however many retrieval layers surfaced it. A meeting that is
        // both a summarised episode AND the origin of a verbatim excerpt was previously listed
        // twice, which reads as two independent corroborations when it is one. The first
        // occurrence wins, so the ordering above (decisions, then work, then memory) decides
        // which framing survives.
        // Keyed on the resolved ENTITY, not the raw evidence source: an episode
        // (`.episode(sessionID:)`) and a verbatim excerpt (`.chatMessage(sessionID:messageID:)`)
        // are different evidence records naming the SAME conversation, and keying on the raw
        // source treats them as two sources. `EntityReference` already defines what "the same
        // thing" means for navigation, so reusing it keeps dedup and navigation agreeing.
        var seenTargets: Set<String> = []
        return references.filter { reference in
            guard let key = EntityReference(reference)?.id else { return true }
            return seenTargets.insert(key).inserted
        }
    }
}

// MARK: - Store

/// Holds the evidence for responses produced in this session, keyed by the response message's
/// own id.
///
/// DELIBERATELY IN-MEMORY AND BOUNDED. Evidence is a property of one generation - it describes
/// what retrieval found at that instant - and persisting it would mean either duplicating
/// records that can later change underneath it, or storing ids whose targets may be gone.
/// Reopening the app therefore shows past answers without a sources chip rather than with a
/// stale or lying one, which is the honest failure mode.
final class ResponseEvidenceStore: ObservableObject {
    @Published private(set) var referencesByMessageID: [UUID: [AnswerSource]] = [:]

    /// Keeps the most recent `limit` responses' evidence. A long meeting can produce a great
    /// many answers, and this is a convenience cache, not a record.
    private let limit: Int
    private var insertionOrder: [UUID] = []

    init(limit: Int = 200) { self.limit = limit }

    func record(_ references: [AnswerSource], for messageID: UUID) {
        guard !references.isEmpty else { return }
        if referencesByMessageID[messageID] == nil { insertionOrder.append(messageID) }
        referencesByMessageID[messageID] = references

        while insertionOrder.count > limit {
            let oldest = insertionOrder.removeFirst()
            referencesByMessageID.removeValue(forKey: oldest)
        }
    }

    /// Adds a source to an answer that already has (or may later have) others. Used for the
    /// screen capture, which is genuinely part of what the model saw but is not retrieval
    /// evidence and therefore never appears in the `ContextPacket`.
    func append(_ kind: AnswerSource.Kind, for messageID: UUID) {
        guard kind == .screen else { return }
        let source = AnswerSource(
            id: "screen-\(messageID)", kind: .screen,
            title: "A still of your screen was included",
            subtitle: "Turn off Screen context in Settings to stop sending this",
            timestamp: Date(), source: nil
        )
        if referencesByMessageID[messageID] == nil { insertionOrder.append(messageID) }
        referencesByMessageID[messageID, default: []].insert(source, at: 0)
    }

    func references(for messageID: UUID) -> [AnswerSource] {
        referencesByMessageID[messageID] ?? []
    }
}
