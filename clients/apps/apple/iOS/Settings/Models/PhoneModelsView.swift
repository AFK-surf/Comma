import SwiftUI

struct PhoneModelsView: View {
    @State var model: PhoneModelsModel
    @State private var adding = false

    var body: some View {
        SettingsPage {
            if let error = model.scope.error { InlineError(message: error, retry: { Task { _ = await model.scope.perform("models.refresh", workspaceParameter: false) } }) }
            if !model.loaded { ProgressView().frame(maxWidth: .infinity) }
            if model.router != nil {
                SettingsSection(Text("Default models"), footer: Text("These choices apply to new work. Existing tasks keep their own model.")) {
                    NavigationLink { PhoneModelSelectionView(model: model, task: false) } label: {
                        SettingsRow(Text("Router"), icon: "central-brain", value: Text(model.title(model.routerSelection))) { SettingsChevron() }
                    }.buttonStyle(SurfaceRowButtonStyle())
                    NavigationLink { PhoneModelSelectionView(model: model, task: true) } label: {
                        SettingsRow(Text("Tasks"), icon: "central-sparkles-two", value: Text(model.title(model.taskSelection))) { SettingsChevron() }
                    }.buttonStyle(SurfaceRowButtonStyle())
                }
            }
            SettingsSection(Text("Model accounts")) {
                ForEach(model.profiles.indices, id: \.self) { i in
                    let profile = model.profiles[i]
                    if let id = profile.string("id") {
                        NavigationLink { PhoneModelAccountView(model: model, profileID: id) } label: {
                            SettingsRow(Text(profile.string("name") ?? profile.string("email") ?? profile.string("source") ?? id),
                                        value: Text(profile.bool("disabled") ? String(localized: "Off") : String(localized: "On"))) { SettingsChevron() }
                        }.buttonStyle(SurfaceRowButtonStyle())
                    }
                }
                if model.loaded, model.profiles.isEmpty { SettingsRow(Text("No model accounts connected")) }
                if model.value.object?.bool("moreProfiles") == true {
                    Button { Task { _ = await model.scope.perform("models.moreProfiles") } } label: { SettingsRow(Text("Load more"), role: .action) }
                        .buttonStyle(SurfaceRowButtonStyle())
                }
                Button { adding = true } label: { SettingsRow(Text("Add model account"), role: .action) }
                    .buttonStyle(SurfaceRowButtonStyle()).disabled(model.presets.isEmpty)
            }
        }
        .pageTitle("Models")
        .task { await model.follow() }
        .refreshable { _ = await model.scope.perform("models.refresh", workspaceParameter: false) }
        .disabled(model.scope.busy || !model.scope.current)
        .sheet(isPresented: $adding) { NavigationStack { PhoneAddModelAccountView(model: model) }.commaSheet([.large]) }
    }
}

struct PhoneModelSelectionView: View {
    let model: PhoneModelsModel
    let task: Bool
    @State private var selection: PhoneModelSelection
    @Environment(\.dismiss) private var dismiss

    init(model: PhoneModelsModel, task: Bool) {
        self.model = model; self.task = task
        _selection = State(initialValue: task ? model.taskSelection : model.routerSelection)
    }

    private var option: PhoneModelOption? { model.models.first { $0.id == selection.model } }
    private var offered: [PhoneModelOption] { model.models.filter { !$0.serving.isEmpty } }

    var body: some View {
        SettingsPage {
            SettingsSection(Text("Model")) {
                Picker("Model", selection: Binding(get: { selection.model ?? "" }, set: { id in
                    selection.kind = id.isEmpty ? "builtin" : "catalog"
                    selection.model = id.isEmpty ? nil : id
                    selection.effort = nil; selection.profile = nil
                })) {
                    Text("Comma default").tag("")
                    ForEach(Array(Set(offered.map(\.vendor))).sorted(), id: \.self) { vendor in
                        Section(vendor) { ForEach(offered.filter { $0.vendor == vendor }) { Text($0.name).tag($0.id) } }
                    }
                    if let id = selection.model, !offered.contains(where: { $0.id == id }) {
                        Text(model.title(selection)).tag(id)
                    }
                }.labelsHidden().settingsPickerRow("Model")
                if let option, !option.efforts.isEmpty {
                    Picker("Thinking effort", selection: Binding(get: { selection.effort ?? "" }, set: { selection.effort = $0.isEmpty ? nil : $0 })) {
                        Text("Default").tag("")
                        ForEach(option.efforts, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().settingsPickerRow("Thinking effort")
                }
            }
            if selection.kind == "catalog" {
                SettingsSection(Text("Account"), footer: Text("Allow paid API accounts only if you want this model to use them when subscriptions run out.")) {
                    Picker("Account", selection: Binding(get: { selection.profile ?? "" }, set: { selection.profile = $0.isEmpty ? nil : $0 })) {
                        Text("Automatic").tag("")
                        ForEach(model.profiles.filter { option?.serving.contains($0.string("id") ?? "") == true }, id: \.self) { profile in
                            Text(profile.string("name") ?? profile.string("email") ?? profile.string("source") ?? "")
                                .tag(profile.string("id") ?? "")
                        }
                    }.labelsHidden().settingsPickerRow("Account")
                    SettingsToggle(title: Text("Allow paid API accounts"), isOn: $selection.allowPaid)
                }
                if option?.serving.isEmpty != false {
                    InlineError(message: String(localized: "No connected account can serve this model. Add or enable an account first."))
                }
            }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }
        .pageTitle(task ? "Task model" : "Router model")
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button("Save") { Task { if await model.saveSelection(selection, task: task) { dismiss() } } }
                .disabled(model.scope.busy || !model.scope.current || selection.kind == "catalog" && option?.serving.isEmpty != false)
        } }
        .disabled(model.scope.busy || !model.scope.current)
    }
}

