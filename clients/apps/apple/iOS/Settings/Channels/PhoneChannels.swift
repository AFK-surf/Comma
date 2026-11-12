import SwiftUI
import Observation
import CommaCore

enum PhoneChannel: String, CaseIterable, Identifiable {
    case telegram, wechat, signal, imessage, linear
    var id: String { rawValue }
    var title: String { switch self { case .telegram: "Telegram"; case .wechat: String(localized: "WeChat"); case .signal: "Signal"; case .imessage: "iMessage"; case .linear: "Linear" } }
}

@MainActor @Observable final class PhoneChannelModel {
    let channel: PhoneChannel
    let feed: WorkspaceTopic
    var scope: WorkspaceSettingsScope { feed.scope }
    var input = ""
    private(set) var signalCode = CoreJSON(value: nil)
    init(store: CommaStore, workspace: Workspace, channel: PhoneChannel) {
        self.channel = channel
        feed = WorkspaceTopic(store: store, workspace: workspace, topic: channel.rawValue,
                              parameters: channel == .telegram ? [:] : ["workspace": workspace.id], workspaceField: channel == .telegram)
    }
    var state: NSDictionary? { feed.value.object?.object("state") }
    var busy: Bool { scope.busy || feed.value.object?.bool("busy") == true }
    var connected: Bool {
        switch channel {
        case .telegram: state?.object("link") != nil
        case .wechat: state?.object("connection")?.bool("connection_active") == true
        case .imessage: state?.object("link") != nil && state?.bool("connection_active") == true
        case .signal: !(feed.value.object?.object("integration")?.objects("bindings").isEmpty ?? true)
        case .linear: state?.object("member") != nil
        }
    }
    func action(_ name: String, _ params: [String: Any] = [:]) async -> CoreJSON? {
        await scope.perform(channel.rawValue + "." + name, params, workspaceParameter: channel != .telegram)
    }
    func connect() async -> URL? {
        let origin = scope.store.configuration.baseURL.host ?? ""
        // These are the same deployed callback channels the service accepts; other origins use its prod default.
        let environment = origin == "salix-staging.comma.surf" ? "staging" : origin == "localhost" || origin == "127.0.0.1" ? "dev" : "prod"
        switch channel {
        case .telegram, .linear:
            let result = await action("connect", ["environment": environment])
            guard let text = result?.object?.string("authorizationUrl"), let url = URL(string: text), url.scheme == "https" else { return nil }
            return url
        case .wechat: _ = await action("start")
        case .imessage: _ = await action("start", ["handle": input])
        case .signal: signalCode = await action("newCode") ?? CoreJSON(value: nil)
        }
        return nil
    }
}

struct PhoneChannelsView: View {
    let store: CommaStore
    let workspace: Workspace
    var body: some View {
        SettingsPage {
            SettingsSection(Text("Connect a channel"), footer: Text("Messages from connected channels reach this workspace’s Router.")) {
                ForEach(PhoneChannel.allCases) { channel in
                    PhoneChannelListRow(store: store, workspace: workspace, channel: channel)
                }
            }
        }.pageTitle("Channels")
    }
}

private struct PhoneChannelListRow: View {
    let store: CommaStore
    let workspace: Workspace
    @State private var model: PhoneChannelModel
    @Environment(\.scenePhase) private var scenePhase

    init(store: CommaStore, workspace: Workspace, channel: PhoneChannel) {
        self.store = store; self.workspace = workspace
        _model = State(initialValue: PhoneChannelModel(store: store, workspace: workspace, channel: channel))
    }

    var body: some View {
        NavigationLink { PhoneChannelView(model: PhoneChannelModel(store: store, workspace: workspace, channel: model.channel)) } label: {
            SettingsRow(Text(verbatim: model.channel.title), provider: model.channel.rawValue, value: status) { SettingsChevron() }
        }.buttonStyle(SurfaceRowButtonStyle())
            .task { await model.feed.follow() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { _ = await model.action("refresh") } }
            }
    }

    private var status: Text {
        if !model.scope.current || model.scope.error != nil { return Text("Unavailable") }
        let hasState = model.channel == .signal ? model.feed.value.object?.object("integration") != nil : model.state != nil
        if !model.feed.loaded || !hasState { return Text("Loading…") }
        return Text(model.connected ? "Connected" : "Not connected")
            .foregroundColor(model.connected ? CommaTheme.successPrimary : CommaTheme.textTertiary)
    }
}

