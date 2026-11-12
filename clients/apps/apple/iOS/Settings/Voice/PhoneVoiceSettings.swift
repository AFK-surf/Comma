import SwiftUI
import AVFAudio
import Observation
import CommaCore

@MainActor protocol PhoneVoicePlayback: AnyObject {
    func play(_ data: Data, finished: @escaping @MainActor (Bool) -> Void) throws
    func stop()
}

@MainActor private final class PhoneVoiceAudioPlayer: NSObject, PhoneVoicePlayback, @preconcurrency AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var finished: (@MainActor (Bool) -> Void)?
    private var sessionActive = false

    func play(_ data: Data, finished: @escaping @MainActor (Bool) -> Void) throws {
        stop()
        let player = try AVAudioPlayer(data: data)
        self.player = player; self.finished = finished
        player.delegate = self
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            sessionActive = true
            guard player.prepareToPlay(), player.play() else { throw CocoaError(.fileReadCorruptFile) }
        } catch { stop(); throw error }
    }
    func stop() {
        player?.stop(); player = nil; finished = nil
        if sessionActive {
            sessionActive = false
            let session = AVAudioSession.sharedInstance()
            // A call can take the shared session while the preview is open.
            if session.category == .playback, session.mode == .default {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if self.player === player { complete(flag) }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        if self.player === player { complete(false) }
    }
    private func complete(_ success: Bool) {
        let completion = finished; stop(); completion?(success)
    }
}

struct PhoneVoiceOption: Identifiable {
    let id: String
    let title: String
    let detail: String

    static func preset(_ name: String, locale: Locale = .current) -> Self {
        let info = presets[name]
        let detail = info.map {
            voiceText($0.female ? "settings_voice_voice_female" : "settings_voice_voice_male",
                      ["language": locale.localizedString(forIdentifier: $0.locale) ?? $0.locale])
        } ?? ""
        return Self(id: name, title: name.prefix(1).uppercased() + name.dropFirst(), detail: detail)
    }

    private static let presets: [String: (locale: String, female: Bool)] = [
        "quartz": ("en-AU", true), "ripple": ("en-AU", false), "vesper": ("en-GB", false),
        "willow": ("en-IE", true), "stone": ("en-IE", false), "gleam": ("en-US", true),
        "meridian": ("en-US", false), "bossa": ("pt-BR", true), "tempo": ("pt-BR", false),
        "beacon": ("en-PH", false), "delta": ("en-US", true), "cinder": ("en-US", false),
        "nuri": ("de", true), "juni": ("de", true), "flitz": ("de", false), "brise": ("fr", true),
        "sillage": ("fr", false), "nira": ("hi", true), "harema": ("ja", true),
        "shida": ("ja", false), "noeul": ("ko", true),
    ]
}

enum PhoneVoicePreview: Equatable { case loading(String), playing(String) }

@MainActor @Observable final class PhoneVoiceModel {
    let feed: WorkspaceTopic
    var scope: WorkspaceSettingsScope { feed.scope }
    @ObservationIgnored private let audio: any PhoneVoicePlayback
    @ObservationIgnored private var previewRequest = 0
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    private(set) var preview: PhoneVoicePreview?
    private(set) var previewError: String?
    init(store: CommaStore, workspace: Workspace, audio: (any PhoneVoicePlayback)? = nil) {
        self.audio = audio ?? PhoneVoiceAudioPlayer()
        feed = WorkspaceTopic(store: store, workspace: workspace, topic: "voice", parameters: ["prefer": workspace.id], workspaceField: true)
    }
    var integration: NSDictionary? { feed.value.object?.object("integration") }
    var selected: String {
        let voice = integration?.object("preferences")?.object("voice")
        return voice?.string("kind") == "custom" ? "custom" : voice?.string("name") ?? ""
    }
    func choice(_ value: String) -> Any {
        value.isEmpty ? NSNull() : value == "custom" ? ["kind": "custom"] : ["kind": "preset", "name": value]
    }
    var defaultVoice: PhoneVoiceOption {
        PhoneVoiceOption(id: "", title: voiceText("settings_voice_voice_default"), detail: voiceText("settings_voice_voice_default_subtitle"))
    }
    var customVoice: PhoneVoiceOption? {
        guard let custom = integration?.object("preferences")?.object("custom_voice") else { return nil }
        let name = custom.string("name") ?? ""
        return PhoneVoiceOption(id: "custom", title: name.isEmpty ? voiceText("settings_voice_voice_custom") : name,
                                detail: custom.string("description") ?? "")
    }
    var presetVoices: [PhoneVoiceOption] { (integration?.strings("voices") ?? []).map { .preset($0) } }
    var selectedTitle: String {
        ([defaultVoice] + [customVoice].compactMap { $0 } + presetVoices).first { $0.id == selected }?.title ?? selected.capitalized
    }
    func select(_ voice: String) async -> Bool {
        stop()
        return await scope.perform("voice.setPreferences", ["voice": choice(voice)]) != nil
    }
    func preview(_ voice: String) async {
        if preview == .playing(voice) || preview == .loading(voice) { stop(); return }
        stop(); previewError = nil
        guard scope.current else { return }
        let request = previewRequest
        preview = .loading(voice)
        let task = Task { await loadPreview(voice, request: request) }
        previewTask = task
        await task.value
    }
    private func loadPreview(_ voice: String, request: Int) async {
        do {
            let answer = try await scope.call("voice.preview", ["voice": choice(voice), "language": Locale.preferredLanguages.first ?? "en"])
            guard request == previewRequest, !Task.isCancelled else { return }
            guard let audio = answer.object?.string("audio"), let data = Data(base64Encoded: audio), data.count <= 10 * 1024 * 1024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            preview = .playing(voice)
            try self.audio.play(data) { [weak self] success in
                guard let self, self.previewRequest == request else { return }
                self.stop()
                if !success { self.previewError = voiceText("settings_voice_preview_failed") }
            }
        } catch {
            guard request == previewRequest else { return }
            stop()
            if !(error is CancellationError), scope.current { previewError = voiceText("settings_voice_preview_failed") }
        }
    }
    func stop() {
        previewRequest += 1; previewTask?.cancel(); previewTask = nil; audio.stop(); preview = nil
    }
    func refresh() async { _ = await scope.perform("voice.refresh", workspaceParameter: false) }
}

struct PhoneVoiceSettingsView: View {
    @State var model: PhoneVoiceModel
    @State private var keys: PhoneAPIKeysModel
    @State private var editor: VoiceEditor?
    @State private var removing: String?

    init(model: PhoneVoiceModel) {
        _model = State(initialValue: model)
        _keys = State(initialValue: PhoneAPIKeysModel(feed: model.feed, voice: true))
    }

    var body: some View {
        SettingsPage {
            if !model.feed.loaded { ProgressView().frame(maxWidth: .infinity) }
            numbers
            if let integration = model.integration { calls(integration) }
            PhoneAPIKeysView(model: keys, embedded: true)
            readiness
            if let error = model.scope.error { InlineError(message: error, retry: { Task { await model.refresh() } }) }
        }
        .pageTitle("Voice settings")
        .task { await model.feed.follow() }
        .onDisappear { model.stop(); keys.clearSecret() }
        .refreshable { await model.refresh() }
        .disabled(model.scope.busy || !model.scope.current)
        .sheet(item: $editor) { editor in
            NavigationStack {
                Group {
                    switch editor {
                    case .voices: PhoneVoicePickerView(model: model)
                    case .number(let line): PhoneVoiceVerificationView(model: model, line: line)
                    case .custom: PhoneCustomVoiceView(model: model)
                    case .pin(let number, let hasPIN): PhoneVoiceNumberView(model: model, number: number, hasPIN: hasPIN)
                    }
                }.sheetCloseButton { self.editor = nil }
            }.commaSheet([.large])
        }
        .confirmationDialog("Remove this caller number?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let number = removing {
                Button("Remove number", role: .destructive) { Task { _ = await model.scope.perform("voice.removeNumber", ["e164": number]) }; removing = nil }
            }
        }
    }

    private var numbers: some View {
        SettingsSection(Text("settings_voice_numbers")) {
            if model.feed.value.object?.bool("integrationError") == true {
                InlineError(message: String(localized: "Voice settings are unavailable."), retry: { Task { await model.refresh() } })
            } else if let integration = model.integration {
                if integration.strings("lines").isEmpty {
                    PhoneVoiceRow(title: voiceText("settings_voice_no_line"), detail: voiceText("settings_voice_no_line_description")) { EmptyView() }
                }
                ForEach(integration.strings("lines"), id: \.self) { line in
                    PhoneVoiceRow(title: voiceText("settings_voice_line", ["line": line]), detail: voiceText("settings_voice_line_description")) {
                        Button("settings_voice_add_number") { editor = .number(line) }.font(.subheadline)
                    }
                }
                ForEach(integration.objects("numbers"), id: \.self) { number in
                    if let e164 = number.string("e164") {
                        let locked = number.string("status") == "locked"
                        PhoneVoiceRow(title: e164, detail: numberDescription(number),
                                      status: voiceText(locked ? "settings_voice_status_locked" : "settings_voice_status_verified"),
                                      statusColor: locked ? CommaTheme.errorPrimary : CommaTheme.successPrimary) {
                            Menu {
                                Button(number.bool("pin_set") ? "settings_voice_change_pin" : "settings_voice_set_pin") {
                                    editor = .pin(e164, number.bool("pin_set"))
                                }
                                if number.bool("pin_set") {
                                    Button("settings_voice_clear_pin") { Task { _ = await model.scope.perform("voice.setPin", ["e164": e164, "pin": ""]) } }
                                }
                                Divider()
                                Button("Remove number", role: .destructive) { removing = e164 }
                            } label: { VoiceMoreLabel() }
                            .accessibilityLabel(Text("Actions for \(e164)"))
                        }
                    }
                }
            } else {
                SettingsRow(Text("settings_voice_loading"))
            }
        }
    }

    private func calls(_ integration: NSDictionary) -> some View {
        let custom = integration.object("preferences")?.object("custom_voice")
        let routerName = model.scope.store.router.name
        return SettingsSection(Text("settings_voice_calls")) {
            PhoneVoiceRow(title: voiceText("settings_voice_voice"), detail: voiceText("settings_voice_voice_description")) {
                Button { editor = .voices } label: {
                    HStack(spacing: GroupedSurface.groupSpacing) {
                        Text(verbatim: model.selectedTitle)
                        SettingsChevron()
                    }
                }.font(.subheadline).accessibilityLabel(Text("settings_voice_voice"))
                    .accessibilityValue(model.selectedTitle)
            }
            PhoneVoiceRow(title: voiceText("settings_voice_custom"), detail: custom?.string("description") ?? voiceText("settings_voice_custom_none")) {
                Button(custom == nil ? "settings_voice_custom_create" : "settings_voice_custom_replace") { editor = .custom }.font(.subheadline)
            }
            PhoneVoiceRow(title: voiceText("settings_voice_router_calls", ["name": routerName]),
                          detail: voiceText("settings_voice_router_calls_description", ["name": routerName])) {
                Toggle("Speak as the Router", isOn: Binding(get: { integration.object("preferences")?.bool("router_calls") == true }, set: { enabled in
                    Task { _ = await model.scope.perform("voice.setPreferences", ["routerCalls": enabled]) }
                })).labelsHidden().tint(CommaTheme.brandSolid)
            }
        }
    }

    private var readiness: some View {
        SettingsSection(Text("settings_voice_readiness")) {
            if let status = model.integration?.object("readiness") {
                let ready = status.bool("ready")
                PhoneVoiceRow(title: voiceText("settings_voice_readiness_title"), detail: readinessDescription(status),
                              status: voiceText(ready ? "settings_voice_status_ready" : "settings_voice_status_not_ready"),
                              statusColor: ready ? CommaTheme.successPrimary : CommaTheme.textTertiary) { EmptyView() }
            } else { SettingsRow(Text("settings_voice_loading")) }
        }
    }

    private func numberDescription(_ number: NSDictionary) -> String {
        var parts: [String] = []
        if let verified = number.int("verified_at") {
            parts.append(voiceText("settings_voice_number_verified", ["date": Date(timeIntervalSince1970: TimeInterval(verified) / 1000).formatted(date: .abbreviated, time: .omitted)]))
        }
        if number.string("status") == "locked", let until = number.int("pin_locked_until") {
            parts.append(voiceText("settings_voice_pin_locked", ["time": Date(timeIntervalSince1970: TimeInterval(until) / 1000).formatted(date: .omitted, time: .shortened)]))
        } else { parts.append(voiceText(number.bool("pin_set") ? "settings_voice_pin_set" : "settings_voice_pin_not_set")) }
        return parts.joined(separator: " · ")
    }

    private func readinessDescription(_ status: NSDictionary) -> String {
        if status.bool("ready") { return voiceText("settings_voice_ready") }
        switch status.string("reason") {
        case "disabled": return voiceText("settings_voice_not_ready_disabled")
        case "not_configured", "twilio_not_configured", "no_platform_lines": return voiceText("settings_voice_not_ready_not_configured")
        default: return voiceText("settings_voice_not_ready_other")
        }
    }
}

