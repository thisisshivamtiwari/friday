# FounderOfficeCopilot — Architecture

A local-first macOS assistant that listens to meetings, turns them into structured project
knowledge, and answers questions grounded in that knowledge.

    conversation → extraction → structured state → relationships → retrieval → grounded answer

Everything is stored on this machine. The only data that leaves it is the text explicitly sent
to Gemini for transcription, extraction and response generation.

## Build and run

```bash
# Tests (offline, deterministic, no network)
cd mac-overlay/AutomatedTests
DEVELOPER_DIR="/Users/<you>/Downloads/Xcode-beta.app/Contents/Developer" swift test

# App
cd mac-overlay
DEVELOPER_DIR="…/Xcode-beta.app/Contents/Developer" \
  xcodebuild -project FounderOfficeCopilot.xcodeproj -scheme FounderOfficeCopilot -configuration Debug build
```

`DEVELOPER_DIR` is required because the system Command Line Tools do not ship the SDK/XCTest
this project needs. New Swift files must be registered in `project.pbxproj` by hand — this
project predates file-system-synchronized groups.

## Surfaces

The app is menu-bar resident (`NSApplicationDelegate`, accessory activation policy) with three
windows, each answering a different question:

| surface | question it answers | entry point |
|---|---|---|
| **Overlay** (`PrivateOverlayView`) | "help me *right now*, mid-meeting" | ⌘⇧A |
| **Workspace** (`MainWindowView`) | "what is the state of everything?" | ⌘0 |
| **Settings** | configuration | ⌘, |

All three share ONE `AIEngineController` object graph, therefore one set of stores. Constructing
a second `ProjectManager`/`ChatSessionStore` would open a second handle on the same file and show
divergent state — and `ChatSessionStore`'s write serialization is per instance, so a second
instance breaks the invariant its concurrency fix depends on.

`AppDelegate.aiEngine` is **lazy**: constructing it opens three Core Data stores, and as a stored
property that happened before `applicationDidFinishLaunching` ran. Launch paths that never touch
the assistant now never open a store.

## Domains

### Persistence (`ProjectStore`, `ChatSessionStore`, `MemoryStore`)
Three independent Core Data stacks, never one shared database. Cross-store references are plain
`UUID` fields, never Core Data relationships — this is what keeps the layers independently
deletable and testable.

`ChatSessionStore` serializes every write through ONE private background context created in
`init`. Core Data executes that context's `perform` queue FIFO, so creates precede appends and no
two writes touch the same row concurrently. This fixed real, observed data loss (three of four
meeting transcripts silently lost). Do not reintroduce per-write `performBackgroundTask`.

### Managers (`ProjectManager`, `ChatSessionManager`, `MemoryManager`)
Load everything into memory once at init, mutate synchronously, mirror to the store
fire-and-forget. There is deliberately no stored `activeProjectID` anywhere: "which project is
active" is always derived from a session's `ProjectSessionLink`, so it cannot drift.

### Extraction (`ExtractionCoordinator`, `ExtractionLLMClient`)
Debounced, batched, modality-gated LLM extraction producing `ExtractionCandidate`s that become
`MemoryEdge` / `ProjectItem` / `Decision` rows.

