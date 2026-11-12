import Foundation
import Observation
import CommaCore

/// A visible page owns one shared-core subscription. The page's scope retires on an account or Workspace change.
@MainActor @Observable final class WorkspaceTopic {
    let scope: WorkspaceSettingsScope
    let topic: String
    let parameters: [String: Any]
    let workspaceField: Bool
    private(set) var value = CoreJSON(value: nil)
    private(set) var loaded = false

    init(store: CommaStore, workspace: Workspace, topic: String, parameters: [String: Any] = [:], workspaceField: Bool = false) {
        scope = WorkspaceSettingsScope(store: store, workspace: workspace)
        self.topic = topic; self.parameters = parameters; self.workspaceField = workspaceField
    }

    func follow(onValue: ((CoreJSON) -> Void)? = nil) async {
        var query = parameters; query["topic"] = topic
        for await update in scope.store.core.subscribe(query, read: { CoreJSON(value: $0) }) {
            guard scope.current, !Task.isCancelled else { return }
            switch update {
            case .value(let next):
                if workspaceField {
                    let id = next.object?.string("workspace") ?? next.object?.object("workspace")?.string("id")
                    guard id == scope.workspace.id else {
                        if id != nil || next.object?.bool("error") == true {
                            loaded = true; scope.error = String(localized: "This page is unavailable in the selected workspace.")
                        }
                        continue
                    }
                }
                value = next; loaded = true
                onValue?(next)
                scope.error = next.object?.bool("error") == true || ["failed", "error"].contains(next.object?.string("status") ?? "") ? String(localized: "Couldn’t load this page") : nil
            case .failed(let error): loaded = true; scope.error = error.localizedDescription
            }
        }
    }
}