private enum VoiceEditor: Identifiable {
    case voices, number(String), custom, pin(String, Bool)
    var id: String {
        switch self { case .voices: "voices"; case .number(let line): "number-" + line; case .custom: "custom"; case .pin(let number, _): "pin-" + number }
    }
}

struct PhoneVoicePickerView: View {
    let model: PhoneVoiceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(CallController.self) private var call: CallController?

    var body: some View {
        SettingsPage {
            SettingsSection { row(model.defaultVoice) }
            if let custom = model.customVoice {
                SettingsSection(Text("settings_voice_voice_custom")) { row(custom) }
            }
            SettingsSection(Text("settings_voice_voice_presets")) {
                ForEach(model.presetVoices) { row($0) }
            }
            if let error = model.previewError { InlineError(message: error, retry: nil) }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }.pageTitle("settings_voice_voice")
            .disabled(model.scope.busy || !model.scope.current)
            .onDisappear { model.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.stop() } }
            .onChange(of: call?.busy) { _, busy in if busy == true { model.stop() } }
    }

    private func row(_ option: PhoneVoiceOption) -> some View {
        HStack(spacing: 0) {
            Button {
                Task { if await model.select(option.id) { dismiss() } }
            } label: {
                PhoneVoiceRow(title: option.title, detail: option.detail) { SettingsCheckmark(shown: model.selected == option.id) }
            }.buttonStyle(SurfaceRowButtonStyle())
                .accessibilityAddTraits(model.selected == option.id ? .isSelected : [])
            Button { Task { await model.preview(option.id) } } label: {
                Group {
                    if model.preview == .loading(option.id) { ProgressView() }
                    else { CentralIcon(model.preview == .playing(option.id) ? "central-pause" : "central-play", size: 20, relativeTo: .body) }
                }.frame(width: GroupedSurface.rowHeight, height: GroupedSurface.rowHeight)
                    .contentShape(Rectangle())
            }.buttonStyle(TactileButtonStyle()).padding(.trailing, GroupedSurface.inset)
                .disabled(call?.busy == true)
                .accessibilityLabel(Text(model.preview == .playing(option.id) ? "settings_voice_preview_stop" : model.preview == .loading(option.id) ? "settings_voice_preview_loading" : "settings_voice_preview_play") + Text(" ") + Text(verbatim: option.title))
        }
    }
}

