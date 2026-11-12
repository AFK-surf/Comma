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
            if phase == .active { Task { _ = try? await model.scope.call("plugin.authorization.check", workspaceParameter: false) } }
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
    @State private var credential = ""
    @State private var confirmingRemove = false
    @Environment(\.openURL) private var openURL

    init(model: PhonePluginsModel, pluginID: String) {
        self.model = model; self.pluginID = pluginID
        _sources = State(initialValue: PhonePluginSourcesModel(scope: model.scope, plugin: pluginID))
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
                    accountSources(plugin)
                    tools(plugin)
                }
                if !plugin.skills.isEmpty {
                    SettingsSection(Text("Skills")) {
                        ForEach(plugin.skills, id: \.self) { name in SettingsRow(Text(name), icon: "central-puzzle") }
                    }
                }
            }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }
        .pageTitle(verbatim: plugin?.name ?? String(localized: "Plugin")) { EmptyView() }
        .disabled(model.scope.busy || !model.scope.current)
        .task(id: plugin?.installed) { if plugin?.installed == true { await sources.followSources() } }
        .task(id: plugin?.toolGroups == true && plugin?.installed == true) {
            if plugin?.toolGroups == true && plugin?.installed == true { await sources.followGroups() }
        }
        .alert("Confirm account", isPresented: Binding(get: { sources.confirmation != nil }, set: { _ in })) {
            Button("Cancel", role: .cancel) { Task { await sources.run("plugin.sources.cancel") } }
            Button("Confirm") { Task { await sources.run("plugin.sources.confirm") } }
        } message: { Text(sources.confirmation?.object?.string("identity") ?? "") }
        .confirmationDialog("Remove plugin?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove plugin", role: .destructive) { Task { if let plugin { await model.remove(plugin) } } }
        } message: { Text("Comma will stop using this plugin in this workspace.") }
        .onDisappear { credential = "" }
    }

    @ViewBuilder private func connection(_ plugin: PhonePlugin) -> some View {
        SettingsSection(Text("Connection")) {
            if plugin.authorizing || model.authorizationPlugin == plugin.id && model.authorizationURL != nil {
                SettingsNote(icon: "icon-globe") { Text("Finish authorizing in your browser…") }
                if let url = model.authorizationURL, model.authorizationPlugin == plugin.id {
                    Button { openURL(url) } label: { SettingsRow(Text("Continue in browser"), role: .action) }
                        .buttonStyle(SurfaceRowButtonStyle())
                }
                Button { Task { await sources.run("plugin.cancel") } } label: { SettingsRow(Text("Cancel connection")) }
                    .buttonStyle(SurfaceRowButtonStyle())
            } else if plugin.working {
                SettingsNote { ProgressView() } message: { Text("Updating connection…") }
            } else if !plugin.installed || model.configurationPlugin == plugin.id {
                if plugin.credentialKey != nil {
                    SecureField(plugin.credentialLabel ?? String(localized: "API key"), text: $credential)
                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled().surfaceRowFrame()
                    if let url = plugin.helpURL { Link(destination: url) { SettingsRow(Text("Setup instructions"), role: .action) } }
                }
                Button {
                    Task {
                        if let url = await model.install(plugin, credential: credential.isEmpty ? nil : credential) { openURL(url) }
                        credential = ""
                    }
                } label: { SettingsRow(Text("Connect plugin"), role: .action) }
                    .buttonStyle(SurfaceRowButtonStyle())
                    .disabled(plugin.locked || plugin.credentialKey != nil && credential.isEmpty)
            } else {
                SettingsRow(Text("Status"), value: Text("Connected"))
                if !plugin.locked {
                    Button { confirmingRemove = true } label: { SettingsRow(Text("Remove plugin"), role: .destructive) }
                        .buttonStyle(SurfaceRowButtonStyle())
                }
            }
        }
    }

    @ViewBuilder private func accountSources(_ plugin: PhonePlugin) -> some View {
        if !sources.sources.isEmpty {
            SettingsSection(Text("Connected accounts"), footer: Text("Manage this plugin’s accounts and tool authorizations.")) {
                ForEach(sources.sources.indices, id: \.self) { i in
                    if let source = sources.sources[i].object {
                        VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing / 2) {
                            Text(sourceName(source.string("toolkit"), fallback: plugin.name)).font(.body)
                            if let account = source.string("selectedAccountId") {
                                Text(account).font(.subheadline).foregroundStyle(CommaTheme.textTertiary).textSelection(.enabled)
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
                                Task { if let url = await model.install(plugin, connection: connection) { openURL(url) } }
                            } label: { SettingsRow(Text("Reconnect account"), role: .action) }
                                .buttonStyle(SurfaceRowButtonStyle()).disabled(sources.pending)
                        }
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

    private func sourceName(_ toolkit: String?, fallback: String) -> String {
        switch toolkit?.lowercased() {
        case "gmail": "Gmail"
        case "googlecalendar": "Google Calendar"
        case "googledrive": "Google Drive"
        case "slack": "Slack"
        default: fallback
        }
    }
}
