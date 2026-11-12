import SwiftUI

struct PhoneRoutinesSettingsView: View {
    @State var model: PhoneRoutinesSettingsModel

    var body: some View {
        SettingsPage {
            if let error = model.scope.error { InlineError(message: error, retry: { Task { await model.refresh() } }) }
            if !model.loaded { ProgressView().frame(maxWidth: .infinity) }
            if model.settings.object != nil {
                SettingsSection(Text("Daily briefing"), footer: Text("The delivery time uses the time zone of the device where you change it.")) {
                    SettingsToggle(title: Text("Scheduled briefing"), isOn: Binding(get: { model.enabled }, set: { enabled in
                        Task { await model.setSchedule(enabled: enabled) }
                    }))
                    DatePicker("Delivery time", selection: Binding(get: { model.time }, set: { time in
                        Task { await model.setSchedule(time: time) }
                    }), displayedComponents: .hourAndMinute)
                        .surfaceRowFrame().disabled(!model.enabled)
                    SettingsRow(Text("Time zone"), value: Text(verbatim: model.timezone))
                }
                SettingsSection(Text("Sources"), footer: Text("Only enabled sources are included in your briefing.")) {
                    ForEach(model.sources) { source in
                        Toggle(isOn: Binding(get: { source.enabled }, set: { enabled in
                            Task { await model.setSource(source, enabled: enabled) }
                        })) {
                            HStack(spacing: 8) {
                                ProviderLogo(source: source)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.appName).foregroundStyle(CommaTheme.textPrimary)
                                    if let label = source.label { Text(label).font(.subheadline).foregroundStyle(CommaTheme.textTertiary) }
                                    if source.needsReconnect { Text("Reconnect this source in Plugins").font(.subheadline).foregroundStyle(CommaTheme.errorPrimary) }
                                }
                            }
                        }.tint(CommaTheme.brandSolid).surfaceRowFrame()
                    }
                    if model.sources.isEmpty {
                        SettingsNote(icon: "central-puzzle") { Text("Connect an app in Plugins to add a briefing source.") }
                    }
                    SettingsToggle(title: Text("Enable new sources automatically"), isOn: Binding(get: { model.autoEnable }, set: { enabled in
                        Task { await model.save(["autoEnableNewSources": enabled]) }
                    }))
                }
            }
            SettingsSection(Text("Proactive messages"), footer: Text("Comma can start a conversation when there is something useful to share.")) {
                switch model.proactive.object?.string("kind") {
                case "ready":
                    SettingsToggle(title: Text("Allow proactive messages"), isOn: Binding(get: { model.proactive.object?.bool("enabled") == true }, set: { enabled in
                        Task { await model.setProactive(enabled) }
                    }))
                case "owner-only":
                    SettingsNote(icon: "icon-info") { Text("Only the workspace owner can change proactive messages.") }
                case "failed":
                    Button { model.proactiveAttempt += 1 } label: { SettingsRow(Text("Retry proactive messages"), role: .action) }
                        .buttonStyle(SurfaceRowButtonStyle())
                default: ProgressView().surfaceRowFrame()
                }
            }
        }
        .pageTitle("Routines")
        .task { await model.follow() }
        .task(id: model.proactiveAttempt) { await model.followProactive() }
        .refreshable { await model.refresh() }
        .disabled(model.scope.busy || !model.scope.current)
    }
}
