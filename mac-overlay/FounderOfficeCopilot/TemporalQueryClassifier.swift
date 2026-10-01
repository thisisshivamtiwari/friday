import Foundation

// MARK: - Temporal Query Classifier
/// Classifies a QUESTION's temporal intent - "what do I currently use" vs "what did I use
/// before" vs "why did we change" vs "when did we decide this" - pure, local, no network, no
/// dependency on any manager. This is what `TemporalStatus.isAdmissible(status:intent:)`
/// consults to decide whether superseded/invalidated evidence should even be considered for a
/// given question. Deliberately heuristic/pattern-based, not a model call - classifying
/// "what is this question ASKING FOR temporally" from a handful of English patterns is cheap
/// and reliable enough not to need one, unlike the actual fact-extraction judgment calls
/// ExtractionLLMClient exists for.
enum TemporalQueryClassifier {
    enum Intent: Equatable, CaseIterable {
        /// "What do I currently use?" / "What's the current approach?"
        case current
        /// "What did I use before?" / "What did we use previously?"
        case historical
        /// "Why did we change/move away/switch/stop?"
        case changeReason
        /// "When did we decide this?" / "When was this decided?"
        case whenDecided
        /// No clear temporal signal either way - defaults to the SAME safe behavior as
        /// `.current` for admissibility purposes (see TemporalStatus.isAdmissible), so a
        /// question with no explicit temporal framing never accidentally surfaces stale,
        /// superseded, or retracted information.
        case unspecified
    }

    private static let changeReasonCues = [
        "why did we change", "why did i change", "why did we switch", "why did i switch",
        "why did we move away", "why did i move away", "why did we stop", "why did i stop",
        "why did we abandon", "why did i abandon"
    ]
    private static let whenDecidedCues = [
        "when did we decide", "when did i decide", "when was this decided", "when was that decided",
        "when did we choose", "when did we agree"
    ]
    private static let historicalCues = [
        "before", "used to", "previously", "in the past", "originally", "what did i use",
        "what did we use", "what was", "how did it use to"
    ]
    private static let currentCues = [
        "currently", "current", "right now", "at the moment", "these days", "what do i use",
        "what do we use", "what am i using", "what are we using", "now"
    ]

    /// Checked in this specific priority order - a question can contain multiple cue-like
    /// words, and the more SPECIFIC intents (why did we change / when was this decided) are
    /// checked first since they imply historical-adjacent access more precisely than a bare
    /// "current"/"before" keyword would.
    static func classify(_ text: String) -> Intent {
        let lowered = text.lowercased()
        if changeReasonCues.contains(where: { lowered.contains($0) }) { return .changeReason }
        if whenDecidedCues.contains(where: { lowered.contains($0) }) { return .whenDecided }
        if historicalCues.contains(where: { lowered.contains($0) }) { return .historical }
        if currentCues.contains(where: { lowered.contains($0) }) { return .current }
        return .unspecified
    }
}
