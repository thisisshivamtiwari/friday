import Foundation

// MARK: - Project Resolution
/// The shared, single implementation of the approved 4-tier active-project resolution
/// algorithm - originally written inline inside `ExtractionCoordinator.resolveActiveProject`
/// (Phase 3.3), extracted here so BOTH the write path (extraction) and the new read path
/// (retrieval) use the exact same logic rather than two copies that could silently drift.
///
/// `sessionID`/`mentionedProjectName`/`probeTexts` are generic inputs rather than being typed
/// against `ExtractionCandidate` - extraction derives them from a candidate's fields (see
/// Stage 8's refactor of ExtractionCoordinator), retrieval derives them from a user's question
/// text (see KeywordGraphRetrievalProvider) - the resolution algorithm itself doesn't need to
/// know which.
///
/// CRITICAL, unchanged from the approved design: this NEVER creates or mutates a
/// `ProjectSessionLink`. It only ever answers "which project does THIS fact/question belong
/// to" - a read-only question. `ProjectSessionLink` remains the sole source of truth for
/// session<->project association, touched only by `ProjectManager.assignSession(_:to:)` via
/// explicit user action.
enum ProjectResolution {
    /// Tier 1: explicit session -> project association (the common case once sessions are
    /// explicitly linked).
    /// Tier 2: an explicit project name mentioned, matching an existing project.
    /// Tier 3: one strong, UNAMBIGUOUS contextual match - the probe texts name something that
    /// matches an existing ProjectItem in exactly one project; matching zero or multiple
    /// projects yields nothing, never a guess.
    /// Tier 4: no assignment - returns nil, meaning conversation-only / no evidence for this
    /// specific fact or question.
    static func resolve(
        sessionID: UUID,
        mentionedProjectName: String?,
        probeTexts: [String],
        projectManager: ProjectManager
    ) -> UUID? {
        if let linked = projectManager.project(forSession: sessionID) {
            return linked
        }

        if let mentioned = mentionedProjectName?.trimmingCharacters(in: .whitespacesAndNewlines), !mentioned.isEmpty {
            if let match = projectManager.projects.first(where: { $0.name.caseInsensitiveCompare(mentioned) == .orderedSame }) {
                return match.id
            }
        }

        let probes = probeTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !probes.isEmpty {
            var matchedProjectIDs = Set<UUID>()
            for project in projectManager.projects {
                let items = projectManager.items(forProject: project.id)
                let matches = items.contains { item in
                    let itemName = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !itemName.isEmpty else { return false }
                    return probes.contains { probe in
                        let normalizedProbe = probe.lowercased()
                        return normalizedProbe.contains(itemName) || itemName.contains(normalizedProbe)
                    }
                }
                if matches { matchedProjectIDs.insert(project.id) }
            }
            if matchedProjectIDs.count == 1 {
                return matchedProjectIDs.first
            }
        }

        return nil
    }

    /// A small helper tier-2 callers (like retrieval, working from free-text questions rather
    /// than a structured candidate) can use to find an explicit project-name mention in
    /// arbitrary text - names shorter than 3 characters are skipped to avoid trivial
    /// false-positive substring matches.
    static func detectMentionedProjectName(in text: String, projectManager: ProjectManager) -> String? {
        let lowered = text.lowercased()
        return projectManager.projects.first { project in
            let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 3 else { return false }
            return lowered.contains(name.lowercased())
        }?.name
    }
}
