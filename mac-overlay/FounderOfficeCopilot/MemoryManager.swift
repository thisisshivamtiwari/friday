import Foundation
import Combine

// MARK: - Memory Manager
/// Owns Friday's memory graph (MemoryEntity nodes + MemoryEdge edges) - the persistent,
/// structured-knowledge counterpart to ChatSessionManager's conversational state. Same shape
/// as ChatSessionManager: loads everything into memory once at init, mutates in-memory
/// synchronously, mirrors to MemoryStore fire-and-forget.
///
/// Phase 3.1 (this class, as it exists right now) is foundation only: load/hold/mutate/
/// persist/read. No extraction, no relevance retrieval, no response integration, no UI -
/// those are later phases, and none of them are wired up yet. This class currently has NO
/// runtime integration with the rest of the app at all.
///
/// Deliberately has NO reference to AIEngineController, GeminiLiveClient,
/// GeminiResponseGenerator, AudioCaptureManager, AudioMixer, or SystemAudioCaptureManager -
/// same purity guarantee ChatSessionManager holds, for the same reason: nothing in this class
/// can accidentally touch audio/Gemini, by construction, not by convention.
final class MemoryManager: ObservableObject {
    @Published private(set) var entities: [MemoryEntity] = []
    @Published private(set) var edges: [MemoryEdge] = []

    private let store: MemoryStore

    /// `store` defaults to a real on-disk-backed instance; tests inject
    /// `MemoryStore(inMemory: true)` so nothing ever touches real saved memory - same seam
    /// pattern as ChatSessionManager's `store:` parameter.
    init(store: MemoryStore = MemoryStore()) {
        self.store = store
        entities = store.loadAllEntities()
        edges = store.loadAllEdges()
    }

    // MARK: Entities

    @discardableResult
    func createEntity(_ entity: MemoryEntity) -> MemoryEntity {
        entities.append(entity)
        store.createEntity(entity)
        return entity
    }

    /// No-op if `entity.id` isn't already known in-memory - mirrors MemoryStore.updateEntity's
    /// "must already exist" semantics rather than silently inserting.
    func updateEntity(_ entity: MemoryEntity) {
        guard let index = entities.firstIndex(where: { $0.id == entity.id }) else { return }
        entities[index] = entity
        store.updateEntity(entity)
    }

    func entity(id: UUID) -> MemoryEntity? {
        entities.first { $0.id == id }
    }

    /// Case-insensitive match against `name` or any `aliases` entry - the lookup later
    /// phases' extraction/dedup logic will need ("has this entity already been created?")
    /// before deciding whether to create a new MemoryEntity or reuse an existing one.
    func entity(named name: String) -> MemoryEntity? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return nil }
        return entities.first { candidate in
            candidate.name.lowercased() == target || candidate.aliases.contains { $0.lowercased() == target }
        }
    }

    // MARK: Edges

    @discardableResult
    func createEdge(_ edge: MemoryEdge) -> MemoryEdge {
        edges.append(edge)
        store.createEdge(edge)
        return edge
    }

    /// No-op if `edge.id` isn't already known in-memory - same reasoning as updateEntity.
    func updateEdge(_ edge: MemoryEdge) {
        guard let index = edges.firstIndex(where: { $0.id == edge.id }) else { return }
        edges[index] = edge
        store.updateEdge(edge)
    }

    func edge(id: UUID) -> MemoryEdge? {
        edges.first { $0.id == id }
    }

    func edges(forSubject subjectEntityID: UUID) -> [MemoryEdge] {
        edges.filter { $0.subjectEntityID == subjectEntityID }
    }

    // MARK: Forgetting / deletion

    /// Soft-forget: sets `status` to `.forgotten` through the normal update path - "forgotten"
    /// is just a status value (see MemoryEdge.Status), not a distinct store primitive. The
    /// row is NOT removed; later phases' relevance/graph code is responsible for excluding
    /// `.forgotten` edges from what they surface, not this method.
    func forgetEdge(id: UUID) {
        guard var target = edge(id: id) else { return }
        target.status = .forgotten
        updateEdge(target)
    }

    /// Permanent, irreversible removal - distinct from `forgetEdge(_:)`, which only changes
    /// status. Only this actually deletes the row, and only when explicitly called - nothing
    /// in this phase calls it automatically.
    func permanentlyDeleteEdge(id: UUID) {
        edges.removeAll { $0.id == id }
        store.deleteEdge(id: id)
    }

    func permanentlyDeleteEntity(id: UUID) {
        entities.removeAll { $0.id == id }
        store.deleteEntity(id: id)
    }

    // MARK: Staleness

    /// `.active` edges whose `lastConfirmedAt` has aged past `MemoryEdge.staleThreshold` -
    /// recomputed fresh from current in-memory state on every call, never cached, so it's
    /// always accurate as time passes with no maintenance job required. Exposed here (rather
    /// than only as a per-edge method on MemoryEdge itself) since later phases' relevance
    /// engine and graph UI both need "which of my current edges are stale right now" as a
    /// set, not just a per-edge check.
    func staleEdges(now: Date = Date()) -> [MemoryEdge] {
        edges.filter { $0.isStale(now: now) }
    }
}
