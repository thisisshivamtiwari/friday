import Foundation

// MARK: - Sensitive Content Gate
/// Hard-blocks credential/security-sensitive content from ever being persisted into Memory or
/// Project state - sits AFTER the LLM extraction call returns candidates but BEFORE
/// validation/persistence (see ExtractionCoordinator). Pure, no network, no Core Data,
/// directly unit-testable.
///
/// Deliberately NOT a simple keyword blocklist - the presence of a word like "secret" alone
/// must never block extraction on its own (rejects an earlier, overly-broad approach
/// explicitly). Blocking requires TWO independent, co-occurring signals in the SAME text:
///
/// 1. A credential-SHAPED token (structural pattern: API-key-prefixed strings, PEM private
///    key markers, SSN-shaped digits, payment-card-shaped digit runs, or short digit
///    sequences).
/// 2. A contextual CUE nearby (password/PIN/API key/SSN/credit card/... language) indicating
///    the value is being shared AS a credential.
///
/// Either signal alone does not block - "that's our team's little secret" (cue, no
/// credential-shaped value) and a bare unrelated 6-digit number (shape, no cue) both pass.
/// Ambiguous cases where both signals are present but weakly so still block - this is
/// deliberately conservative, per the approved policy.
enum SensitiveContentGate {
    /// True if the candidate's textual fields contain sensitive content - checks every string
    /// field a persisted MemoryEdge/ProjectItem/Decision could end up storing. Checks the
    /// fields BOTH individually (catches a single field like a `statement` that alone contains
    /// both signals) AND concatenated together (catches the equally realistic case where a
    /// structured candidate splits the context cue and the value across separate fields, e.g.
    /// `predicate: "password"` + `literalValue: "<the actual value>"` - neither field alone
    /// has both signals, but together they clearly do).
    static func isSensitive(_ candidate: ExtractionCandidate) -> Bool {
        let fields = [
            candidate.literalValue,
            candidate.predicate,
            candidate.name,
            candidate.itemDescription,
            candidate.statement,
            candidate.context,
            candidate.reason
        ].compactMap { $0 }

        if fields.contains(where: { isSensitive($0) }) { return true }
        return isSensitive(fields.joined(separator: " "))
    }

    static func isSensitive(_ text: String) -> Bool {
        hasCredentialShapedToken(text) && hasCredentialContextCue(text)
    }

    // MARK: Pattern signal

    private static let pemMarker = "-----begin"

    /// SSN-shaped: NNN-NN-NNNN
    private static let ssnRegex = try! NSRegularExpression(pattern: #"\b\d{3}-\d{2}-\d{4}\b"#)
    /// Payment-card-shaped: 13-19 contiguous digits (covers Visa/Mastercard/Amex/etc lengths).
    private static let cardRegex = try! NSRegularExpression(pattern: #"\b\d{13,19}\b"#)
    /// A long high-entropy token (letters/digits/-/_ , 24+ chars, no spaces) - the general
    /// shape of API keys, access tokens, JWTs, and password-manager-generated secrets.
    private static let longTokenRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z0-9_\-]{24,}\b"#)
    /// A short digit sequence - only meaningful as a "pattern" signal when a context cue is
    /// ALSO present (see isSensitive's two-signal requirement); a bare 4-8 digit number is far
    /// too common/ambiguous to treat as credential-shaped on its own.
    private static let shortDigitRegex = try! NSRegularExpression(pattern: #"\b\d{4,8}\b"#)
    /// Common API key prefixes.
    private static let knownKeyPrefixes = ["sk-", "pk-", "AKIA", "ghp_", "github_pat_", "xoxb-", "xoxp-", "xoxa-"]

    private static func hasCredentialShapedToken(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains(pemMarker) { return true }
        if knownKeyPrefixes.contains(where: { text.contains($0) }) { return true }
        let range = NSRange(text.startIndex..., in: text)
        if ssnRegex.firstMatch(in: text, range: range) != nil { return true }
        if cardRegex.firstMatch(in: text, range: range) != nil { return true }
        if longTokenRegex.firstMatch(in: text, range: range) != nil { return true }
        if shortDigitRegex.firstMatch(in: text, range: range) != nil { return true }
        return false
    }

    // MARK: Context signal

    private static let contextCues = [
        "password", "passcode", "pass code", "pin", "api key", "apikey", "api-key",
        "secret key", "private key", "ssn", "social security", "credit card", "card number",
        "cvv", "cvc", "security code", "auth token", "access token", "credential",
        "bank account", "routing number"
    ]

    private static func hasCredentialContextCue(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return contextCues.contains { lowered.contains($0) }
    }
}
