import Foundation

// MARK: - Extraction Heuristics
/// Cheap, local, synchronous pattern-matching used BEFORE anything is queued for the batched
/// LLM extraction call - pure, no network, no Core Data, directly unit-testable (matches the
/// project's established convention for pulling this kind of logic into its own testable
/// type, e.g. SessionSearch/ScrollFollowState).
///
/// This is deliberately NOT where modality classification happens - that's the extraction
/// LLM's job, since it needs real language understanding. This is purely a cheap "is this
/// turn even worth the cost of a batched extraction call" pre-filter, plus two narrow,
/// high-precision detectors (explicit memory requests, corrections) that are cheap and
/// reliable enough to do locally without waiting on a model round trip.
enum ExtractionHeuristics {
    /// Turns too short/low-content to plausibly contain anything extraction-worthy - filler,
    /// acknowledgements, single words. Filtering these out here is most of the cost savings:
    /// most turns in a real conversation ARE these.
    private static let fillerPhrases: Set<String> = [
        "yes", "yeah", "yep", "ok", "okay", "no", "nope", "hmm", "hm", "uh", "um",
        "right", "sure", "cool", "great", "thanks", "thank you", "got it", "makes sense"
    ]

    /// Whether a finalized turn is even worth queuing for batched LLM extraction - a coarse,
    /// cheap filter, not a modality classification. Most turns should fail this check; that's
    /// by design; see the Phase 3.3 design notes ("most turns should produce zero candidates").
    static func isWorthExtracting(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count >= 8 else { return false } // shorter than almost any real assertion
        if fillerPhrases.contains(trimmed.lowercased()) { return false }
        return true
    }

    /// A direct "remember that..." style request - high-precision enough to detect locally
    /// without a model call. Used to set `isExplicit = true` on whatever the LLM subsequently
    /// extracts from the SAME turn, not to extract content itself.
    static func looksLikeExplicitMemoryRequest(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let cues = ["remember that", "remember this", "don't forget that", "don't forget this", "please remember"]
        return cues.contains { lowered.contains($0) }
    }

    /// Negation-plus-reference language pointing at something Friday just said/extracted -
    /// "no, that's wrong", "that's not right", "actually, ...". Used by ExtractionCoordinator
    /// to invalidate the per-session last-extraction pointer (see its own doc comment) before
    /// running normal extraction on the same turn.
    static func looksLikeCorrection(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let cues = ["that's wrong", "that's not right", "that's incorrect", "no, that's", "actually, i", "actually i", "no that's"]
        return cues.contains { lowered.contains($0) }
    }
}
