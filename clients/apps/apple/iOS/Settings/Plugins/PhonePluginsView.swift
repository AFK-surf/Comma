import SwiftUI
import CommaCore

struct PhonePluginsView: View {
    @State var model: PhonePluginsModel
    @State private var query = ""
    @Environment(\.scenePhase) private var phase

    var body: some View {
        SettingsPage {
            if let error = model.scope.error { InlineError(message: error, retry: { Task { await model.refresh() } }) }
            if !model.loaded { ProgressView().frame(maxWidth: .infinity) }
            pluginSection("Connected", installed: true)
            pluginSection("Available plugins", installed: false)
            if model.loaded, filtered.isEmpty {
                SettingsSection { SettingsRow(Text("No plugins found")) }
            }
        }
        .pageTitle("Plugins")
        .searchable(text: $query, prompt: "Search plugins")
        .task { await model.follow() }
        .task { await model.notices() }
        .refreshable { await model.refresh() }
        .onChange(of: phase) { _, phase in
            if phase == .active { Task { await model.checkAuthorization() } }
        }
        .disabled(!model.scope.current)
    }

    private var filtered: [PhonePlugin] {
        model.plugins.filter { query.isEmpty || ($0.name + " " + $0.summary).localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder private func pluginSection(_ title: LocalizedStringKey, installed: Bool) -> some View {
        let plugins = filtered.filter { $0.installed == installed }
        if !plugins.isEmpty {
            SettingsSection(Text(title)) {
                ForEach(plugins) { plugin in
                    NavigationLink {
                        PhonePluginDetailView(model: model, pluginID: plugin.id)
                    } label: {
                        HStack(spacing: GroupedSurface.groupSpacing) {
                            PluginMark(brand: plugin.brand)
                            VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing / 2) {
                                Text(plugin.name).font(.body).foregroundStyle(CommaTheme.textPrimary)
                                Text(plugin.summary).font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if plugin.working { ProgressView() } else { SettingsChevron() }
                        }
                        .surfaceRowFrame()
                    }
                    .buttonStyle(SurfaceRowButtonStyle())
                    .accessibilityIdentifier("plugin-" + plugin.id)
                }
            }
        }
    }
}

/// A Router's request to add a plugin, answered over the conversation: the plugin's own page, which starts its install
/// once (a browser authorization, or the form the core asks for), unless the page needs a value first. It closes once
/// the plugin is installed and no form waits.
struct PhonePluginInstallSheet: View {
    let pluginID: String
    @State private var model: PhonePluginsModel
    @State private var started = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(store: CommaStore, workspace: Workspace, pluginID: String) {
        self.pluginID = pluginID
        _model = State(initialValue: PhonePluginsModel(store: store, workspace: workspace))
    }

    private var plugin: PhonePlugin? { model.plugins.first { $0.id == pluginID } }

    var body: some View {
        NavigationStack {
            PhonePluginDetailView(model: model, pluginID: pluginID)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
        }
        .task { await model.follow() }
        .task { await model.notices() }
        .task(id: model.loaded) { await start() }
        .onChange(of: plugin?.installed == true && model.configuration == nil) { _, done in
            if done && started { dismiss() }
        }
    }

    /// Starts the install once the catalog is read, as the page's Connect would, when there is nothing to fill in first.
    private func start() async {
        guard !started, model.loaded, let plugin else { return }
        started = true
        guard !plugin.installed, !plugin.locked, !plugin.working, !plugin.authorizing, !plugin.requiresCredentialInput else { return }
        if let url = await model.install(plugin) { openURL(url) }
    }
}

struct PluginMark: View {
    let brand: String
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    var body: some View {
        Group {
            if ["google", "googleworkspace"].contains(RecommendationSource.brandKey(brand) ?? "") {
                Image("GoogleSignIn").resizable().scaledToFit().padding(GroupedSurface.groupSpacing)
            } else if let image = ProviderArtwork.image(brand) {
                Image(uiImage: image).resizable().scaledToFit()
                    .padding(GroupedSurface.groupSpacing)
            } else { CentralIcon("central-puzzle", relativeTo: .title2) }
        }
        .foregroundStyle(CommaTheme.textPrimary)
        .frame(width: side, height: side)
        .background(CommaTheme.bgPrimary, in: RoundedRectangle(cornerRadius: GroupedSurface.groupSpacing))
        .accessibilityHidden(true)
    }
}

struct PhonePluginDetailView: View {
    let model: PhonePluginsModel
    let pluginID: String
    @State private var sources: PhonePluginSourcesModel
    @State private var stations: PhonePluginStationsModel
    @State private var credential = ""
    @State private var copiedConnectLine = false
    @State private var confirmingDiscardLine = false
    @State private var disconnectingStation: PhonePluginStation?
    /// The level just picked, shown until the core's value catches up (or the save fails).
    @State private var chosenLevel: StillfailNotificationLevel?
    /// Bumped by Try again to subscribe to the workspaces anew.
    @State private var stationsAttempt = 0
    @State private var confirmingRemove = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var statusDot: CGFloat = 7

    init(model: PhonePluginsModel, pluginID: String) {
        self.model = model; self.pluginID = pluginID
        _sources = State(initialValue: PhonePluginSourcesModel(scope: model.scope, plugin: pluginID))
        _stations = State(initialValue: PhonePluginStationsModel(scope: model.scope, plugin: pluginID))
    }

    private var plugin: PhonePlugin? { model.plugins.first { $0.id == pluginID } }

    var body: some View {
        SettingsPage {
            if let plugin {
                SettingsSection {
                    HStack(spacing: GroupedSurface.groupSpacing) {
                        PluginMark(brand: plugin.brand)
                        VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing / 2) {
                            Text(plugin.name).font(.headline)
                            Text(plugin.installed ? String(localized: "Connected") : String(localized: "Not connected")).font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                        }
                    }.surfaceRowFrame()
                    Text(plugin.description).font(.body).foregroundStyle(CommaTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).surfaceRowFrame()
                }
                connection(plugin)
                if plugin.installed {
                    if plugin.stations {
                        monoidStations(plugin)
                    }
                    accountSources(plugin)
                    tools(plugin)
                }
                if !plugin.skills.isEmpty {
                    SettingsSection(Text("Skills")) {
                        ForEach(plugin.skills, id: \.self) { name in SettingsRow(Text(name), icon: "central-puzzle") }
                    }
                }
                // Removing is the page's last, destructive step, on its own at the bottom.
                if plugin.installed && !plugin.locked {
                    SettingsSection {
                        Button { confirmingRemove = true } label: { SettingsRow(Text("Remove plugin"), role: .destructive) }
                            .buttonStyle(SurfaceRowButtonStyle())
                            .disabled(plugin.working || plugin.authorizing)
                    }
                }
            }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }
        .pageTitle(verbatim: plugin?.name ?? String(localized: "Plugin")) { EmptyView() }
        .disabled(model.scope.busy || !model.scope.current)
        .task { await model.follow() }
        .task { await model.notices() }
        .refreshable { await model.refresh() }
        .onChange(of: phase) { _, phase in
            if phase == .active { Task { await model.checkAuthorization() } }
        }
        .task(id: plugin?.installed) { if plugin?.installed == true { await sources.followSources() } }
        .task(id: StationsFollow(on: plugin?.installed == true && plugin?.stations == true, attempt: stationsAttempt)) {
            if plugin?.installed == true && plugin?.stations == true { await stations.follow() }
        }
        .task(id: plugin?.toolGroups == true && plugin?.installed == true) {
            if plugin?.toolGroups == true && plugin?.installed == true { await sources.followGroups() }
        }
        .alert("Confirm account", isPresented: Binding(get: { sources.confirmation != nil }, set: { _ in })) {
            Button("Cancel", role: .cancel) { Task { await sources.run("plugin.sources.cancel") } }
            Button("Confirm") { Task { await sources.run("plugin.sources.confirm") } }
        } message: { Text(sources.confirmation?.object?.string("identity") ?? "") }
        .confirmationDialog(
            disconnectingStation?.workspace.map { String(localized: "Disconnect \($0)?") } ?? String(localized: "Disconnect workspace?"),
            isPresented: Binding(get: { disconnectingStation != nil }, set: { if !$0 { disconnectingStation = nil } }),
            titleVisibility: .visible,
            presenting: disconnectingStation
        ) { station in
            Button("Disconnect", role: .destructive) { Task { await stations.disconnect(station) } }
        } message: { _ in
            Text("Comma stops reaching this workspace and deletes what its station sent. The plugin and your other workspaces stay connected.")
        }
        .confirmationDialog("Close without copying?", isPresented: $confirmingDiscardLine, titleVisibility: .visible) {
            Button("Close", role: .destructive) { closeConnectLine() }
        } message: {
            Text("This line can’t be shown again. To get a new one, connect the workspace again.")
        }
        .confirmationDialog("Remove plugin?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove plugin", role: .destructive) { Task { if let plugin { await model.remove(plugin) } } }
        } message: {
            if pluginID == PhonePlugin.colab {
                Text("Comma will stop using Google Colab in this workspace. Its running Colab VMs are stopped first. If the account needs reconnecting, reconnect the same Google account before you remove it.")
            } else {
                Text("Comma will stop using this plugin in this workspace.")
            }
        }
        .onChange(of: model.configuration?.value) { _, _ in copiedConnectLine = false }
        .onChange(of: stations.notificationLevel) { _, _ in chosenLevel = nil }
        // A copy lands silently on the pasteboard; one success tap confirms it.
        .sensoryFeedback(.success, trigger: copiedConnectLine) { _, now in now }
        .onDisappear { credential = ""; copiedConnectLine = false }
    }