struct PhoneChannelView: View {
    @State var model: PhoneChannelModel
    @State private var disconnecting = false
    @State private var removingOrganization = false
    @State private var binding: String?
    @State private var number = ""
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        SettingsPage {
            if !model.feed.loaded { ProgressView().frame(maxWidth: .infinity) }
            SettingsSection {
                SettingsRow(Text("Status"), value: Text(model.connected ? "Connected" : "Not connected"))
                if !model.connected {
                    if model.channel == .imessage {
                        TextField("Phone number or Apple Account email", text: $model.input).textInputAutocapitalization(.never).autocorrectionDisabled().surfaceRowFrame()
                    }
                    Button { Task { if let url = await model.connect() { openURL(url) } } } label: {
                        SettingsRow(Text("Connect"), role: .action)
                    }.buttonStyle(SurfaceRowButtonStyle()).disabled(model.channel == .imessage && model.input.isEmpty)
                } else if model.channel != .signal {
                    Button("Disconnect", role: .destructive) { disconnecting = true }.surfaceRowFrame()
                }
            }
            details
            if let error = model.scope.error { InlineError(message: error, retry: { Task { _ = await model.action("refresh") } }) }
            if model.feed.value.object?.bool("error") == true, model.scope.error == nil {
                InlineError(message: String(localized: "Couldn’t read the channel status"), retry: { Task { _ = await model.action("refresh") } })
            }
        }.pageTitle(verbatim: model.channel.title).task { await model.feed.follow() }
            .refreshable { _ = await model.action("refresh") }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { _ = await model.action("refresh") } } }
            .disabled(model.busy || !model.scope.current)
            .confirmationDialog("Disconnect this channel?", isPresented: $disconnecting, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { _ = await model.action("disconnect") } }
            }
            .confirmationDialog("Remove Comma from this organization?", isPresented: $removingOrganization, titleVisibility: .visible) {
                Button("Remove organization connection", role: .destructive) { Task { _ = await model.action("disconnect", ["scope": "organization"]) } }
            } message: { Text("This removes the Linear connection for everyone in the organization.") }
            .confirmationDialog("Disconnect this Signal chat?", isPresented: Binding(get: { binding != nil }, set: { if !$0 { binding = nil } }), titleVisibility: .visible) {
                if let binding { Button("Disconnect", role: .destructive) { Task { _ = await model.action("disconnect", ["binding": binding]) }; self.binding = nil } }
            }
    }

    @ViewBuilder private var details: some View {
        switch model.channel {
        case .telegram:
            if let state = model.state {
                SettingsSection(Text("Telegram")) {
                    if let link = state.string("bot_url"), let url = URL(string: link), url.scheme == "https" { Link("Open bot", destination: url).surfaceRowFrame() }
                    if let username = state.object("link")?.string("telegram_username") { SettingsRow(Text("Account"), value: Text(verbatim: username)) }
                    if model.feed.value.object?.string("attempt") != nil { Button("Cancel connection") { Task { _ = await model.action("cancel") } }.surfaceRowFrame() }
                }
            }
        case .wechat:
            if let pending = model.state?.object("pending") {
                SettingsSection(Text("Scan with WeChat")) {
                    if let image = pending.string("qrcode_url"), let url = URL(string: image), url.scheme == "https" {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image { image.resizable().interpolation(.none).scaledToFit() }
                            else if phase.error != nil { Text("Couldn’t load the QR code") }
                            else { ProgressView() }
                        }.frame(maxWidth: GroupedSurface.rowHeight * 5).frame(maxWidth: .infinity).surfaceRowFrame()
                    }
                    if pending.string("login_status") == "need_verifycode" {
                        TextField("Verification code", text: $model.input).keyboardType(.numberPad).surfaceRowFrame()
                        Button("Verify") { Task { _ = await model.action("verify", ["code": model.input]) } }.surfaceRowFrame().disabled(model.input.isEmpty)
                    }
                    if ["expired", "verify_code_blocked"].contains(pending.string("login_status") ?? "") { Text("The connection code expired. Start a new connection.").surfaceRowFrame() }
                    Button("Cancel connection") { Task { _ = await model.action("cancel") } }.surfaceRowFrame()
                }
            }
        case .signal:
            SettingsSection(Text("Signal chats")) {
                ForEach(model.feed.value.object?.object("integration")?.objects("bindings") ?? [], id: \.self) { chat in
                    SettingsRow(Text(verbatim: chat.string("display_name") ?? chat.string("peer") ?? ""))
                    Button("Disconnect chat", role: .destructive) { binding = chat.string("binding_id") }.surfaceRowFrame()
                }
                if model.connected { Button("Connect another chat") { Task { _ = await model.connect() } }.surfaceRowFrame() }
                if let code = model.signalCode.object {
                    Text("Send this command to the Signal number:").surfaceRowFrame()
                    SettingsRow(Text(verbatim: code.string("number") ?? ""))
                    Text(verbatim: code.string("command") ?? "").font(.body.monospaced()).textSelection(.enabled).surfaceRowFrame()
                    Button("Cancel code") { if let claim = code.string("claimId") { Task { _ = await model.action("cancelCode", ["claim": claim]) } } }.surfaceRowFrame()
                }
            }
            SettingsSection(Text("Workspace Signal number"), footer: Text("Leave empty to use the platform number.")) {
                SettingsRow(Text("Current number"), value: Text(verbatim: model.feed.value.object?.object("number")?.object("effective")?.string("e164") ?? "—"))
                TextField("Phone number (+country code)", text: $number).keyboardType(.phonePad).surfaceRowFrame()
                Button("Save number") { Task { _ = await model.action("setNumber", ["number": number]) } }.surfaceRowFrame()
            }
        case .imessage:
            if let pending = model.state?.object("pending_claim") {
                SettingsSection(Text("Verify in iMessage")) {
                    Text("Send this code from the account you entered:").surfaceRowFrame()
                    Text(verbatim: pending.string("code") ?? "").font(.title2.monospaced()).textSelection(.enabled).surfaceRowFrame()
                    if let line = pending.string("line_handle") { SettingsRow(Text("Send to"), value: Text(verbatim: line)) }
                    Button("Cancel connection") { Task { _ = await model.action("cancel") } }.surfaceRowFrame()
                }
            }
            if let handle = model.state?.object("link")?.string("sender_handle") { SettingsSection { SettingsRow(Text("Account"), value: Text(verbatim: handle)) } }
        case .linear:
            if let member = model.state?.object("member") {
                SettingsSection(Text("Linear")) {
                    SettingsRow(Text("Organization"), value: Text(verbatim: model.state?.object("installation")?.string("organization_name") ?? "—"))
                    SettingsRow(Text("Account"), value: Text(verbatim: member.string("linear_user_name") ?? member.string("linear_user_email") ?? "—"))
                    Picker("When a task completes", selection: Binding(get: { member.string("completion_state_policy") ?? "unchanged" }, set: { policy in
                        Task { _ = await model.action("updateSettings", ["completion_state_policy": policy]) }
                    })) { Text("Keep issue status").tag("unchanged"); Text("In review").tag("in_review"); Text("Done").tag("done") }.surfaceRowFrame()
                }
            }
            if model.state?.object("installation")?.bool("installer") == true {
                SettingsSection {
                    Button("Remove organization connection", role: .destructive) { removingOrganization = true }.surfaceRowFrame()
                }
            }
            if model.feed.value.object?.string("attempt") != nil { SettingsSection { Button("Cancel connection") { Task { _ = await model.action("cancel") } }.surfaceRowFrame() } }
        }
    }
}