private struct PhoneVoiceVerificationView: View {
    let model: PhoneVoiceModel
    let line: String
    @State private var number = ""
    @State private var code = ""
    @State private var sent = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsPage {
            SettingsSection(Text(verbatim: line), footer: Text("settings_voice_add_number_description")) {
                TextField("Phone number (+country code)", text: $number).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    .surfaceRowFrame().disabled(sent)
                if sent {
                    TextField("Verification code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).surfaceRowFrame()
                    Button("Verify number") { Task { if await model.scope.perform("voice.checkCode", parameters.merging(["code": code], uniquingKeysWith: { _, next in next })) != nil { dismiss() } } }
                        .surfaceRowFrame().disabled(code.isEmpty)
                    Button("Use another number") { sent = false; code = "" }.surfaceRowFrame()
                } else {
                    Button("Send verification code") { Task { sent = await model.scope.perform("voice.startVerification", parameters) != nil } }
                        .surfaceRowFrame().disabled(!number.hasPrefix("+"))
                }
            }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }.pageTitle("settings_voice_add_number_title").disabled(model.scope.busy || !model.scope.current)
    }
    private var parameters: [String: Any] { ["e164": number, "line": line] }
}

private struct PhoneCustomVoiceView: View {
    let model: PhoneVoiceModel
    @State private var name = ""
    @State private var description = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SettingsPage {
            SettingsSection(Text("Custom voice"), footer: Text("settings_voice_custom_dialog_description")) {
                TextField("Voice name (optional)", text: $name).surfaceRowFrame()
                TextField("Describe the voice", text: $description, axis: .vertical).lineLimit(3...6).surfaceRowFrame()
                Button("Create and select voice") {
                    Task { if await model.scope.perform("voice.createCustomVoice", ["description": description, "name": name]) != nil { dismiss() } }
                }.surfaceRowFrame().disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }.pageTitle("settings_voice_custom_title").disabled(model.scope.busy || !model.scope.current)
    }
}

