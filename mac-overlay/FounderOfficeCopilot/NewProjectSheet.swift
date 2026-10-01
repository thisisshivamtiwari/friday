import SwiftUI

// MARK: - New Project
/// Creating the first project is the app's BOOTSTRAP, not a convenience.
///
/// `ExtractionCoordinator` refuses to create a `ProjectItem` or `Decision` without an active
/// project, and every `ProjectResolution` tier matches against projects that already exist. With
/// zero projects the workspace therefore cannot populate itself no matter how much is said - a
/// real install reached 24 conversations with 0 projects, 0 work items and 0 decisions for
/// exactly this reason. This sheet is what breaks that cycle.
///
/// Optionally links the current conversation, because a project with nothing pointed at it is
/// still a dead end - extraction needs the session→project link to know where to file what it
/// hears.
struct NewProjectSheet: View {
    @ObservedObject var workspace: WorkspaceModel
    /// The conversation to attach, when there is one worth attaching.
    let linkableSession: ChatSession?
    let created: (Project) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var linkSession = true
    @FocusState private var nameFocused: Bool

    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("New project").font(DS.Font.title)
                Text("Projects are where your work, decisions and people are filed. Name it the way you'd refer to it out loud.")
                    .font(DS.Font.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Project name", text: $name)
                .textFieldStyle(.plain)
                .font(DS.Font.title)
                .focused($nameFocused)
                .padding(DS.Space.s)
                .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Surface.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium).stroke(DS.Surface.hairline))
                .onSubmit { create() }
                .accessibilityLabel("Project name")

            if let session = linkableSession {
                Toggle(isOn: $linkSession) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Add “\(session.title)” to this project").font(DS.Font.body)
                        Text("Lets the assistant file what it hears in this conversation.")
                            .font(DS.Font.caption).foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Create project") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 460)
        .background(DS.Surface.canvas)
        .onAppear { nameFocused = true }
    }

    private func create() {
        guard canCreate else { return }
        let sessionID = (linkSession ? linkableSession?.id : nil)
        guard let project = workspace.createProject(named: name, linking: sessionID) else { return }
        created(project)
        dismiss()
    }
}
