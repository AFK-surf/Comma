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
    /// iMessage: a shared line takes the code only from a known account, so the server asked for it.
    var needsHandle = false
    /// iMessage: a code was asked for, so Messages opens once it arrives.
    var composeWhenReady = false
    /// iMessage: this page showed a code, so connecting now is worth celebrating once.
    var sawAttempt = false
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
        case .imessage:
            // A dedicated line takes the code from whoever sends it. A shared line refuses until it has the account.
            composeWhenReady = true
            let params: [String: Any] = needsHandle ? ["handle": input.trimmingCharacters(in: .whitespaces)] : [:]
            if await scope.perform("imessage.start", params, handled: { [weak self] refusal in
                guard refusal.code == "imessage_handle_required" else { return false }
                self?.needsHandle = true
                return true
            }) != nil { needsHandle = false } else { composeWhenReady = false }
        case .signal: signalCode = await action("newCode") ?? CoreJSON(value: nil)
        }
        return nil
    }

    /// The iMessage attempt under way on a Photon line: the code and the line to send it to.
    var imessageAttempt: NSDictionary? {
        guard channel == .imessage, let claim = state?.object("pending_claim"), claim.string("code") != nil,
              claim.string("line_handle") != nil else { return nil }
        return claim
    }

    /// Messages, composing to the line with the code filled in (`sms:+1…&body=…`), so one tap on Send connects.
    var imessageComposeURL: URL? {
        guard let claim = imessageAttempt, let line = claim.string("line_handle"), let code = claim.string("code"),
              let body = code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "sms:\(line)&body=\(body)")
    }

    /// Use another account: drop the attempt and ask for the account again.
    func changeIMessageAccount() async {
        input = imessageAttempt?.string("sender_handle") ?? input
        needsHandle = true
        _ = await action("cancel")
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
            if model.channel == .imessage && !model.connected && model.feed.loaded {
                IMessageOnboarding(model: model).transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(.easeOut(duration: 0.1))))
            } else if model.channel == .imessage && model.connected {
                IMessageConnected(model: model) { disconnecting = true }
                    .transition(.opacity.animation(CommaMotion.settle.delay(0.1)))
            } else {
                SettingsSection {
                    SettingsRow(Text("Status"), value: Text(model.connected ? "Connected" : "Not connected"))
                    if !model.connected {
                        Button { Task { if let url = await model.connect() { openURL(url) } } } label: {
                            SettingsRow(Text("Connect"), role: .action)
                        }.buttonStyle(SurfaceRowButtonStyle())
                    } else if model.channel != .signal {
                        Button("Disconnect", role: .destructive) { disconnecting = true }.surfaceRowFrame()
                    }
                }
            }
            details
            if let error = model.scope.error { InlineError(message: error, retry: { Task { _ = await model.action("refresh") } }) }
            if model.feed.value.object?.bool("error") == true, model.scope.error == nil {
                InlineError(message: String(localized: "Couldn’t read the channel status"), retry: { Task { _ = await model.action("refresh") } })
            }
        }
        // Connecting replaces the iMessage steps with the connected channel's status.
        .animation(model.channel == .imessage ? CommaMotion.settle : nil, value: model.connected)
        .pageTitle(verbatim: model.channel.title).task { await model.feed.follow() }
            .refreshable { _ = await model.action("refresh") }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { _ = await model.action("refresh") } } }
            .onChange(of: model.imessageAttempt != nil) { _, attempt in if attempt { model.sawAttempt = true } }
            .onChange(of: model.imessageComposeURL) { _, url in
                guard model.composeWhenReady, let url else { return }
                model.composeWhenReady = false
                openURL(url)
            }
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
            EmptyView()
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

