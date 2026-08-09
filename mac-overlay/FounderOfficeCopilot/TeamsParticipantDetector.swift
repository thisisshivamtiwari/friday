import Foundation
import AppKit
import ApplicationServices

// MARK: - Teams Participant Detector
/// Detects participants in a Microsoft Teams call via the macOS Accessibility API
///
/// For browser-based Teams: there is no permission-safe way to read a Chrome/Safari tab's
/// DOM through the Accessibility API, so this always returns an empty list for that case.
///
/// For native Teams: walks the app's accessibility tree looking for the roster/participants
/// list. Microsoft's new Teams client (Electron/React, bundle id com.microsoft.teams2) has
/// documented accessibility-tree reliability issues on macOS - broken parent/child links,
/// and elements that reportedly only refresh while Accessibility Inspector or VoiceOver is
/// running (see Apple Developer Forums thread 763286 and the Microsoft Teams developer
/// community discussion on enabling the accessibility tree on macOS). Detection here is
/// therefore best-effort: it returns whatever names it can actually find in the tree, and an
/// empty array - never fabricated placeholders - when the roster can't be located.
final class TeamsParticipantDetector {
    /// Microsoft Teams (work or school) - the current Electron/React client
    private let newTeamsBundleID = "com.microsoft.teams2"
    /// Microsoft Teams classic
    private let classicTeamsBundleID = "com.microsoft.teams"

    private var didPromptForAccessibilityPermission = false

    /// Safety limits so a malformed/huge accessibility tree can't hang the polling timer
    private let maxNodesToVisit = 4000
    private let maxTraversalDepth = 14

    /// Detects current meeting platform and participants
    /// Returns array of participant names if detected
    func detectParticipants() -> [String] {
        let runningApps = NSWorkspace.shared.runningApplications

        if let teamsApp = runningApps.first(where: {
            $0.bundleIdentifier == newTeamsBundleID || $0.bundleIdentifier == classicTeamsBundleID
        }) {
            return detectNativeTeamsParticipants(pid: teamsApp.processIdentifier)
        }

        // Browser-based Teams: no reliable way to read participant names without DOM access
        return []
    }

    /// Reads the participant roster from native Teams via the Accessibility API
    /// Requires: System Settings > Privacy & Security > Accessibility permission for this app
    private func detectNativeTeamsParticipants(pid: pid_t) -> [String] {
        guard ensureAccessibilityPermission() else { return [] }

        let appElement = AXUIElementCreateApplication(pid)
        guard let windows: [AXUIElement] = attribute(appElement, kAXWindowsAttribute) else {
            return []
        }

        var visitedCount = 0
        for window in windows {
            guard let roster = findRosterContainer(in: window, depth: 0, visitedCount: &visitedCount) else { continue }
            let names = collectNames(from: roster, depth: 0, visitedCount: &visitedCount)
            if !names.isEmpty {
                return names
            }
        }
        return []
    }

    /// Checks (and, once per launch, prompts for) Accessibility permission
    private func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        if !didPromptForAccessibilityPermission {
            didPromptForAccessibilityPermission = true
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }
        return false
    }

    /// Depth-first search for a container that looks like the participant roster, identified
    /// by its role (list/outline/table) plus a description, title, identifier, or role
    /// description that mentions "participant", "roster", or "attendee"
    private func findRosterContainer(in element: AXUIElement, depth: Int, visitedCount: inout Int) -> AXUIElement? {
        visitedCount += 1
        guard depth < maxTraversalDepth, visitedCount < maxNodesToVisit else { return nil }

        if looksLikeRosterContainer(element) {
            return element
        }

        guard let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) else { return nil }
        for child in children {
            if let found = findRosterContainer(in: child, depth: depth + 1, visitedCount: &visitedCount) {
                return found
            }
        }
        return nil
    }

    private func looksLikeRosterContainer(_ element: AXUIElement) -> Bool {
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        guard role == kAXListRole || role == kAXOutlineRole || role == kAXTableRole else { return false }

        let hints: [String] = [
            attribute(element, kAXDescriptionAttribute) as String?,
            attribute(element, kAXTitleAttribute) as String?,
            attribute(element, "AXIdentifier") as String?,
            attribute(element, kAXRoleDescriptionAttribute) as String?
        ].compactMap { $0 }
        let hintText = hints.joined(separator: " ").lowercased()

        return hintText.contains("participant") || hintText.contains("roster") || hintText.contains("attendee")
    }

    /// Collects plausible participant names (AXStaticText values) under a roster container
    private func collectNames(from element: AXUIElement, depth: Int, visitedCount: inout Int) -> [String] {
        visitedCount += 1
        guard depth < maxTraversalDepth, visitedCount < maxNodesToVisit else { return [] }

        var names: [String] = []

        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        if role == kAXStaticTextRole,
           let value: String = attribute(element, kAXValueAttribute),
           Self.isPlausibleParticipantName(value) {
            names.append(value)
        }

        if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
            for child in children {
                names.append(contentsOf: collectNames(from: child, depth: depth + 1, visitedCount: &visitedCount))
            }
        }

        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// Filters out roster-row UI chrome (button labels, status text) that isn't actually a
    /// name. Internal + static so it can be unit tested without a live accessibility tree.
    static func isPlausibleParticipantName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 60 else { return false }

        let nonNameKeywords = [
            "mute", "more options", "remove from meeting", "pin", "spotlight",
            "microphone", "camera", "raised hand", "presenting", "organizer", "(you)"
        ]
        let lowered = trimmed.lowercased()
        return !nonNameKeywords.contains { lowered.contains($0) }
    }

    /// Small typed wrapper around AXUIElementCopyAttributeValue
    private func attribute<T>(_ element: AXUIElement, _ key: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