private struct PhoneVoiceRow<Control: View>: View {
    let title: String
    var detail = ""
    var status: String? = nil
    var statusColor = CommaTheme.textTertiary
    @ViewBuilder let control: Control
    var body: some View {
        HStack(spacing: GroupedSurface.groupSpacing) {
            VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing / 2) {
                Text(verbatim: title).font(.body).foregroundStyle(CommaTheme.textPrimary)
                if !detail.isEmpty { Text(verbatim: detail).font(.footnote).foregroundStyle(CommaTheme.textTertiary) }
            }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
            if let status { Text(verbatim: status).font(.footnote).foregroundStyle(statusColor) }
            control
        }.surfaceRowFrame()
    }
}

private struct VoiceMoreLabel: View {
    var body: some View {
        CentralIcon("inbox-actions", size: 20, relativeTo: .body).foregroundStyle(CommaTheme.textSecondary)
            .frame(width: GroupedSurface.rowHeight, height: GroupedSurface.rowHeight).contentShape(Rectangle())
    }
}

private func voiceText(_ key: String, _ values: [String: String] = [:]) -> String {
    values.reduce(Bundle.main.localizedString(forKey: key, value: key, table: nil)) {
        $0.replacingOccurrences(of: "{" + $1.key + "}", with: $1.value)
    }
}

