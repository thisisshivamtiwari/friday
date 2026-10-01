import XCTest
@testable import FounderOfficeCopilotCore

/// Covers `ProjectResolution.resolve` (the shared 4-tier active-project algorithm, extracted
/// from `ExtractionCoordinator` for reuse by the read path) and `detectMentionedProjectName`.
/// Every test uses an in-memory `ProjectStore`, and confirms `resolve` never creates or
/// mutates a `ProjectSessionLink` - it must remain a pure, read-only lookup.
final class ProjectResolutionTests: XCTestCase {
    private func makeProjectManager() -> ProjectManager {
        ProjectManager(store: ProjectStore(inMemory: true))
    }

    // MARK: Tier 1 - explicit session link

    func testTier1SessionLinkWins() {
        let manager = makeProjectManager()
        let project = manager.createProject(Project(name: "Friday"))
        let otherProject = manager.createProject(Project(name: "Retvens"))
        let sessionID = UUID()
        manager.assignSession(sessionID, to: project.id)

        let resolved = ProjectResolution.resolve(
            sessionID: sessionID,
            mentionedProjectName: otherProject.name,
            probeTexts: [],
            projectManager: manager
        )
        XCTAssertEqual(resolved, project.id, "an explicit session link must win over a conflicting mentioned name")
    }

    // MARK: Tier 2 - explicit mentioned name

    func testTier2MentionedNameMatchesExistingProject() {
        let manager = makeProjectManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))

        let resolved = ProjectResolution.resolve(
            sessionID: UUID(),
            mentionedProjectName: "trustworthy ai",
            probeTexts: [],
            projectManager: manager
        )
        XCTAssertEqual(resolved, project.id, "mentioned-name matching must be case-insensitive")
    }

    func testTier2MentionedNameWithNoMatchFallsThrough() {
        let manager = makeProjectManager()
        _ = manager.createProject(Project(name: "Trustworthy AI"))

        let resolved = ProjectResolution.resolve(
            sessionID: UUID(),
            mentionedProjectName: "Some Unrelated Project",
            probeTexts: [],
            projectManager: manager
        )
        XCTAssertNil(resolved)
    }

    // MARK: Tier 3 - strong unambiguous contextual match

    func testTier3ProbeTextMatchesUniqueProjectItem() {
        let manager = makeProjectManager()
        let project = manager.createProject(Project(name: "MSc Research"))
        _ = manager.createProjectItem(ProjectItem(projectID: project.id, kind: .component, name: "XYZ Algorithm", sourceSessionID: UUID()))

        let resolved = ProjectResolution.resolve(
            sessionID: UUID(),
            mentionedProjectName: nil,
            probeTexts: ["we should revisit the XYZ Algorithm design"],
            projectManager: manager
        )
        XCTAssertEqual(resolved, project.id)
    }

    func testTier3AmbiguousMatchAcrossProjectsReturnsNil() {
        let manager = makeProjectManager()
        let projectA = manager.createProject(Project(name: "Project A"))
        let projectB = manager.createProject(Project(name: "Project B"))
        _ = manager.createProjectItem(ProjectItem(projectID: projectA.id, kind: .component, name: "Shared Component", sourceSessionID: UUID()))
        _ = manager.createProjectItem(ProjectItem(projectID: projectB.id, kind: .component, name: "Shared Component", sourceSessionID: UUID()))

        let resolved = ProjectResolution.resolve(
            sessionID: UUID(),
            mentionedProjectName: nil,
            probeTexts: ["let's talk about Shared Component"],
            projectManager: manager
        )
        XCTAssertNil(resolved, "an ambiguous match across multiple projects must never guess")
    }

    // MARK: Tier 4 - no assignment

    func testTier4NoMatchAnywhereReturnsNil() {
        let manager = makeProjectManager()
        _ = manager.createProject(Project(name: "Friday"))

        let resolved = ProjectResolution.resolve(
            sessionID: UUID(),
            mentionedProjectName: nil,
            probeTexts: ["totally unrelated conversation about lunch"],
            projectManager: manager
        )
        XCTAssertNil(resolved)
    }

    // MARK: Read-only guarantee

    func testResolveNeverCreatesASessionLink() {
        let manager = makeProjectManager()
        let project = manager.createProject(Project(name: "Friday"))
        let sessionID = UUID()

        _ = ProjectResolution.resolve(
            sessionID: sessionID,
            mentionedProjectName: project.name,
            probeTexts: [],
            projectManager: manager
        )
        XCTAssertNil(manager.project(forSession: sessionID), "resolve() must never mutate ProjectSessionLink state")
        XCTAssertTrue(manager.sessionLinks.isEmpty)
    }

    // MARK: detectMentionedProjectName

    func testDetectMentionedProjectNameFindsAKnownProject() {
        let manager = makeProjectManager()
        _ = manager.createProject(Project(name: "Retvens"))

        let detected = ProjectResolution.detectMentionedProjectName(in: "how is Retvens coming along?", projectManager: manager)
        XCTAssertEqual(detected, "Retvens")
    }

    func testDetectMentionedProjectNameSkipsNamesUnderThreeCharacters() {
        let manager = makeProjectManager()
        _ = manager.createProject(Project(name: "Q1"))

        let detected = ProjectResolution.detectMentionedProjectName(in: "what about Q1", projectManager: manager)
        XCTAssertNil(detected, "names shorter than 3 characters must be skipped to avoid trivial false positives")
    }

    func testDetectMentionedProjectNameReturnsNilWhenNothingMatches() {
        let manager = makeProjectManager()
        _ = manager.createProject(Project(name: "Friday"))

        XCTAssertNil(ProjectResolution.detectMentionedProjectName(in: "let's talk about the weather", projectManager: manager))
    }
}
