import SwiftUI
import CommaCore

/// The member's workspaces. Choosing one switches to it and returns to Settings, like a navigation picker.
struct WorkspacePickerView: View {
    let store: CommaStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsPage {
            SettingsSection {
                ForEach(store.workspaces) { workspace in
                    let chosen = workspace.id == store.workspace?.id
                    Button { choose(workspace) } label: {
                        SettingsRow(Text(workspace.name)) { SettingsCheckmark(shown: chosen) }
                    }
                    .buttonStyle(SurfaceRowButtonStyle())
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        }
        .pageTitle("Workspace")
    }

    private func choose(_ workspace: Workspace) {
        if workspace.id != store.workspace?.id {
            Task { await store.chooseWorkspace(workspace) }
        }
        dismiss()
    }
}
