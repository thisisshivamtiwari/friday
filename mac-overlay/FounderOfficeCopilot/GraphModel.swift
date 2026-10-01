import Foundation

// MARK: - Graph Model
/// The value types the Graph UI renders. Deliberately a SEPARATE PROJECTION of the persisted
/// model, not a second copy of it and not something SwiftUI derives from Core Data directly:
/// `GraphSnapshotBuilder` reads the same in-memory arrays `ProjectManager`/`MemoryManager`/
/// `ChatSessionManager` already publish, and turns them into nodes and edges. Nothing here
/// persists, mutates, or reaches a store.
///
/// EVERY value in this file is deterministic. Given the same persisted state the builder must
/// produce the same node ids, the same edge ids, the same types and the same relationship
/// semantics - no `UUID()`, no `Date()`, no dictionary-iteration order leaking into output.
/// That is what makes the whole graph testable without a UI, and it is asserted directly by
/// `GraphSnapshotBuilderTests.testSnapshotIsDeterministicAcrossRepeatedBuilds`.

// MARK: Node identity

/// What a node IS. Kept small on purpose - a node type earns its place by having real graph
/// semantics in the CURRENT model and real rows behind it, not by sounding useful.
///
/// `Meeting` is deliberately ABSENT. The type exists and carries genuine relationships
/// (`projectID`, `participantEntityIDs`, `sessionIDs`), but nothing in the app ever creates one:
/// `ProjectManager.createMeeting` has exactly one caller, its own store write, and the
/// extraction pipeline never calls it. Every populated fixture contains 0 meeting rows. Adding
/// it would define a node type that can never appear.
///
/// `ProjectEvent` is also absent as a NODE, for a different reason: 19 event rows exist in the
/// reference fixture, but an event is a timeline entry about another entity rather than a thing
/// that participates in relationships. It is surfaced in the inspector as a project's recent
/// activity, where it reads as history instead of adding a node per status change.
enum GraphNodeKind: String, CaseIterable, Hashable {
    case project
    case projectItem
    case decision
    case session
    case person

    var displayName: String {
        switch self {
        case .project: return "Project"
        case .projectItem: return "Work item"
        case .decision: return "Decision"
        case .session: return "Session"
        case .person: return "Person"
        }
    }
}

/// A node's stable identity: its kind plus the PERSISTED entity id it projects. Never a fresh
/// `UUID()`. Two builds over unchanged data produce equal ids, so selection, filters and
/// layout positions all survive a rebuild.
///
/// The kind is part of the identity because ids are only unique WITHIN a store - a
/// `ProjectItem` and a `Decision` could in principle carry the same `UUID` without any conflict
/// in Core Data, and collapsing them here would silently merge two unrelated nodes.
struct GraphNodeID: Hashable, Comparable {
    let kind: GraphNodeKind
    let entityID: UUID

    static func < (lhs: GraphNodeID, rhs: GraphNodeID) -> Bool {
        lhs.kind.rawValue == rhs.kind.rawValue
            ? lhs.entityID.uuidString < rhs.entityID.uuidString
            : lhs.kind.rawValue < rhs.kind.rawValue
    }
}

// MARK: Node

/// One rendered node. `lifecycleStatus` is the `ProjectItem.Status` raw value for work items and
/// nil for everything else - the graph shows lifecycle where lifecycle exists rather than
/// inventing a status axis for types that have none.
struct GraphNode: Identifiable, Hashable {
    let id: GraphNodeID
    let title: String
    /// Short secondary line - a work item's kind, a decision's context, a session's date. Nil
    /// when the model genuinely has nothing to put here; never filled with a placeholder.
    let subtitle: String?
    /// `ProjectItem.Status.rawValue` for work items only.
    let lifecycleStatus: String?
    /// Which project this node belongs to, for project filtering. Nil for people (a person is
    /// shared across projects) and for sessions that are not linked to any project.
    let projectID: UUID?

    var kind: GraphNodeKind { id.kind }

    /// The workspace entity this node stands for, so a graph selection can open the same
    /// inspector every other surface uses. Nil for node kinds the workspace has no screen for.
    var entityReference: EntityReference? {
        switch id.kind {
        case .project: return EntityReference(kind: .project(id.entityID))
        case .projectItem: return EntityReference(kind: .workItem(id.entityID))
        case .decision: return EntityReference(kind: .decision(id.entityID))
        case .person: return EntityReference(kind: .person(id.entityID))
        case .session: return EntityReference(kind: .conversation(id.entityID))
        }
    }
}

// MARK: Edge

