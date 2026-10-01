import Foundation

// MARK: - Memory Entity
/// A node in Friday's memory graph - something the user has mentioned that's worth tracking
/// identity for: themselves, a person, an organization, a project, a place, a concept, or a
/// tool. Deliberately ONE type with a `kind` tag rather than separate Person/Organization/
/// Project/... types - a single flexible type is dramatically simpler to persist and query,
/// and kind-specific structured fields aren't needed at this product's scale (see the Phase 3
/// design notes for the full reasoning).
///
/// Named `MemoryEntity` rather than bare `Entity` to stay unambiguous next to Core Data's own
/// `NSEntityDescription` vocabulary in MemoryStore.swift.
struct MemoryEntity: Identifiable, Equatable {
    enum Kind: String, Equatable, CaseIterable {
        /// The user themselves - exactly one MemoryEntity with this kind is expected to
        /// exist (a singleton "self" node), rather than a separate persistent User type -
        /// see the Phase 3 design notes for why a dedicated User type isn't needed in a
        /// single-user local app.
        case `self`
        case person
        case organization
        case project
        case place
        case concept
        case tool
        case other
    }

    let id: UUID
    var kind: Kind
    var name: String
    /// Alternate names/spellings this entity has been referred to by (e.g. "UOB" for
    /// "University of Bath") - used by later phases' relevance/dedup matching, not read by
    /// anything in this foundation phase.
    var aliases: [String]
    /// Free-text, user-editable notes - never written by extraction, only by explicit user
    /// edits in a later phase's UI.
    var notes: String?
    /// Whether the user has explicitly confirmed/edited this entity, as opposed to it having
    /// only ever been auto-created by extraction.
    var isUserVerified: Bool
    let createdAt: Date
    var lastMentionedAt: Date
    var mentionCount: Int

    init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        aliases: [String] = [],
        notes: String? = nil,
        isUserVerified: Bool = false,
        createdAt: Date = Date(),
        lastMentionedAt: Date = Date(),
        mentionCount: Int = 1
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.aliases = aliases
        self.notes = notes
        self.isUserVerified = isUserVerified
        self.createdAt = createdAt
        self.lastMentionedAt = lastMentionedAt
        self.mentionCount = mentionCount
    }
}
