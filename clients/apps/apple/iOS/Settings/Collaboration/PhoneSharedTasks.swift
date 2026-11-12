import SwiftUI
import CommaCore

struct PhoneSharedTasksView: View {
    @State var feed: WorkspaceTopic
    var body: some View {
        SettingsPage {
            if !feed.loaded { ProgressView().frame(maxWidth: .infinity) }
            SettingsSection(Text("Shared tasks")) {
                ForEach(feed.value.object?.objects("shares") ?? [], id: \.self) { task in
                    if let id = task.string("id") {
                        NavigationLink { PhoneSharedTaskView(feed: WorkspaceTopic(store: feed.scope.store, workspace: feed.scope.workspace, topic: "taskShare", parameters: ["group": feed.scope.workspace.groupID, "conversation": id]), task: id, title: task.string("title") ?? String(localized: "Task")) } label: {
                            SettingsRow(Text(verbatim: task.string("title") ?? String(localized: "Task"))) { SettingsChevron() }
                        }.buttonStyle(SurfaceRowButtonStyle())
                    }
                }
                if feed.loaded, feed.value.object?.objects("shares").isEmpty == true { SettingsRow(Text("No shared tasks")) }
                if feed.value.object?.bool("hasMore") == true {
                    Button("Load more") { Task { _ = await feed.scope.perform("taskShares.more") } }.surfaceRowFrame()
                        .disabled(feed.value.object?.bool("loading") == true)
                }
            }
            if let error = feed.scope.error { InlineError(message: error, retry: { Task { _ = await feed.scope.perform("taskShares.refresh") } }) }
        }.pageTitle("Shared tasks").task { await feed.follow() }
            .refreshable { _ = await feed.scope.perform("taskShares.refresh") }
    }
}

private struct PhoneSharedTaskView: View {
    @State var feed: WorkspaceTopic
    let task: String
    let title: String
    @State private var destructive: String?
    @Environment(\.dismiss) private var dismiss
    private var params: [String: Any] { ["group": feed.scope.workspace.groupID, "conversation": task] }
    var body: some View {
        SettingsPage {
            SettingsSection { Text(verbatim: title).font(.headline).surfaceRowFrame() }
            if let share = feed.value.object?.object("share"), let link = share.string("url"), let url = URL(string: link) {
                SettingsSection(Text("Public link"), footer: Text("Anyone with the link can read the task’s shared messages.")) {
                    ShareLink(item: url) { SettingsRow(Text("Send link"), icon: "central-share-os") }.buttonStyle(SurfaceRowButtonStyle())
                    Text(verbatim: link).font(.footnote.monospaced()).textSelection(.enabled).surfaceRowFrame()
                    if share.bool("has_newer_messages") {
                        Button("Update shared messages") { Task { _ = await feed.scope.perform("taskShare.publish", params, workspaceParameter: false) } }.surfaceRowFrame()
                    }
                    Button("Replace link", role: .destructive) { destructive = "reset" }.surfaceRowFrame()
                    Button("Stop sharing", role: .destructive) { destructive = "revoke" }.surfaceRowFrame()
                }
            } else if feed.value.object?.string("status") == "loading" { ProgressView().surfaceRowFrame() }
            else if feed.value.object?.string("status") == "ready" { SettingsSection { SettingsRow(Text("This task is no longer shared.")) } }
            SettingsSection { Button("Open task") { Task { await feed.scope.store.openTask(id: task) } }.surfaceRowFrame() }
            if let error = feed.scope.error { InlineError(message: error, retry: { Task { _ = await feed.scope.perform("taskShare.refresh", params, workspaceParameter: false) } }) }
        }.pageTitle("Share task").task { await feed.follow() }
            .confirmationDialog("Invalidate the current link?", isPresented: Binding(get: { destructive != nil }, set: { if !$0 { destructive = nil } }), titleVisibility: .visible) {
                if let action = destructive {
                    Button(action == "revoke" ? "Stop sharing" : "Replace link", role: .destructive) {
                        Task {
                            let result = await feed.scope.perform("taskShare." + action, params, workspaceParameter: false)
                            if action == "revoke", result != nil { dismiss() }
                        }
                        destructive = nil
                    }
                }
            }.disabled(feed.scope.busy || !feed.scope.current)
    }
}