/// Connecting iMessage, in the steps the desktop shows: Connect gets a one-time code, Messages opens with it filled
/// in for Comma's line, and Send connects. A shared line asks for the account first; a dedicated one takes the code
/// from whoever sends it.
private struct IMessageOnboarding: View {
    @Bindable var model: PhoneChannelModel
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let attempt = model.imessageAttempt
        // A code counts down by the second; before one, nothing on the page changes with time.
        TimelineView(.periodic(from: .now, by: attempt == nil ? 60 : 1)) { context in
            let remaining = attempt.map { Date(timeIntervalSince1970: $0.double("expires_at") ?? 0).timeIntervalSince(context.date) } ?? 0
            let step = attempt.map { (remaining > 0 ? "waiting-" : "expired-") + ($0.string("code") ?? "") } ?? "start"
            // Each step replaces the one before: it rises in as the old one fades, and a new code does the same.
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 24) {
                    if let attempt, remaining > 0 { waiting(attempt, remaining: remaining) }
                    else if let attempt { expired(attempt) }
                    else {
                        // The account field opens above the button when the line asks for it.
                        VStack(alignment: .leading, spacing: 24) { start }
                            .animation(CommaMotion.settle(reduced: reduceMotion), value: model.needsHandle)
                    }
                }
                .id(step)
                // The old step leaves quickly, so the two never read on top of each other.
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 16)).animation(CommaMotion.settle.delay(0.1)),
                    removal: .opacity.animation(.easeOut(duration: 0.1))))
            }
            .animation(CommaMotion.settle(reduced: reduceMotion), value: step)
        }
    }

    // MARK: Before a code

    @ViewBuilder private var start: some View {
        VStack(spacing: 14) {
            Image(decorative: "provider-imessage").resizable().scaledToFit().frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            VStack(spacing: 6) {
                Text("Chat with Comma in iMessage").font(.title3.weight(.semibold)).foregroundStyle(CommaTheme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Text Comma from Messages like any other chat. Send text and images; Comma can reply with images, videos, and files.")
                    .font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
            }
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.top, 12).padding(.horizontal, 12)

        if model.needsHandle {
            SettingsSection(Text("Your iMessage account"),
                            footer: Text("Use an email enabled in Messages, or a phone number with + and the country code.")) {
                TextField("Phone number or Apple Account email", text: $model.input).textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress).textContentType(.username).autocorrectionDisabled().submitLabel(.go)
                    .onSubmit { connect() }
                    .surfaceRowFrame()
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }

        VStack(spacing: 10) {
            Button(action: connect) {
                Text(model.needsHandle ? "Get code" : "Connect").contentTransition(.opacity)
            }
            .buttonStyle(CommaButtonStyle())
            .disabled(model.needsHandle && model.input.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Group chats are not supported.").font(.footnote).foregroundStyle(CommaTheme.textTertiary)
        }
    }

    // MARK: A code to send

    /// Messages opens with everything filled in, so the page waits on the person; the code is there for another device.
    @ViewBuilder private func waiting(_ attempt: NSDictionary, remaining: TimeInterval) -> some View {
        let sender = attempt.string("sender_handle").map(IMessageHandle.display)
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(CommaTheme.textTertiary).padding(.bottom, 2)
            VStack(spacing: 6) {
                Text("Waiting for your message").font(.title3.weight(.semibold)).foregroundStyle(CommaTheme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Group {
                    if let sender {
                        Text("Tap Send in Messages. Send it from \(sender); a message from another account does not connect.")
                    } else {
                        Text("Tap Send in Messages. The account that sends the code connects to Comma.")
                    }
                }
                .font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
            }
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.top, 20).padding(.horizontal, 12)

        VStack(spacing: 14) {
            if let url = model.imessageComposeURL {
                Button { openURL(url) } label: {
                    HStack(spacing: 8) {
                        Image(decorative: "provider-imessage").resizable().scaledToFit().frame(width: 22, height: 22)
                        Text("Open Messages")
                    }
                }
                .buttonStyle(CommaButtonStyle())
            }
            IMessageManualCode(code: attempt.string("code") ?? "", line: attempt.string("line_handle") ?? "", remaining: remaining)
        }

        HStack(spacing: 20) {
            if attempt.string("sender_handle") != nil {
                Button("Use another account") { Task { await model.changeIMessageAccount() } }
            }
            Button("Cancel") { Task { _ = await model.action("cancel") } }
        }
        .font(.subheadline).foregroundStyle(CommaTheme.textSecondary).buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func expired(_ attempt: NSDictionary) -> some View {
        EmptyState(Text("This code expired"), icon: "central-history", description: Text("Get a new code to connect."))
            .frame(minHeight: 200)
        Button("Get a new code") {
            if let sender = attempt.string("sender_handle") {
                model.input = sender
                model.needsHandle = true
            }
            connect()
        }
        .buttonStyle(CommaButtonStyle())
        if attempt.string("sender_handle") != nil {
            Button("Use another account") { Task { await model.changeIMessageAccount() } }
                .font(.subheadline).foregroundStyle(CommaTheme.textSecondary).buttonStyle(.plain)
                .frame(maxWidth: .infinity)
        }
    }

    private func connect() { Task { _ = await model.connect() } }
}

/// The code and the line in one line, for sending from another device. Either can be copied.
private struct IMessageManualCode: View {
    let code: String
    let line: String
    let remaining: TimeInterval

    var body: some View {
        VStack(spacing: 4) {
            Text("Or send \(Text(verbatim: code).font(.footnote.monospaced().weight(.semibold)).foregroundColor(CommaTheme.textSecondary)) to \(Text(verbatim: IMessageHandle.display(line)).foregroundColor(CommaTheme.textSecondary)) from another device.")
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copy code") { UIPasteboard.general.string = code }
                    Button("Copy number") { UIPasteboard.general.string = line }
                }
            Text("Expires in \(Duration.seconds(remaining.rounded(.up)).formatted(.time(pattern: .minuteSecond)))")
                .monospacedDigit()
        }
        .font(.footnote).foregroundStyle(CommaTheme.textTertiary)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

/// An iMessage handle as people read it: a North American number as `+1 (202) 555-0123`; other numbers and emails as given.
enum IMessageHandle {
    static func display(_ handle: String) -> String {
        let digits = handle.filter(\.isNumber)
        guard handle.hasPrefix("+1"), digits.count == 11, !handle.contains("@") else { return handle }
        let d = Array(digits.dropFirst())
        return "+1 (\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
    }
}

/// iMessage once connected: the success (celebrated only as it happens), the account that talks to Comma, and Disconnect.
private struct IMessageConnected: View {
    let model: PhoneChannelModel
    let disconnect: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @ScaledMetric(relativeTo: .largeTitle) private var badge: CGFloat = 72

    var body: some View {
        let sender = model.state?.object("link")?.string("sender_handle")
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(CommaTheme.successPrimary.opacity(0.12)).frame(width: badge, height: badge)
                CentralIcon("central-circle-check-fill", size: badge * 0.55, relativeTo: .largeTitle)
                    .foregroundStyle(CommaTheme.successPrimary)
                    // It grows in from half its size, invisible until then, as everything that enters by scale does.
                    .scaleEffect(shown || reduceMotion || !model.sawAttempt ? 1 : 0.5)
                    .opacity(shown || !model.sawAttempt ? 1 : 0)
            }
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("iMessage connected").font(.title3.weight(.semibold)).foregroundStyle(CommaTheme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Group {
                    if let sender {
                        Text("Messages you send from \(IMessageHandle.display(sender)) go to Comma.")
                    } else {
                        Text("Messages you send from your iMessage account go to Comma.")
                    }
                }
                .font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
            }
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.top, 12).padding(.horizontal, 12)
        .onAppear {
            // Only the moment of connecting celebrates; opening the page later shows the plain status.
            guard model.sawAttempt else { shown = true; return }
            withAnimation(reduceMotion ? CommaMotion.stateChange : .spring(response: 0.42, dampingFraction: 0.62).delay(0.15)) { shown = true }
        }

        SettingsSection {
            if let sender { SettingsRow(Text("Account"), value: Text(verbatim: IMessageHandle.display(sender))) }
            Button("Disconnect", role: .destructive, action: disconnect).surfaceRowFrame()
        }
    }
}
