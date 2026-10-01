import Foundation

// MARK: - Cross-Layer Conflict Resolver
/// The pipeline stage the Stage 1-6 audit found missing: `retrieve -> temporal admissibility ->
/// relevance scoring -> CROSS-LAYER CONFLICT RESOLUTION -> provenance collection -> historical
/// evidence resolution -> budget -> ContextPacket`. Everything upstream of this type already
/// resolves conflicts WITHIN one evidence type (MemoryEdge/Decision supersession chains, via
/// `TemporalStatus.isAdmissible`) - this type is the ACROSS-type counterpart: deciding what to
/// do when a `MemoryEdge`, a `ProjectItem`, and a `Decision` each independently describe what
/// looks like the same real-world fact but disagree about it (e.g. Memory says "database =
/// MongoDB" while a newer Decision says "use PostgreSQL going forward").
///
/// Deliberately NOT a general knowledge graph and NOT an LLM contradiction detector (both
/// explicitly ruled out) - every decision here is a plain, explainable comparison of fields
/// that already exist on these types:
///   - `Decision.relatedItemID` (an existing structural link to a `ProjectItem`)
///   - `MemoryEdge.predicate` used as a topic anchor, checked for a substring match against the
///     other evidence's own text (the closest deterministic proxy to "these two are talking
///     about the same attribute" without semantic understanding - see `sharesTopic` below for
///     the honest limitation this implies)
///   - plain timestamp comparison (`lastConfirmedAt` / `lastUpdatedAt`) when neither side is a
///     Decision
///
/// If none of those signals fire, two items are left completely alone - per the explicit
/// requirement that low-confidence "same fact" guesses must never manufacture a conflict.
enum CrossLayerConflictResolver {
    /// The filtered evidence pools - `decisions` always passes through unchanged (Decisions are
    /// never the LOSING side of a cross-layer conflict, per the "explicit decisions win"
    /// requirement), so it isn't even a candidate for filtering here.
    struct Resolution {
        let memories: [ScoredEvidence<MemoryEdge>]
        let projectItems: [ScoredEvidence<ProjectItem>]
    }

    /// Applies cross-layer conflict resolution to an already-retrieved, already-temporally-
    /// admissible, already-scored evidence pool.
    ///
    /// For CURRENT/unspecified-intent questions, the losing side of an established conflict is
    /// EXCLUDED outright (not merely score-demoted) - simpler, fully deterministic, and easy to
    /// explain/test than a fuzzy demotion factor, satisfying the "demoted or excluded" language
    /// with the more explainable of the two options.
    ///
    /// For HISTORICAL/changeReason/whenDecided intent, this is a complete no-op: nothing is
    /// excluded. Those intents already rely on `TemporalStatus.isAdmissible` upstream to let
    /// superseded/invalidated evidence back into the pool on purpose - cross-layer exclusion
    /// would undo exactly the thing that stage was for.
    static func resolve(
        memories: [ScoredEvidence<MemoryEdge>],
        projectItems: [ScoredEvidence<ProjectItem>],
        decisions: [ScoredEvidence<Decision>],
        intent: TemporalQueryClassifier.Intent
    ) -> Resolution {
        guard intent == .current || intent == .unspecified else {
            return Resolution(memories: memories, projectItems: projectItems)
        }

        var excludedMemoryIDs = Set<UUID>()
        var excludedProjectItemIDs = Set<UUID>()

        // Decision vs Memory - an explicit Decision addressing the same topic always wins.
        for decision in decisions {
            for memory in memories where !excludedMemoryIDs.contains(memory.value.id) {
                if sharesTopic(predicate: memory.value.predicate, in: renderedText(decision.value)) {
                    excludedMemoryIDs.insert(memory.value.id)
                }
            }
        }

        // Decision vs ProjectItem - only the EXISTING structural link is trusted here
        // (`Decision.relatedItemID`), never a lexical guess - ProjectItem names/descriptions
        // are too free-form for a substring match to stay conservative enough.
        for decision in decisions {
            guard let relatedItemID = decision.value.relatedItemID else { continue }
            for item in projectItems where item.value.id == relatedItemID {
                excludedProjectItemIDs.insert(item.value.id)
            }
        }

        // Memory vs ProjectItem - neither is a Decision, so fall back to "strictly newer wins."
        // Equal timestamps are left untouched (requirement: can't confidently decide -> keep
        // both), which also makes this comparison naturally order-independent.
        for item in projectItems where !excludedProjectItemIDs.contains(item.value.id) {
            for memory in memories where !excludedMemoryIDs.contains(memory.value.id) {
                guard sharesTopic(predicate: memory.value.predicate, in: renderedText(item.value)) else { continue }
                if item.value.lastUpdatedAt > memory.value.lastConfirmedAt {
                    excludedMemoryIDs.insert(memory.value.id)
                } else if memory.value.lastConfirmedAt > item.value.lastUpdatedAt {
                    excludedProjectItemIDs.insert(item.value.id)
                }
            }
        }

        return Resolution(
            memories: memories.filter { !excludedMemoryIDs.contains($0.value.id) },
            projectItems: projectItems.filter { !excludedProjectItemIDs.contains($0.value.id) }
        )
    }

    /// The "same fact" signal used for any comparison involving a `MemoryEdge`: does the
    /// edge's OWN predicate (its stated attribute - "database", "prefers", "studies-at", ...)
    /// appear anywhere in the other evidence's rendered text. This is a conservative, fully
    /// deterministic proxy for topical overlap, NOT semantic equivalence - it depends on the
    /// other evidence's text actually mentioning that attribute word (e.g. a Decision's
    /// `context` field naming "database"). A Decision that changes the database without ever
    /// using that word (context/statement/reason all silent on it) will NOT be detected as
    /// addressing the same fact - a known, honest limitation of a keyword-only V1, consistent
    /// with `RetrievalProvider`'s own documented limitation.
    private static func sharesTopic(predicate: String, in text: String) -> Bool {
        let token = predicate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard token.count > 2 else { return false }
        return text.lowercased().contains(token)
    }

    private static func renderedText(_ decision: Decision) -> String {
        [decision.statement, decision.context ?? "", decision.reason ?? ""].joined(separator: " ")
    }

    private static func renderedText(_ item: ProjectItem) -> String {
        [item.name, item.description ?? ""].joined(separator: " ")
    }
}
