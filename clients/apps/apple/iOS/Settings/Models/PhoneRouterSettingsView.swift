import SwiftUI

struct PhoneRouterSettingsView: View {
    @State var model: PhoneRouterSettingsModel

    var body: some View {
        SettingsPage {
            SettingsSection(Text("Router")) {
                TextField("Name", text: $model.draftName).surfaceRowFrame()
                Button {
                    Task { _ = await model.scope.perform("models.renameAgent", ["name": model.draftName.trimmingCharacters(in: .whitespacesAndNewlines)]) }
                } label: { SettingsRow(Text("Save name"), role: .action) }
                    .buttonStyle(SurfaceRowButtonStyle())
                    .disabled(!model.loaded || model.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.draftName.count > 40 || model.draftName == model.name)
            }
            SettingsSection(Text("Replies")) {
                Picker("Reply style", selection: Binding(get: { model.style }, set: { style in
                    Task { _ = await model.scope.perform("models.setReplyStyle", ["style": style]) }
                })) {
                    Text("Default").tag("default")
                    Text("Concise").tag("concise")
                }.labelsHidden().settingsPickerRow("Reply style").disabled(!model.loaded)
            }
            SettingsSection(Text("System prompt"), footer: Text("Custom instructions apply to this workspace’s Router. They are the same instructions shown in System Files.")) {
                NavigationLink { PhoneRouterInstructionsView(model: model) } label: {
                    SettingsRow(Text("Custom instructions"), icon: "central-file-bend") { SettingsChevron() }
                }.buttonStyle(SurfaceRowButtonStyle())
            }
            if let error = model.scope.error {
                InlineError(message: error, retry: { Task { await model.refresh() } })
            }
        }
        .pageTitle("Router settings")
        .task { await model.follow() }
        .disabled(model.scope.busy || !model.scope.current)
    }
}

struct PhoneRouterInstructionsView: View {
    @Bindable var model: PhoneRouterSettingsModel
    @State private var confirmingReset = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsPage {
            if model.savedInstructions == nil {
                if model.scope.error == nil { ProgressView().frame(maxWidth: .infinity) }
            } else {
                SettingsSection(Text("Custom instructions")) {
                    TextEditor(text: $model.instructions)
                        .font(.body).foregroundStyle(CommaTheme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: editorHeight)
                        .surfaceRowFrame()
                        .accessibilityLabel("Custom instructions")
                }
                if model.instructionsChanged {
                    SettingsSection(Text("Latest saved instructions")) {
                        Text(model.savedInstructions ?? "").font(.body).textSelection(.enabled).surfaceRowFrame()
                    }
                }
                SettingsSection {
                    Button { confirmingReset = true } label: { SettingsRow(Text("Reset instructions"), role: .destructive) }
                        .buttonStyle(SurfaceRowButtonStyle())
                }
            }
            if let error = model.scope.error {
                if model.savedInstructions == nil { InlineError(message: error, retry: { Task { await model.loadInstructions() } }) }
                else { InlineError(message: error, dismiss: { model.scope.error = nil }) }
            }
        }
        .pageTitle("Custom instructions")
        .task { if model.savedInstructions == nil { await model.loadInstructions() } }
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button("Save") { Task { if await model.saveInstructions(model.instructions) { dismiss() } } }
                .disabled(model.savedInstructions == nil || model.instructions == model.savedInstructions || model.savingInstructions || !model.scope.current)
        } }
        .disabled(model.savingInstructions || !model.scope.current)
        .confirmationDialog("Reset custom instructions?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset instructions", role: .destructive) { Task { _ = await model.saveInstructions("") } }
        }
    }

    @ScaledMetric(relativeTo: .body) private var editorHeight: CGFloat = 240
}