    @ViewBuilder private func connection(_ plugin: PhonePlugin) -> some View {
        SettingsSection(Text("Connection")) {
            if plugin.authorizing || model.authorizationPlugin == plugin.id && model.authorizationURL != nil {
                SettingsNote(icon: "icon-globe") { Text("Finish authorizing in your browser…") }
                if let url = model.authorizationURL, model.authorizationPlugin == plugin.id {
                    Button { openURL(url) } label: { SettingsRow(Text("Continue in browser"), role: .action) }
                        .buttonStyle(SurfaceRowButtonStyle())
                }
                Button { Task { await model.cancel(plugin) } } label: { SettingsRow(Text("Cancel connection")) }
                    .buttonStyle(SurfaceRowButtonStyle())
            } else if plugin.installed && plugin.stations {
                // Its connect line and progress show under Workspaces, where another workspace is connected.
                EmptyView()
            } else if plugin.working {
                SettingsNote { ProgressView() } message: { Text("Updating connection…") }
            } else if let form = model.configuration(for: plugin), form.showsValue {
                connectLineForm(form)
            } else if let form = model.configuration(for: plugin), form.oauthCode {
                codeForm(plugin, form)
            } else if !plugin.installed || model.configurationPlugin == plugin.id {
                let form = model.configuration(for: plugin).flatMap { $0.showsValue ? nil : $0 }
                let needsInput = form != nil || plugin.requiresCredentialInput
                if needsInput {
                    let label = form?.label ?? (plugin.requiresCredentialInput ? plugin.credentialLabel : nil) ?? String(localized: "API key")
                    SecureField(label, text: $credential)
                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled().surfaceRowFrame()
                    if let url = form?.helpURL ?? plugin.helpURL { Link(destination: url) { SettingsRow(Text("Setup instructions"), role: .action) } }
                }
                if let error = model.formError { formError(error) }
                Button {
                    Task {
                        if let url = await model.install(plugin, credential: credential.isEmpty ? nil : credential) { openURL(url) }
                        credential = ""
                    }
                } label: { SettingsRow(Text("Connect plugin"), role: .action) }
                    .buttonStyle(SurfaceRowButtonStyle())
                    .disabled(plugin.locked || needsInput && credential.isEmpty)
            }
            // Connected and idle, the section says nothing the header does not: it leaves no group behind.
        }
    }

