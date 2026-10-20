import SwiftUI
import UIKit
import CommaCore

/// The owner's controls for a Task's public link (the core's `taskShare`): create, copy or send, update to the latest
/// message, replace, and stop sharing. Anyone with the link can read the shared messages. Glyphs follow the desktop's
/// share popover (a link to create or copy, a check once copied).
struct TaskShareSheet: View {
    let store: CommaStore
    let task: TaskSummary
    @Environment(\.dismiss) private var dismiss
    @State private var share: TaskShare?
    @State private var loaded = false
    @State private var action = PageAction()
    @State private var confirmingReset = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            // Drawn with Settings' groups, as the filter sheets are, rather than the system form.
            SettingsPage(background: CommaTheme.cardPrimary) {
                SettingsSection(footer: Text("Anyone with the link can read this task’s messages up to when it was shared. They can’t send messages or see your workspace.")) {
                    Text(task.title).font(.body).foregroundStyle(CommaTheme.textPrimary).lineLimit(2).surfaceRowFrame()
                }
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 8)
                } else if let share, let url = URL(string: share.url) {
                    SettingsSection(Text("Link")) {
                        Text(share.url).font(.subheadline.monospaced()).foregroundStyle(CommaTheme.textSecondary)
                            .textSelection(.enabled).lineLimit(3).surfaceRowFrame(vertical: 12)
                        ShareLink(item: url) { SettingsRow(Text("Send link"), icon: "central-share-os") }
                            .buttonStyle(SurfaceRowButtonStyle())
                        Button {
                            UIPasteboard.general.url = url
                            copied = true
                        } label: {
                            SettingsRow(Text(copied ? "Copied" : "Copy link"), icon: copied ? "icon-check" : "central-chain-link-4")
                                .contentTransition(.opacity)
                        }
                        .buttonStyle(SurfaceRowButtonStyle())
                        .animation(CommaMotion.stateChange, value: copied)
                    }
                    SettingsSection {
                        SettingsRow(Text("Messages"), value: Text(share.messageCount.formatted()))
                        if share.artifactCount > 0 { SettingsRow(Text("Files"), value: Text(share.artifactCount.formatted())) }
                        SettingsRow(Text("Shared"), value: Text(Date(wireTimestamp: share.sharedAt).formatted(.relative(presentation: .named))))
                        if share.hasNewerMessages {
                            Button { run("taskShare.publish") } label: {
                                SettingsRow(Text("Include newer messages"), icon: "central-arrow-rotate-clockwise")
                            }
                            .buttonStyle(SurfaceRowButtonStyle())
                        }
                    } footer: {
                        if share.hasNewerMessages { Text("Messages sent after the link was shared aren’t visible to readers until you include them.") }
                    }
                    SettingsSection(footer: Text("Replacing the link stops the current link from working.")) {
                        Button { confirmingReset = true } label: {
                            SettingsRow(Text("Replace link"), icon: "central-arrow-rotate-counter-clockwise")
                        }
                        Button(role: .destructive) {
                            run("taskShare.revoke")
                        } label: {
                            SettingsRow(Text("Stop sharing"), icon: "central-circle-x", role: .destructive)
                        }
                    }
                    .buttonStyle(SurfaceRowButtonStyle())
                } else {
                    SettingsSection {
                        Button { run("taskShare.publish") } label: {
                            SettingsRow(Text("Create link"), icon: "central-chain-link-4", role: .action)
                        }
                        .buttonStyle(SurfaceRowButtonStyle())
                    }
                }
                if let error = action.error { InlineError(message: error, dismiss: { action.error = nil }) }
            }
            .disabled(action.busy)
            .pageTitle("Share task")
            .sheetCloseButton { dismiss() }
            .confirmationDialog("Replace the link?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Replace link", role: .destructive) { run("taskShare.reset") }
            } message: {
                Text("People with the current link will no longer be able to open it.")
            }
        }
        .tint(CommaTheme.brandSolid)
        // A copy lands silently on the pasteboard; one success tap confirms it.
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .task { await follow() }
        .commaSheet()
    }

    private var params: [String: Any] { ["group": task.groupID, "conversation": task.id] }

    /// Follows the Task's link while the sheet shows it; the core reads it again after each change.
    private func follow() async {
        var topic = params
        topic["topic"] = "taskShare"
        for await value in store.core.subscribe(topic, read: { CoreJSON(value: $0) }) {
            guard case .value(let next) = value, let json = next.object else { continue }
            switch json.string("status") {
            case "ready":
                share = CoreJSON(value: json.object("share")).decode(TaskShare.self)
                loaded = true
            case "failed":
                action.error = String(localized: "Comma could not load this task’s link.")
                loaded = true
            default: continue
            }
        }
    }

    private func run(_ name: String) {
        guard !action.busy else { return }
        copied = false
        let core = store.core
        let box = SendableParams(params)
        action.run { _ = try await core.call(name, box.value) }
    }
}
