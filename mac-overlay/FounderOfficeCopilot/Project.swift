import Foundation

// MARK: - Project
/// The top-level container for Friday's structured understanding of a piece of work - "MSc
/// Research", "Friday" (this app), "Retvens", etc. Doubles as the "workspace" concept from the
/// Phase 3.2 design notes: a separate Workspace type isn't needed, since real-world projects
/// the user works on are siblings, not nested under some shared umbrella.
///
/// `Project` is the ROOT everything else in this layer attaches to via a plain `projectID`
/// field (`ProjectItem`, `Decision`, `Meeting`, `ProjectEvent`, `ProjectSessionLink`) - never a
/// Core Data relationship, matching MemoryStore's established convention.
struct Project: Identifiable, Equatable {
    enum Status: String, Equatable, CaseIterable {
        case active
        /// Set only by explicit, deliberate user action (see the Phase 3.2 design notes on
        /// project completion) - never inferred from conversation silence or "all tasks done".
        case completed
        /// Soft removal from the active workflow - distinct from `.completed`: an archived
        /// project isn't necessarily finished, it's just set aside. Session links, items,
        /// decisions, meetings, and events are all left untouched when a project is archived.
        case archived
    }

    let id: UUID
    var name: String
    var status: Status
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        status: Status = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