private struct PhoneVoiceNumberView: View {
    let model: PhoneVoiceModel
    let number: String
    let hasPIN: Bool
    @State private var pin = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SettingsPage {
            SettingsSection(Text(verbatim: number), footer: Text("An empty PIN removes the current PIN.")) {
                SecureField("New PIN", text: $pin).keyboardType(.numberPad).surfaceRowFrame()
                Button("Save PIN") { Task { if await model.scope.perform("voice.setPin", ["e164": number, "pin": pin]) != nil { dismiss() } } }.surfaceRowFrame()
            }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }.pageTitle("Caller PIN").disabled(model.scope.busy || !model.scope.current)
    }
}

@MainActor @Observable final class PhoneAPIKeysModel {
    let feed: WorkspaceTopic
    let voice: Bool
    var scope: WorkspaceSettingsScope { feed.scope }
    var name = ""
    var expires = false
    var expiry = Date.now.addingTimeInterval(30 * 86400)
    private(set) var created = CoreJSON(value: nil)
    init(store: CommaStore, workspace: Workspace, voice: Bool) {
        self.voice = voice
        feed = WorkspaceTopic(store: store, workspace: workspace, topic: voice ? "voice" : "routerKeys", parameters: ["prefer": workspace.id], workspaceField: true)
    }
    init(feed: WorkspaceTopic, voice: Bool) {
        self.feed = feed; self.voice = voice
    }
    var prefix: String { voice ? "voice" : "routerKeys" }
    func create() async {
        var params: [String: Any] = ["name": name]
        if voice, expires { params["expiresAt"] = Int(expiry.timeIntervalSince1970) }
        created = await scope.perform(prefix + ".create" + (voice ? "Key" : ""), params) ?? CoreJSON(value: nil)
        if created.object != nil { name = "" }
    }
    func clearSecret() { created = CoreJSON(value: nil) }
}

struct PhoneAPIKeysView: View {
    @State var model: PhoneAPIKeysModel
    var embedded = false
    @State private var creating = false
    @State private var deleting: String?
    @State private var renaming: String?
    @State private var rename = ""