**Decision → ProjectItem linking** is the subtle part. The model is given the active project's
canonical item names and may also name an item it is proposing in the *same* response (a
project's first meeting has no tracked items yet — that case is the norm, not the exception).
Resolution is project-scoped exact/token-containment matching; ambiguity is terminal (never a
guess), and a name matching nothing simply yields no link. Cross-project links are structurally
impossible: `items(forProject:)` is the only candidate source.

### Context (`ContextEngine` → `ContextPacketFormatter`)
Retrieval → relevance scoring → temporal admissibility → budgeting → a `ContextPacket`, which the
formatter renders into the one text block appended to the system instruction. Two behaviours
worth knowing:

- **Grounding directive.** Driven by *evidence sufficiency* (distinctive-token coverage of the
  question), not by emptiness. This is what stops a confident answer invented from a single
  generic-word match.
- **Work-state fallback.** A question with no distinctive tokens of its own is a follow-up
  carrying its subject in the conversation; the lexical gate has nothing to match on, so deleting
  every work-state item is an artefact rather than a judgment. In that one case the top-scored
  items and decisions are admitted. A question that *does* name a subject is judged exactly as
  before — which is what preserves the negative-retrieval and cross-project safety behaviour.

### Graph (`GraphSnapshotBuilder` → `GraphFilter` → `GraphLayoutEngine` → `GraphView`)
Four pure layers under a thin view; no SwiftUI type touches Core Data. Two invariants:

1. **Never fabricate an edge.** Every edge reads a field holding the other end's id. A `Decision`
   with `relatedItemID == nil` produces no edge — nothing is inferred from text similarity.
2. **Never silently repair.** A dangling or cross-project `relatedItemID` becomes a
   `GraphIntegrityIssue` and no edge, surfaced in the inspector.

Node ids are `(kind, persisted UUID)`, never fresh UUIDs, and layout is closed-form (not
force-directed), so the same database always produces the same picture.

### Navigation currency (`EntityReference`)
Every surface reduces its objects to an `EntityReference`, which is what lets any surface hand off
to any other without knowing about it: a chat source, a graph node, a timeline entry and a search
result all become one, and `EntityInspectorSheet` renders any of them. `EntityReference(_:)` maps
from an `AnswerSource` by reading the retrieval layer's OWN typed id, so a source can only open
the entity it genuinely pointed at — there is no name matching anywhere in that path. Evidence
with no dedicated screen returns nil and is shown as non-navigable rather than opening an
approximation.

### Workspace UI (`WorkspaceModel` + feature views)
`WorkspaceModel` is a read model over the managers. It adds no persistence and no AI; it derives
the cross-cutting notions ("open work", "needs attention", "last activity", unified search) once,
so those numbers agree on every screen. All visual styling comes from `DesignSystem.swift` — no
screen defines its own spacing, radius or type scale.

## Testing

`AutomatedTests/` is a standalone SPM package whose `Sources/` are **symlinks** into the real app
sources, so tests exercise shipped code rather than a copy. Delete the folder any time; it has no
effect on the app build.

The suite is offline and deterministic: no test performs a network call, and the AI clients are
injected behind protocols (`ExtractionLLMClientProtocol`, `apiKeyProvider`) so tests use stubs and
a nil key. One test is skipped by design — it requires a Screen Recording TCC grant.

Coverage concentrates on the things that can silently corrupt state: persistence and concurrency,
extraction decoding, decision linking (ambiguity, isolation, same-batch ordering), retrieval and
admission, grounding, and graph projection including adversarial shapes (cycles, dangling links,
cross-project links, near-identical names).

## Data safety

- Three SQLite stores in `~/Library/Application Support/FounderOfficeCopilot/`.
- The Gemini API key lives in the Keychain (`com.founderoffice.copilot.secrets`), never in
  `UserDefaults` and never logged.
- Only the assembled context block and the current turn are sent to Gemini — never a database
  dump. `SensitiveContentGate` drops candidates that look like credentials before persistence.
- **Screen context is OFF by default** (`SettingsStore.screenContextEnabled`). When enabled, one
  downscaled still of the current screen is sent with each response *and is listed in that
  answer's sources*. It was previously always-on and undisclosed, which is a defect worth
  understanding rather than just fixing: it uploads whatever is visible (a validation run sent a
  screenshot containing an open `.env` with a live API key), and because the frame never enters
  the `ContextPacket` it bypasses retrieval, project isolation and the grounding directive
  entirely. On a negative-retrieval benchmark question the assistant answered in confident detail
  about a hotel-pricing codebase that merely happened to be on screen, instead of correctly
  saying it had nothing stored. Pinned by `AnswerSourceTests`.
- `ExtractionCoordinator` is fire-and-forget: extraction failures never block a response, and a
  dropped batch loses only derived insight, never the conversation itself.

## Historical research

The extraction/retrieval/linking work was validated with a synthetic evaluation harness
(SyntheticLab) and a series of controlled ablations. That infrastructure has been removed from
the product; its conclusions live in `PHASES.md` and the durable evidence in
`~/Documents/FridayPhase42Evidence/`.
