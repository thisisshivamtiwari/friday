import Foundation

// MARK: - Relevance Scoring
/// Pure, deterministic salience/ranking logic - no network, no Core Data, no dependency on
/// any manager. Deliberately combines SEVERAL weighted factors rather than any single one:
/// explicitly NOT "just recency" (§8 of the approved design), and explicitly NOT the same
/// thing as `MemoryEdge.staleThreshold`'s 90-day maintenance cutoff, which governs a
/// completely different concern (visual de-emphasis / retrieval floor) and remains untouched -
/// `recencyScore` below uses its own, separate, gentler decay curve purely for ranking.
enum RelevanceScoring {
    /// The inputs to one evidence item's score - all normalized to comparable ranges so the
    /// fixed weights in `score(_:)` mean the same thing regardless of which factor produced
    /// them.
    struct Factors: Equatable {
        /// 0...1 - token overlap between the query and this evidence's rendered text.
        var keywordOverlap: Double = 0
        /// Whether this evidence belongs to the resolved active project (irrelevant/false for
        /// evidence that isn't project-scoped, e.g. plain Memory).
        var projectMatch: Bool = false
        /// 0...1 - a soft recency signal (see `recencyScore(date:now:halfLife:)`), NOT the
        /// 90-day stale-maintenance threshold.
        var recency: Double = 0
        /// 0...1 - the evidence's own stored confidence, where applicable (0 if none).
        var confidence: Double = 0
        var isPinned: Bool = false
        /// How many times this fact has been independently corroborated - diminishing
        /// contribution past a handful of confirmations, same spirit as the confidence-growth
        /// model already used at write time.
        var confirmationCount: Int = 0
        /// 0...1 - how directly connected this evidence is to whatever the current
        /// conversation/other retrieved evidence is already anchored on (e.g. shares a
        /// subject entity) - the "shallow graph traversal" signal.
        var relationshipProximity: Double = 0

        init(
            keywordOverlap: Double = 0,
            projectMatch: Bool = false,
            recency: Double = 0,
            confidence: Double = 0,
            isPinned: Bool = false,
            confirmationCount: Int = 0,
            relationshipProximity: Double = 0
        ) {
            self.keywordOverlap = keywordOverlap
            self.projectMatch = projectMatch
            self.recency = recency
            self.confidence = confidence
            self.isPinned = isPinned
            self.confirmationCount = confirmationCount
            self.relationshipProximity = relationshipProximity
        }
    }

    /// Fixed weights, chosen so keyword/project relevance (what the question is actually
    /// about) dominate over softer signals like recency/confidence - deliberately NOT
    /// recency-first. Exposed as named constants (not inlined magic numbers) so a future
    /// tuning pass has one place to look, without needing to restructure the function itself.
    private static let keywordWeight = 0.30
    private static let projectMatchWeight = 0.20
    private static let recencyWeight = 0.15
    private static let confidenceWeight = 0.15
    private static let pinnedWeight = 0.10
    private static let confirmationWeight = 0.05
    private static let relationshipWeight = 0.05

    static func score(_ factors: Factors) -> Double {
        var total = 0.0
        total += factors.keywordOverlap.clamped01 * keywordWeight
        total += (factors.projectMatch ? 1.0 : 0.0) * projectMatchWeight
        total += factors.recency.clamped01 * recencyWeight
        total += factors.confidence.clamped01 * confidenceWeight
        total += (factors.isPinned ? 1.0 : 0.0) * pinnedWeight
        total += min(Double(factors.confirmationCount) / 5.0, 1.0) * confirmationWeight
        total += factors.relationshipProximity.clamped01 * relationshipWeight
        return total
    }

    /// Simple token-overlap (Jaccard-against-the-query) - no embeddings, no semantic
    /// similarity, exactly the "keyword/exact matching" V1 is scoped to. Tokens shorter than 3
    /// characters are dropped (articles/prepositions add noise, not signal) and comparison is
    /// case-insensitive.
    static func keywordOverlap(query: String, text: String) -> Double {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return 0 }
        let textTokens = tokenize(text)
        guard !textTokens.isEmpty else { return 0 }
        let matched = queryTokens.intersection(textTokens)
        return Double(matched.count) / Double(queryTokens.count)
    }

    private static func tokenize(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        )
    }

    /// Exponential decay with its OWN half-life, deliberately separate from
    /// `MemoryEdge.staleThreshold` (90 days, a maintenance/visual-de-emphasis concern) - this
    /// is purely a ranking input, one of seven weighted factors, not a hard cutoff and not the
    /// sole driver of relevance.
    static func recencyScore(date: Date, now: Date = Date(), halfLife: TimeInterval = 60 * 60 * 24 * 30) -> Double {
        let age = max(0, now.timeIntervalSince(date))
        guard halfLife > 0 else { return age == 0 ? 1 : 0 }
        return Foundation.pow(0.5, age / halfLife)
    }
}

private extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