    var body: some View {
        Group {
            if embedded { content }
            // The embedding page clears the secret when it closes. Here the rows are siblings, and one leaving would clear it.
            else {
                SettingsPage { content }.pageTitle(model.voice ? "Voice API keys" : "Router API keys")
                    .task { await model.feed.follow() }.onDisappear { model.clearSecret() }
            }
        }
        .disabled(model.scope.busy || !model.scope.current)
        .sheet(isPresented: $creating) {
            NavigationStack {
                SettingsPage {
                    creation
                    if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
                }.pageTitle("Create API key").sheetCloseButton { creating = false }
            }.commaSheet([.large])
        }
        .alert("Rename key", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Key name", text: $rename)
            Button("Save") { if let id = renaming { Task { _ = await model.scope.perform(model.voice ? "voice.updateKey" : "routerKeys.rename", ["key": id, "name": rename]) } }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete this API key?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let id = deleting { Button("Delete key", role: .destructive) { Task { _ = await model.scope.perform(model.voice ? "voice.deleteKey" : "routerKeys.delete", ["key": id]) }; deleting = nil } }
        }
    }

    private var content: some View {
        Group {
            if let secret = model.created.object?.string("key") {
                SettingsSection(Text("Copy this key now"), footer: Text("The full key is shown only once.")) {
                    Text(verbatim: secret).font(.footnote.monospaced()).textSelection(.enabled).surfaceRowFrame()
                    Button("Copy key") { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: secret]], options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(120)]) }.surfaceRowFrame()
                    Button("Done") { model.clearSecret() }.surfaceRowFrame()
                }
            }
            if !embedded { creation }
            SettingsSection(Text(model.voice ? "settings_voice_keys" : "API keys")) {
                if embedded {
                    PhoneVoiceRow(title: voiceText("settings_voice_keys_connect"), detail: voiceText("settings_voice_keys_description")) {
                        Button("settings_voice_new_key") { model.clearSecret(); creating = true }.font(.subheadline)
                    }
                }
                ForEach(model.feed.value.object?.objects("keys") ?? [], id: \.self) { key in
                    if let id = key.string("key_id") {
                        if model.voice {
                            let active = key.string("status") == "active"
                            PhoneVoiceRow(title: key.string("name") ?? "", detail: keyDescription(key),
                                          status: String(localized: active ? "Active" : "Disabled"),
                                          statusColor: active ? CommaTheme.successPrimary : CommaTheme.textTertiary) {
                                Menu {
                                    Button("Rename") { rename = key.string("name") ?? ""; renaming = id }
                                    Button(active ? "settings_inbound_api_disable" : "settings_inbound_api_enable") {
                                        Task { _ = await model.scope.perform("voice.updateKey", ["key": id, "status": active ? "disabled" : "active"]) }
                                    }
                                    Divider()
                                    Button("Delete key", role: .destructive) { deleting = id }
                                } label: { VoiceMoreLabel() }
                                .accessibilityLabel("settings_inbound_api_actions")
                            }
                        } else {
                            VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing) {
                                Text(verbatim: key.string("name") ?? "").font(.headline)
                                Text(verbatim: key.string("prefix") ?? "").font(.footnote.monospaced()).foregroundStyle(CommaTheme.textTertiary)
                                SettingsToggle(title: Text("Active"), isOn: Binding(get: { key.string("status") == "active" }, set: { enabled in
                                    Task { _ = await model.scope.perform("routerKeys.setStatus", ["key": id, "status": enabled ? "active" : "disabled"]) }
                                }))
                                HStack {
                                    Button("Rename") { rename = key.string("name") ?? ""; renaming = id }
                                    Spacer(); Button("Delete key", role: .destructive) { deleting = id }
                                }
                            }.surfaceRowFrame()
                        }
                    }
                }
                if embedded, model.feed.loaded, model.feed.value.object?.objects("keys").isEmpty == true,
                   model.feed.value.object?.bool("keysError") != true { SettingsRow(Text("settings_voice_keys_none")) }
            }
            if model.voice, model.feed.value.object?.bool("keysError") == true {
                InlineError(message: String(localized: "Couldn’t load API keys"), retry: { Task { _ = await model.scope.perform("voice.refresh", workspaceParameter: false) } })
            }
            if !embedded, let error = model.scope.error { InlineError(message: error, retry: { Task { _ = await model.scope.perform(model.prefix + ".refresh", workspaceParameter: false) } }) }
        }
    }

    private var creation: some View {
        SettingsSection(Text("Create API key")) {
            TextField("Key name", text: $model.name).surfaceRowFrame()
            if model.voice {
                SettingsToggle(title: Text("Set expiration"), isOn: $model.expires)
                if model.expires { DatePicker("Expires", selection: $model.expiry, in: Date.now..., displayedComponents: .date).surfaceRowFrame() }
            }
            Button("Create key") { Task { await model.create(); if model.created.object != nil { creating = false } } }
                .surfaceRowFrame().disabled(model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func keyDescription(_ key: NSDictionary) -> String {
        func date(_ seconds: Int?) -> String {
            seconds.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .omitted) } ?? "—"
        }
        let prefix = key.string("prefix") ?? ""
        return voiceText("settings_voice_key_details", ["prefix": prefix.hasSuffix("…") ? String(prefix.dropLast()) : prefix,
                                                     "created": date(key.int("created_at")), "used": date(key.int("last_used_at"))])
    }
}