struct PhoneModelAccountView: View {
    let model: PhoneModelsModel
    let profileID: String
    @State private var name = ""
    @State private var key = ""
    @State private var confirmingRemove = false
    @State private var reconnecting = false
    @Environment(\.dismiss) private var dismiss
    private var profile: NSDictionary? { model.profiles.first { $0.string("id") == profileID } }

    var body: some View {
        SettingsPage {
            if let profile {
                SettingsSection(Text("Account")) {
                    SettingsRow(Text("Provider"), value: Text(model.providerName(profile.string("source") ?? "")))
                    if let email = profile.string("email") { SettingsRow(Text("Email"), value: Text(email)) }
                    SettingsRow(Text("Status"), value: Text(profile.string("status") == "active" ? String(localized: "Connected") : String(localized: "Needs attention")))
                    SettingsToggle(title: Text("Enabled"), isOn: Binding(get: { !profile.bool("disabled") }, set: { enabled in
                        Task { _ = await model.scope.perform("models.updateProfile", ["profile": profileID, "disabled": !enabled]) }
                    }))
                    TextField("Name", text: $name).surfaceRowFrame()
                    Button { Task { _ = await model.scope.perform("models.updateProfile", ["profile": profileID, "name": name.trimmingCharacters(in: .whitespacesAndNewlines)]) } } label: {
                        SettingsRow(Text("Save name"), role: .action)
                    }.buttonStyle(SurfaceRowButtonStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if profile.bool("subscription") {
                    SettingsSection(Text("Usage")) {
                        ForEach(profile.objects("meters").indices, id: \.self) { i in
                            let meter = profile.objects("meters")[i]
                            let window = meter.string("window")
                            let label = window == "5h" ? String(localized: "5-hour allowance") : String(localized: "Weekly allowance")
                            // A week one model has to itself (Claude's Fable) says whose.
                            SettingsRow(Text(window == "model" ? "\(meter.string("model") ?? "") · \(label)" : label),
                                        value: Text("\(meter.int("percent") ?? 0)% remaining"))
                        }
                        Button { Task { _ = await model.scope.perform("models.refreshQuota", ["profile": profileID]) } } label: {
                            SettingsRow(Text("Refresh usage"), role: .action)
                        }.buttonStyle(SurfaceRowButtonStyle())
                        Button { reconnecting = true } label: { SettingsRow(Text("Reconnect account"), role: .action) }
                            .buttonStyle(SurfaceRowButtonStyle())
                    }
                } else {
                    SettingsSection(Text("API key")) {
                        if let hint = profile.string("key_hint") { SettingsRow(Text("Current key"), value: Text(hint)) }
                        SecureField("New API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().surfaceRowFrame()
                        Button {
                            Task { if await model.scope.perform("models.updateProfile", ["profile": profileID, "api_key": key]) != nil { key = "" } }
                        } label: { SettingsRow(Text("Replace API key"), role: .action) }
                            .buttonStyle(SurfaceRowButtonStyle()).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                SettingsSection {
                    Button { confirmingRemove = true } label: { SettingsRow(Text("Remove account"), role: .destructive) }
                        .buttonStyle(SurfaceRowButtonStyle())
                }
            }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }
        .pageTitle("Model account")
        .onAppear { name = profile?.string("name") ?? "" }
        .onDisappear { key = "" }
        .disabled(model.scope.busy || !model.scope.current)
        .sheet(isPresented: $reconnecting) {
            NavigationStack { PhoneAddModelAccountView(model: model, renewing: CoreJSON(value: profile)) }.commaSheet([.large])
        }
        .confirmationDialog("Remove model account?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove account", role: .destructive) {
                Task { if await model.scope.perform("models.deleteProfile", ["profile": profileID]) != nil { dismiss() } }
            }
        }
    }
}

struct PhoneAddModelAccountView: View {
    let model: PhoneModelsModel
    let renewing: CoreJSON?
    @State private var presetID = ""
    @State private var name = ""
    @State private var key = ""
    @State private var endpoint = ""
    @State private var wire = "responses"
    @State private var signIn: CoreJSON?
    @State private var code = ""
    @State private var waiting = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private var preset: NSDictionary? { model.presets.first { $0.string("id") == presetID } }
    private var needsEndpoint: Bool { preset?.bool("baseUrl") == true || preset?.object("discover") != nil }

    init(model: PhoneModelsModel, renewing: CoreJSON? = nil) {
        self.model = model; self.renewing = renewing
        let preset = model.presets.first { $0.string("subscriptionSource") == renewing?.object?.string("source") }
        _presetID = State(initialValue: renewing == nil ? "" : preset?.string("id") ?? "")
    }

    var body: some View {
        SettingsPage(background: CommaTheme.cardPrimary) {
            if let attempt = signIn?.object {
                SettingsSection(Text("Sign in")) {
                    if let userCode = attempt.string("user_code") {
                        SettingsRow(Text("Code"), value: Text(userCode).monospaced()).textSelection(.enabled)
                    }
                    if let url = attempt.string("url").flatMap(URL.init(string:)) {
                        Button { openURL(url) } label: { SettingsRow(Text("Continue in browser"), role: .action) }.buttonStyle(SurfaceRowButtonStyle())
                    }
                    if attempt.string("mode") != "device" {
                        TextField("Authorization code", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled().surfaceRowFrame()
                        Button {
                            Task {
                                if await model.scope.perform("models.signIn.complete", ["attempt": attempt.string("id") ?? "", "code": code]) != nil {
                                    code = ""; dismiss()
                                }
                            }
                        } label: { SettingsRow(Text("Complete sign-in"), role: .action) }
                            .buttonStyle(SurfaceRowButtonStyle()).disabled(code.isEmpty)
                    } else if waiting {
                        SettingsNote { ProgressView() } message: { Text("Waiting for authorization…") }
                    }
                    Button { signIn = nil; code = "" } label: { SettingsRow(Text("Choose another provider")) }.buttonStyle(SurfaceRowButtonStyle())
                }
            } else {
                SettingsSection(Text("Provider")) {
                    Picker("Provider", selection: $presetID) {
                        Text("Choose a provider").tag("")
                        ForEach(model.presets, id: \.self) { preset in
                            Text(model.presetName(preset)).tag(preset.string("id") ?? "")
                        }
                    }.labelsHidden().settingsPickerRow("Provider").disabled(renewing != nil)
                }
                if let preset {
                    if let source = preset.string("subscriptionSource") {
                        SettingsSection(Text("Subscription")) {
                            Button {
                                Task {
                                    var params: [String: Any] = ["provider": source]
                                    if let id = renewing?.object?.string("id"), let version = renewing?.object?.string("version") {
                                        params["account"] = id; params["version"] = version
                                    }
                                    if let answer = await model.scope.perform("models.signIn.begin", params) {
                                        signIn = answer
                                    }
                                }
                            } label: { SettingsRow(Text("Sign in with subscription"), role: .action) }.buttonStyle(SurfaceRowButtonStyle())
                        }
                    }
                    if renewing == nil, preset.string("keySource") != nil || preset.object("discover") != nil {
                        SettingsSection(Text("API account")) {
                            TextField("Name (optional)", text: $name).surfaceRowFrame()
                            SecureField("API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().surfaceRowFrame()
                            if needsEndpoint {
                                TextField("Endpoint URL", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().surfaceRowFrame()
                            }
                            if preset.object("discover") != nil {
                                Picker("Protocol", selection: $wire) {
                                    Text("Responses").tag("responses")
                                    Text("Chat Completions").tag("chat_completions")
                                    Text("Anthropic").tag("anthropic")
                                }.labelsHidden().settingsPickerRow("Protocol")
                            }
                            Button { Task { await add(preset) } } label: { SettingsRow(Text("Connect account"), role: .action) }
                                .buttonStyle(SurfaceRowButtonStyle())
                                .disabled(key.isEmpty && !preset.bool("keyOptional") || needsEndpoint && endpoint.isEmpty)
                        }
                    }
                }
            }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }
        .pageTitle("Add model account")
        .sheetCloseButton { dismiss() }
        .disabled(model.scope.busy || !model.scope.current)
        .onChange(of: presetID) { _, _ in key = ""; endpoint = "" }
        .onDisappear { key = ""; code = "" }
        .task(id: signIn?.object?.string("id")) {
            guard let attempt = signIn?.object, attempt.string("mode") == "device", let id = attempt.string("id") else { return }
            waiting = true
            defer { waiting = false }
            do {
                _ = try await model.scope.call("models.signIn.wait", ["attempt": id])
                dismiss()
            } catch is CancellationError { }
            catch { if model.scope.current { model.scope.error = error.localizedDescription } }
        }
    }

    private func add(_ preset: NSDictionary) async {
        var params: [String: Any] = ["source": preset.string("keySource") ?? preset.string("id") ?? "custom"]
        if !name.isEmpty { params["name"] = name }
        if !key.isEmpty { params["api_key"] = key }
        if needsEndpoint { params["base_url"] = endpoint }
        if let discovery = preset.object("discover") {
            params["discover"] = true; params["protocol"] = discovery.string("protocol") ?? wire
        }
        if await model.scope.perform("models.createProfile", params) != nil { key = ""; dismiss() }
    }
}