/// What a relationship MEANS. Every case maps to exactly one real field or join in the
/// persisted model - there is no case here that is inferred, guessed, or derived from text
/// similarity.
enum GraphEdgeKind: String, CaseIterable, Hashable {
    /// `ProjectItem.projectID`
    case projectContainsItem
    /// `Decision.projectID`
    case projectHasDecision
    /// `ProjectSessionLink` - the single source of truth for session <-> project.
    case projectLinkedToSession
    /// `Decision.relatedItemID` - THE Phase 4.3 relationship. Drawn only when the id is
    /// non-nil AND resolves to an existing item in the SAME project; every other case becomes
    /// a `GraphIntegrityIssue` and no edge at all.
    case decisionRelatesToItem
    /// `Decision.madeBy`
    case decisionMadeByPerson
    /// `Decision.supersedes` / `supersededBy`
    case decisionSupersedesDecision
    /// `ProjectItem.relatedItemID` - e.g. a result pointing at its experiment.
    case itemRelatesToItem
    /// `ProjectItem.assignedTo`
    case itemAssignedToPerson
    /// `ProjectItem.sourceSessionID`
    case itemDiscussedInSession
    /// `Decision.sourceSessionID`
    case decisionDiscussedInSession

    var displayName: String {
        switch self {
        case .projectContainsItem: return "contains"
        case .projectHasDecision: return "has decision"
        case .projectLinkedToSession: return "linked to"
        case .decisionRelatesToItem: return "relates to"
        case .decisionMadeByPerson: return "made by"
        case .decisionSupersedesDecision: return "supersedes"
        case .itemRelatesToItem: return "related to"
        case .itemAssignedToPerson: return "assigned to"
        case .itemDiscussedInSession: return "discussed in"
        case .decisionDiscussedInSession: return "discussed in"
        }
    }

    /// Structural containment edges (a project owning its rows) versus edges that carry real
    /// analytical meaning. The view draws the former quietly and the latter prominently, so the
    /// graph doesn't read as a uniform hairball where "contains" looks as important as
    /// "this decision is about that work item".
    var isStructural: Bool {
        switch self {
        case .projectContainsItem, .projectHasDecision, .projectLinkedToSession: return true
        default: return false
        }
    }
}

/// An edge's stable identity. Because it is exactly (kind, source, destination), inserting the
/// same relationship twice is a no-op in a `Set`/dictionary - duplicate prevention is
/// structural rather than a de-dup pass that could be forgotten.
struct GraphEdgeID: Hashable {
    let kind: GraphEdgeKind
    let source: GraphNodeID
    let destination: GraphNodeID
}

struct GraphEdge: Identifiable, Hashable {
    let id: GraphEdgeID
    /// The project this edge is scoped to, used by project filtering. Nil only for edges whose
    /// endpoints span projects by nature (a person shared between projects).
    let projectID: UUID?

    var kind: GraphEdgeKind { id.kind }
    var source: GraphNodeID { id.source }
    var destination: GraphNodeID { id.destination }
}

// MARK: Integrity

/// A relationship the persisted data claims but that does not hold. These are REPORTED, never
/// silently repaired and never drawn as if valid - a graph that quietly fixes its input is a
/// graph that hides the bug. The Graph UI surfaces these in a dedicated inspector section.
struct GraphIntegrityIssue: Identifiable, Hashable {
    enum Kind: String, Hashable {
        /// `relatedItemID` points at an id no `ProjectItem` has.
        case danglingRelatedItem
        /// `relatedItemID` resolves, but the target belongs to a DIFFERENT project. Project
        /// isolation is structural everywhere else in this codebase, so this is a real
        /// violation and not a display concern.
        case crossProjectRelatedItem
        /// A row's `projectID` names a project that does not exist.
        case orphanedProjectReference
        /// `supersedes`/`supersededBy` points at a decision that does not exist.
        case danglingSupersession
    }

    let id: String
    let kind: Kind
    let subject: GraphNodeID
    let detail: String
}

// MARK: Snapshot

/// One complete, immutable projection of persisted state. Built off the main thread is safe -
/// it is a pure value with no store handles.
struct GraphSnapshot: Equatable {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
    let integrityIssues: [GraphIntegrityIssue]
    /// Project id -> display name, so the view can label filters and inspectors without
    /// re-reading the store.
    let projectNames: [UUID: String]

    static let empty = GraphSnapshot(nodes: [], edges: [], integrityIssues: [], projectNames: [:])

    var isEmpty: Bool { nodes.isEmpty }

    func node(_ id: GraphNodeID) -> GraphNode? { nodes.first { $0.id == id } }

    /// Every edge touching `id`, in either direction.
    func edges(touching id: GraphNodeID) -> [GraphEdge] {
        edges.filter { $0.source == id || $0.destination == id }
    }

    /// Degree - used by the accessible node browser, which has to convey "how connected is
    /// this" without the spatial layout a sighted user reads it from.
    func degree(of id: GraphNodeID) -> Int { edges(touching: id).count }
}