    /// A one-time connect line (`format == "show"`) to paste into a Monoid station. Closing it before a copy asks first:
    /// the line is not shown again.
    @ViewBuilder private func connectLineForm(_ form: PhonePluginConfiguration) -> some View {
        let line = form.value ?? ""
        SettingsNote(icon: "central-chain-link-4") {
            Text("Paste this line into a Monoid station: in Monoid, add a connect and choose Comma.")
        }
        Text(verbatim: line)
            .font(.subheadline.monospaced())
            .foregroundStyle(CommaTheme.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .surfaceRowFrame(vertical: 12)
            .accessibilityLabel(Text(form.label ?? String(localized: "Connect line")))
            .accessibilityValue(Text(verbatim: line))
        Button {
            // A credential: it leaves the pasteboard after two minutes, but may still reach a Mac by Universal Clipboard.
            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: line]], options: [.expirationDate: Date.now.addingTimeInterval(120)])
            copiedConnectLine = true
        } label: {
            SettingsRow(Text(copiedConnectLine ? "Copied" : "Copy line"),
                        icon: copiedConnectLine ? "icon-check" : "central-square-behind-square-6", role: .action)
                .contentTransition(.opacity)
        }
        .buttonStyle(SurfaceRowButtonStyle())
        .animation(CommaMotion.stateChange, value: copiedConnectLine)
        .disabled(line.isEmpty)
        .accessibilityIdentifier("monoid-connect-line-copy")
        ShareLink(item: line) { SettingsRow(Text("Send line"), icon: "central-share-os", role: .action) }
            .buttonStyle(SurfaceRowButtonStyle())
            .disabled(line.isEmpty)
        Button {
            if copiedConnectLine { closeConnectLine() } else { confirmingDiscardLine = true }
        } label: { SettingsRow(Text("Done")) }
            .buttonStyle(SurfaceRowButtonStyle())
            .accessibilityIdentifier("monoid-connect-line-done")
    }

    private func closeConnectLine() {
        model.dismissConfiguration()
        copiedConnectLine = false
    }

    @ViewBuilder private func monoidStations(_ plugin: PhonePlugin) -> some View {
        let line = model.configuration(for: plugin).flatMap { $0.showsValue ? $0 : nil }
        SettingsSection(Text("Workspaces")) {
            if let line {
                connectLineForm(line)
            } else {
                workspacesContent(plugin)
            }
        } footer: {
            if line != nil {
                Text("This line is shown only once. To connect another workspace, get a new line.")
            } else if stations.hasOfflineConnectedStation {
                Text("Some workspaces are offline. Task sync and Home card replies resume when they reconnect.")
            }
        }

        SettingsSection(Text("Notifications")) {
            ForEach(StillfailNotificationLevel.allCases) { level in
                let chosen = (chosenLevel ?? stations.notificationLevel) == level
                Button { choose(level) } label: {
                    StationLevelRow(title: notificationLevelTitle(level), detail: notificationLevelDescription(level)) {
                        SettingsCheckmark(shown: chosen)
                    }
                }
                .buttonStyle(SurfaceRowButtonStyle())
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityIdentifier("monoid-notification-level-" + level.rawValue)
            }
            .disabled(stations.notificationPending)
            if stations.error == "notification_save_failed" || stations.notificationError != nil {
                formError(stations.notificationError ?? String(localized: "Couldn’t save notification level. Try again."))
            }
        }
    }

    private func choose(_ level: StillfailNotificationLevel) {
        guard level != (chosenLevel ?? stations.notificationLevel) else { return }
        chosenLevel = level
        Task { if !(await stations.setNotificationLevel(level)) { chosenLevel = nil } }
    }

    @ViewBuilder private func workspacesContent(_ plugin: PhonePlugin) -> some View {
        if stations.error == "load_failed" && stations.stations == nil {
            SettingsNote(icon: "central-exclamation-triangle") {
                Text("Couldn’t read the connected Monoid workspaces.")
            }
            Button { stationsAttempt += 1 } label: { SettingsRow(Text("Try Again"), role: .action) }
                .buttonStyle(SurfaceRowButtonStyle())
        } else if let list = stations.stations {
            if list.isEmpty {
                SettingsNote(icon: "central-chain-link-4") {
                    Text("No workspaces are connected yet. Connect one to get a line to paste into its Monoid station.")
                }
            } else {
                ForEach(list) { station in
                    stationRow(station)
                }
            }
        } else {
            SettingsNote { ProgressView() } message: { Text("Loading…") }
        }
        if stations.error == "disconnect_failed" {
            formError(String(localized: "Couldn’t disconnect workspace. Try again."))
        } else if let actionError = stations.actionError {
            formError(actionError)
        }
        Button {
            Task { _ = await model.install(plugin) }
        } label: {
            SettingsRow(Text(stations.stations?.isEmpty == false ? "Connect another workspace" : "Connect a workspace"),
                        icon: "central-plus-small", role: .action) {
                if plugin.working { ProgressView() }
            }
        }
        .buttonStyle(SurfaceRowButtonStyle())
        .disabled(plugin.locked || plugin.working)
        .accessibilityIdentifier("monoid-connect-another-workspace")
    }

    private func stationRow(_ station: PhonePluginStation) -> some View {
        HStack(spacing: GroupedSurface.groupSpacing) {
            StationWorkspaceBadge(name: station.workspace, emoji: station.emoji)
            VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing / 2) {
                Text(station.displayName)
                    .font(.body)
                    .foregroundStyle(CommaTheme.textPrimary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                stationDetail(station)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if stations.pending == station.id {
                ProgressView()
                    .frame(width: 44, height: 44)
                    .padding(.trailing, -12)
                    .accessibilityLabel(Text("Disconnecting \(station.displayName)"))
            } else {
                Menu {
                    disconnectButton(station)
                } label: {
                    CentralIcon("inbox-actions", size: 20).foregroundStyle(CommaTheme.textSecondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .padding(.trailing, -12)
                .disabled(stations.pending != nil)
                .accessibilityLabel(Text("Actions for \(station.displayName)"))
                .accessibilityIdentifier("monoid-disconnect-" + station.id)
            }
        }
        .surfaceRowFrame()
        .contextMenu { if stations.pending == nil { disconnectButton(station) } }
    }

    private func disconnectButton(_ station: PhonePluginStation) -> some View {
        Button(role: .destructive) { disconnectingStation = station } label: {
            Label { Text("Disconnect") } icon: { MenuIcon.destructive("central-chain-link-4") }
        }
    }

    /// Where Comma reaches the workspace and whether it is online, in words as well as by the dot.
    @ViewBuilder private func stationDetail(_ station: PhonePluginStation) -> some View {
        if station.connectedAt == nil {
            Text("Waiting for its line to be pasted")
                .font(.footnote)
                .foregroundStyle(CommaTheme.textTertiary)
        } else {
            let via = station.station.map { String(localized: "via \($0)") }
            let status: String = if !station.connected {
                String(localized: "Offline")
            } else if let count = station.stationCount, count > 1 {
                String(localized: "\(count) stations")
            } else {
                String(localized: "Online")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(station.connected ? CommaTheme.successPrimary : CommaTheme.textQuaternary)
                    .frame(width: statusDot, height: statusDot)
                    // Centred on the capitals, not sitting on the baseline.
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + statusDot * 0.15 }
                    .accessibilityHidden(true)
                Text([via, status].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(CommaTheme.textTertiary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
        }
    }

    private func notificationLevelTitle(_ level: StillfailNotificationLevel) -> LocalizedStringKey {
        switch level {
        case .off: "Off"
        case .actionNeeded: "When action is needed"
        case .issues: "Action needed and failures"
        case .all: "All updates"
        }
    }

    private func notificationLevelDescription(_ level: StillfailNotificationLevel) -> LocalizedStringKey {
        switch level {
        case .off: "No reminders for Monoid chats. You can still ask Comma about them anytime."
        case .actionNeeded: "When a chat needs your approval, a sign-in, a choice, or a reply."
        case .issues: "Also when a chat stops with an error."
        case .all: "Also when a chat finishes and stays unread for 3 minutes."
        }
    }

    /// A Google sign-in: the page opens in the browser, which shows a code; the code pasted here connects the account.
    /// A rejected code stays, to correct; a fresh sign-in link replaces the old one in place.
    @ViewBuilder private func codeForm(_ plugin: PhonePlugin, _ form: PhonePluginConfiguration) -> some View {
        SettingsNote(icon: "icon-globe") { Text("Sign in with Google, then paste the code the page shows here.") }
        if let url = form.helpURL {
            Button { openURL(url) } label: { SettingsRow(Text("Sign in with Google"), role: .action) }
                .buttonStyle(SurfaceRowButtonStyle())
        }
        TextField(form.label ?? String(localized: "Authorization code"), text: $credential)
            .textContentType(.oneTimeCode).textInputAutocapitalization(.never).autocorrectionDisabled()
            .onSubmit { connect(plugin) }
            .surfaceRowFrame()
            .accessibilityIdentifier("plugin-authorization-code")
        if let error = model.formError ?? form.error { formError(error) }
        Button { connect(plugin) } label: { SettingsRow(Text("Connect"), role: .action) }
            .buttonStyle(SurfaceRowButtonStyle())
            .disabled(plugin.locked || code.isEmpty)
        Button { model.dismissConfiguration(); credential = "" } label: { SettingsRow(Text("Cancel")) }
            .buttonStyle(SurfaceRowButtonStyle())
    }

    private var code: String { credential.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Sends the pasted code; it is kept after a refusal, to correct in place.
    private func connect(_ plugin: PhonePlugin) {
        guard !code.isEmpty else { return }
        Task {
            if let url = await model.install(plugin, credential: code) { openURL(url) }
            if model.formError == nil && model.scope.error == nil { credential = "" }
        }
    }

    private func formError(_ message: String) -> some View {
        Text(message).font(.footnote).foregroundStyle(CommaTheme.errorPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .surfaceRowFrame()
    }

    @ViewBuilder private func accountSources(_ plugin: PhonePlugin) -> some View {
        if !sources.sources.isEmpty {
            SettingsSection(Text("Connected accounts"), footer: Text("Manage this plugin’s accounts and tool authorizations.")) {
                ForEach(sourceRows) { row in
                    let source = row.source
                    VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing / 2) {
                        Text(sourceName(source.string("toolkit"), fallback: plugin.name)).font(.body)
                        if let account = source.string("selectedAccountId") {
                            Text(account).font(.subheadline).foregroundStyle(CommaTheme.textTertiary).textSelection(.enabled)
                        }
                        if let usage = colabUsage(source) {
                            Text(usage).font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                        }
                        if source.string("state") == "needs_reauthorization" {
                            Text("Reconnect this account to keep using it").font(.footnote).foregroundStyle(CommaTheme.errorPrimary)
                        }
                        if source.string("kind") == "native_mcp_oauth" {
                            Text("Tool authorization").font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                        }
                    }.surfaceRowFrame()
                    if source.string("state") != "ready", source.string("kind") != "native_mcp_oauth" {
                        ForEach(source.objects("candidates").compactMap { $0.string("id") }, id: \.self) { account in
                            Button {
                                Task { await sources.run("plugin.sources.prepare", ["toolkit": source.string("toolkit") ?? "", "account": account]) }
                            } label: { SettingsRow(Text(account), role: .action) { SettingsChevron() } }
                                .buttonStyle(SurfaceRowButtonStyle()).disabled(sources.pending)
                        }
                    }
                    if let connection = source.string("connectionId") {
                        Button {
                            Task {
                                if let url = await model.install(plugin, connection: connection, binding: source.string("bindingId")) { openURL(url) }
                            }
                        } label: { SettingsRow(Text("Reconnect account"), role: .action) }
                            .buttonStyle(SurfaceRowButtonStyle()).disabled(sources.pending)
                    }
                }
                Button { Task { await sources.run("plugin.sources.refresh") } } label: { SettingsRow(Text("Refresh accounts")) }
                    .buttonStyle(SurfaceRowButtonStyle())
            }
        }
    }

    @ViewBuilder private func tools(_ plugin: PhonePlugin) -> some View {
        if !sources.groups.isEmpty {
            SettingsSection(Text("Tools")) {
                ForEach(sources.groups.indices, id: \.self) { i in
                    if let group = sources.groups[i].object, let id = group.string("id") {
                        SettingsToggle(title: Text(group.string("name") ?? id), isOn: Binding(get: { group.bool("enabled") }, set: { enabled in
                            Task { await sources.run("plugin.toolGroup.set", ["group": id, "enabled": enabled]) }
                        }))
                    }
                }
            }
        } else if !plugin.tools.isEmpty {
            SettingsSection(Text("Tools")) { ForEach(plugin.tools, id: \.self) { SettingsRow(Text($0)) } }
        }
    }

    /// Each connected account once, by the account it binds (several can share a connection), else its connection.
    private var sourceRows: [SourceRow] {
        var seen = Set<String>()
        return sources.sources.enumerated().compactMap { index, value in
            guard let source = value.object else { return nil }
            var id = source.string("bindingId") ?? source.string("connectionId") ?? "source-\(index)"
            if !seen.insert(id).inserted { id += "-\(index)" }
            return SourceRow(id: id, source: source)
        }
    }

    private struct SourceRow: Identifiable {
        let id: String
        let source: NSDictionary
    }

    /// A Google Colab account's compute units left and the Colab VMs running on it, as the server last read them.
    private func colabUsage(_ source: NSDictionary) -> String? {
        guard source.string("kind") == "oauth_code_paste", let metadata = source.object("metadata") else { return nil }
        let balance = metadata.double("ccuBalance").map {
            String(localized: "\($0.formatted(.number.precision(.fractionLength(0...1)))) compute units left")
        }
        let vms = metadata.int("activeVmCount").map { String(localized: "Running Colab VMs: \($0)") }
        let parts = [balance, vms].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func sourceName(_ toolkit: String?, fallback: String) -> String {
        switch toolkit?.lowercased() {
        case "google-colab": "Google Colab"
        case "gmail": "Gmail"
        case "googlecalendar": "Google Calendar"
        case "googledrive": "Google Drive"
        case "slack": "Slack"
        default: fallback
        }
    }
}

/// What `task(id:)` follows the workspaces by: whether to, and which attempt (Try again starts another).
private struct StationsFollow: Equatable {
    let on: Bool
    let attempt: Int
}

/// A choice with a line saying what it means, then its checkmark.
private struct StationLevelRow<Control: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: GroupedSurface.groupSpacing) {
            VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing / 2) {
                Text(title).font(.body).foregroundStyle(CommaTheme.textPrimary)
                Text(detail).font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            control
        }
        .surfaceRowFrame()
    }
}

/// A connected Monoid workspace's emoji or initial; one not yet connected has no name, so it shows a waiting glyph.
private struct StationWorkspaceBadge: View {
    let name: String?
    let emoji: String?
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 32

    private var initial: String? {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GroupedSurface.groupSpacing, style: .continuous)
                .fill(GroupedSurface.ink)
            if let emoji, !emoji.isEmpty {
                Text(emoji).font(.body)
            } else if let initial {
                Text(initial)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CommaTheme.textSecondary)
            } else {
                CentralIcon("central-chain-link-4", size: 16, relativeTo: .body)
                    .foregroundStyle(CommaTheme.textTertiary)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
