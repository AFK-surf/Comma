import SwiftUI
import CommaCore
import CoreImage.CIFilterBuiltins

/// The Apps tab follows the selected Workspace and starts no list work while another tab is shown.
struct MiniAppsTabView: View {
    let store: CommaStore

    var body: some View {
        if let workspace = store.workspace {
            MiniAppsView(store: store, workspace: workspace).id("\(store.boundaryToken)/\(workspace.id)")
        } else {
            NavigationStack {
                EmptyState(Text("No workspace"), icon: "icon-square-grid",
                           description: Text("Choose or create a workspace to see your apps."))
                    .background(CommaTheme.bgSecondary)
                    .pageTitle("Apps")
            }
        }
    }
}

/// Current Workspace apps. This page follows one Core topic and does not fetch each row separately.
struct MiniAppsView: View {
    let store: CommaStore
    @Environment(AppNavigation.self) private var navigation
    @State private var model: MiniAppsModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""
    @State private var preview: MiniAppTarget?

    init(store: CommaStore, workspace: Workspace) {
        self.store = store
        _model = State(initialValue: MiniAppsModel(store: store, workspace: workspace))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: GroupedSurface.margin) {
                        if !model.apps.isEmpty {
                            FilterSearchField(prompt: "Search apps", text: $query, icon: "icon-search", accessibilityID: "miniAppSearch")
                        }
                        if let failure = model.failure {
                            InlineError(message: failure) { Task { await model.perform("miniApps.refresh") } }
                        }
                        LazyVGrid(columns: columns, spacing: GroupedSurface.margin) {
                            ForEach(shown) { app in
                                MiniAppGridCard(store: store, app: app, workspaceID: model.workspace.id,
                                                status: status(app), canRun: model.current,
                                                continuing: store.canContinueMiniApp(workspaceID: model.workspace.id, appID: app.id),
                                                details: { store.miniAppPresentation = .details(MiniAppTarget(workspaceID: model.workspace.id, appID: app.id)) },
                                                run: { preview = MiniAppTarget(workspaceID: model.workspace.id, appID: app.id) })
                                    .id(app.id)
                            }
                        }
                    }
                    .padding(GroupedSurface.margin)
                }
                .background(CommaTheme.bgSecondary)
                .overlay {
                    Group {
                        if !model.loaded { ProgressView("Loading apps…") }
                        else if model.apps.isEmpty, model.failure == nil {
                            EmptyState(Text("No apps yet"), icon: "icon-square-grid",
                                       description: Text("Ask Comma to build an app. Apps you create or install in this workspace appear here."))
                                .accessibilityIdentifier("miniAppsEmpty")
                        } else if shown.isEmpty, model.failure == nil { EmptyState(Text("No matching apps"), icon: "icon-search") }
                    }.allowsHitTesting(false)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await model.perform("miniApps.refresh") }
                .pageTitle("Apps")
                .task(whileShowing: .apps) { await model.followList() }
                .onChange(of: navigation.reselect[.apps]) { _, _ in
                    query = ""
                    if let first = model.apps.first { withAnimation(CommaMotion.spatialMove) { scroller.scrollTo(first.id, anchor: .top) } }
                }
            }
        }
        .fullScreenCover(item: $preview) { target in MiniAppRunView(store: store, target: target).id(target.id) }
        .onChange(of: model.current) { _, current in if !current { preview = nil } }
    }

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 260), spacing: GroupedSurface.margin)]
    }

    private var shown: [MiniAppRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.apps.filter { query.isEmpty || ($0.name + " " + $0.summary).localizedCaseInsensitiveContains(query) }
    }

    private func status(_ app: MiniAppRecord) -> String {
        if app.status == "disabled" { return String(localized: "Disabled") }
        guard let version = app.runningVersion else { return String(localized: "Not published") }
        if app.installed { return String(localized: "Installed · v\(version)") }
        return app.liveVersion == nil ? String(localized: "Preview · v\(version)") : "v\(version)"
    }
}

/// Version artwork and navigation share a card; Run remains a separate action.
private struct MiniAppGridCard: View {
    let store: CommaStore
    let app: MiniAppRecord
    let workspaceID: String
    let status: String
    let canRun: Bool
    let continuing: Bool
    let details: () -> Void
    let run: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var pressed = false
    @State private var lightTitle = false

    private var via: [String: String] { ["workspace": workspaceID] }
    private var runTitle: LocalizedStringKey { continuing ? "Continue" : "Run" }
    private var titleColor: Color {
        if reduceTransparency { return CommaTheme.textPrimary }
        return Color(UIColor(CommaTheme.textPrimary).resolvedColor(with: UITraitCollection(userInterfaceStyle: lightTitle ? .dark : .light)))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: details) {
                VStack(spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        MiniAppArtwork(store: store, url: app.coverURL, via: via,
                                       height: 184, cover: true, progressiveBlur: !reduceTransparency,
                                       coverContrast: { lightTitle = $0 })
                        if reduceTransparency {
                            CommaTheme.cardPrimary.frame(height: 80).frame(maxHeight: .infinity, alignment: .bottom)
                        }
                        HStack(spacing: 12) {
                            MiniAppArtwork(store: store, url: app.iconURL, via: via, icon: true)
                                .background(CommaTheme.cardPrimary, in: RoundedRectangle(cornerRadius: 12))
                            Text(app.name).font(.headline).foregroundStyle(titleColor)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(GroupedSurface.margin)
                    }
                    .frame(height: 184)
                    .clipped()
                    HStack(alignment: .center, spacing: GroupedSurface.margin) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.summary.isEmpty ? app.author : app.summary)
                                .font(.subheadline).foregroundStyle(CommaTheme.textSecondary).lineLimit(2)
                            Text(status).font(.caption).foregroundStyle(CommaTheme.textTertiary)
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(runTitle).font(.subheadline.weight(.medium))
                            .padding(.horizontal, 24).frame(minHeight: 44)
                            .hidden().accessibilityHidden(true)
                    }
                    .padding(GroupedSurface.margin)
                }
                .background(CommaTheme.cardPrimary)
                .clipShape(RoundedRectangle(cornerRadius: GroupedSurface.radius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: GroupedSurface.radius, style: .continuous))
            }
            .buttonStyle(MiniAppCardPressStyle(pressed: $pressed))
            .accessibilityLabel(app.name)
            .accessibilityValue(Text(app.summary.isEmpty ? app.author : app.summary) + Text(" · ") + Text(status))
            .accessibilityIdentifier("mini-app-" + app.id)
            runButton
                .disabled(app.status != "active" || app.runningVersion == nil || !canRun)
                .accessibilityLabel(Text(runTitle) + Text(" ") + Text(app.name))
                .accessibilityIdentifier("mini-app-run-" + app.id)
                .padding(GroupedSurface.margin)
        }
        .scaleEffect(pressed ? 0.98 : 1)
        .animation(pressed ? .easeOut(duration: 0.05) : CommaMotion.release, value: pressed)
    }

    @ViewBuilder private var runButton: some View {
        if #available(iOS 26.0, *) {
            Button(runTitle, action: run)
                .font(.subheadline.weight(.medium))
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        } else {
            Button(action: run) { Text(runTitle).frame(minHeight: 44) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }
}

private struct MiniAppCardPressStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, value in pressed = value }
            .onDisappear { pressed = false }
    }
}

/// Selected app settings and Versions. Only the selected Version's build is observed for publication.
struct MiniAppDetailView: View {
    let store: CommaStore
    let appID: String
    var close: (() -> Void)?
    var openBuild: ((String) -> Void)?
    @State private var model: MiniAppsModel
    @State private var selected: Int?
    @State private var preview: MiniAppTarget?
    @State private var rollback: MiniAppVersionRecord?
    @State private var removing = false
    @State private var compactTitle = false
    @State private var managing = false
    @Environment(\.dismiss) private var dismiss

    init(store: CommaStore, workspace: Workspace, appID: String, close: (() -> Void)? = nil,
         openBuild: ((String) -> Void)? = nil) {
        self.store = store; self.appID = appID; self.close = close; self.openBuild = openBuild
        _model = State(initialValue: MiniAppsModel(store: store, workspace: workspace))
    }

    private var chosen: MiniAppVersionRecord? { model.versions.first { $0.number == selected } ?? model.versions.max { $0.number < $1.number } }

    var body: some View {
        GeometryReader { geometry in
            let coverHeight = min(300, max(180, min(geometry.size.width * 0.5, geometry.size.height * 0.55)))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let failure = model.failure {
                        InlineError(message: failure) { Task { await model.perform("miniApp.refresh", ["app": appID]) } }
                            .padding(GroupedSurface.margin)
                    }
                    if let app = model.app {
                        MiniAppArtwork(store: store, url: app.coverURL, via: via,
                                       height: coverHeight, cover: true, cornerRadius: 0)
                            .accessibilityIdentifier("mini-app-detail-cover")
                        VStack(alignment: .leading, spacing: GroupedSurface.margin) {
                            identity(app)
                            facts(app)
                            if let release = model.versions.first(where: { $0.number == app.runningVersion }), !release.notes.isEmpty {
                                VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing) {
                                    HStack {
                                        sectionTitle("What's New", icon: "central-history")
                                        Spacer()
                                        Text("v\(release.number)").font(.subheadline).foregroundStyle(CommaTheme.textSecondary)
                                    }
                                    Text(release.notes).font(.subheadline).textSelection(.enabled)
                                }
                            }
                            if !app.screenshotURLs.isEmpty {
                                VStack(alignment: .leading, spacing: GroupedSurface.margin) {
                                    sectionTitle("Preview", icon: "central-images-1")
                                    MiniAppScreenshots(store: store, urls: app.screenshotURLs, via: via,
                                                       height: 300, width: geometry.size.width > 560 ? 220 : 180, inset: 0)
                                }
                            }
                            if !app.summary.isEmpty {
                                Divider()
                                MiniAppDescription(text: app.summary)
                            }
                            Divider()
                            DisclosureGroup(isExpanded: $managing) {
                                VStack(spacing: GroupedSurface.margin) {
                                    if model.owner { access(app) }
                                    if !model.versions.isEmpty { versions(app) }
                                    management(app)
                                }.padding(.top, GroupedSurface.margin)
                            } label: {
                                sectionTitle("Versions and management", icon: "central-planning")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .accessibilityIdentifier("mini-app-detail-management")
                        }
                        .padding(.horizontal, GroupedSurface.margin)
                        .padding(.leading, geometry.safeAreaInsets.leading)
                        .padding(.trailing, geometry.safeAreaInsets.trailing)
                        .padding(.vertical, GroupedSurface.margin)
                    } else if model.missing {
                        EmptyState(Text("App unavailable"), icon: "central-exclamation-triangle",
                                   description: Text("This app was removed or is no longer shared with this workspace."))
                    } else if !model.loaded { ProgressView("Loading app…").frame(maxWidth: .infinity).padding(GroupedSurface.margin) }
                }
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > coverHeight + 140 } action: { _, compact in
                compactTitle = compact
            }
            .ignoresSafeArea(.container, edges: [.top, .horizontal])
        }
        .background(CommaTheme.bgPrimary)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(compactTitle ? .visible : .hidden, for: .navigationBar)
        .modifier(MiniAppDetailToolbar())
        .toolbar {
            if let close {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: close) { CentralIcon("icon-close") }
                        .accessibilityLabel("Close app details")
                        .accessibilityIdentifier("closeMiniAppDetails")
                }
                .horizontalBarOnly()
            }
            ToolbarItem(placement: .principal) {
                if compactTitle, let app = model.app {
                    HStack(spacing: 8) {
                        MiniAppArtwork(store: store, url: app.iconURL, via: via, icon: true, iconSize: 28)
                        Text(app.name).font(.headline).lineLimit(1)
                    }.accessibilityIdentifier("mini-app-detail-compact-title")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                runButton(identifier: "mini-app-detail-run")
            }
        }
        .disabled(model.busy)
        .task { await model.followApp(appID) }
        .task(id: chosen?.conversationID) { await model.followReview(chosen?.conversationID) }
        .fullScreenCover(item: $preview) { target in MiniAppRunView(store: store, target: target).id(target.id) }
        .alert("Change the live version?", isPresented: Binding(get: { rollback != nil }, set: { if !$0 { rollback = nil } })) {
            if let rollback {
                Button("Use v\(rollback.number)") { Task { await model.perform("miniApps.rollback", ["app": appID, "version": rollback.number]) }; self.rollback = nil }
            }
            Button("Cancel", role: .cancel) { rollback = nil }
        } message: {
            Text("People following the live version will use v\(rollback?.number ?? 0). Cloud data stays in place.")
        }
        .onChange(of: model.current) { _, current in if !current { preview = nil; dismiss() } }
        .onChange(of: model.missing) { _, missing in if missing { preview = nil; dismiss() } }
        .alert("Uninstall this app?", isPresented: $removing) {
            Button("Uninstall", role: .destructive) {
                Task { if await model.perform("miniApps.uninstall", ["app": appID]) { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the installation and permissions from \(model.workspace.name). The app and its cloud data are not deleted.")
        }
    }

    private var via: [String: String] { ["workspace": model.workspace.id] }
    private var continuing: Bool { store.canContinueMiniApp(workspaceID: model.workspace.id, appID: appID) }

    @ViewBuilder private func runButton(identifier: String) -> some View {
        let button = Button(continuing ? "Continue" : "Run") { preview = MiniAppTarget(workspaceID: model.workspace.id, appID: appID) }
            .disabled(!model.current || model.app?.status != "active" || model.app?.runningVersion == nil)
            .accessibilityIdentifier(identifier)
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
        } else { button.buttonStyle(.borderedProminent).buttonBorderShape(.capsule) }
    }

    private func identity(_ app: MiniAppRecord) -> some View {
        HStack(alignment: .center, spacing: GroupedSurface.margin) {
            MiniAppArtwork(store: store, url: app.iconURL, via: via, icon: true, iconSize: 80)
                .background(CommaTheme.bgSecondary, in: RoundedRectangle(cornerRadius: GroupedSurface.radius))
            VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing) {
                Text(app.name).font(.title3.bold()).foregroundStyle(CommaTheme.textPrimary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !app.author.isEmpty { Text(app.author).font(.subheadline).foregroundStyle(CommaTheme.textSecondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            runButton(identifier: "mini-app-detail-primary-run")
        }
    }

    private func facts(_ app: MiniAppRecord) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: GroupedSurface.margin) {
                fact("Version", icon: "central-history", value: app.runningVersion.map { "v\($0)" } ?? String(localized: "Not published"))
                fact("Access", icon: app.visibility == "private" ? "central-people-circle" : app.visibility == "workspace" ? "central-buildings" : "central-chain-link-4", value: app.visibility == "private" ? String(localized: "Only me") : app.visibility == "workspace" ? String(localized: "Workspace") : String(localized: "Anyone with the link"))
                fact("Status", icon: app.status == "active" ? "central-circle-check" : "central-circle-minus", value: app.status == "active" ? String(localized: "Active") : String(localized: "Disabled"))
            }.padding(.vertical, GroupedSurface.inset)
            Divider()
        }
    }

    private func fact(_ title: LocalizedStringKey, icon: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing) {
            HStack(spacing: 4) {
                CentralIcon(icon, size: 16, relativeTo: .caption)
                Text(title).font(.caption)
            }.foregroundStyle(CommaTheme.textTertiary)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(CommaTheme.textPrimary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: GroupedSurface.groupSpacing) {
            CentralIcon(icon, size: 20, relativeTo: .headline).foregroundStyle(CommaTheme.textTertiary)
            Text(title).font(.headline)
        }.foregroundStyle(CommaTheme.textPrimary)
    }

    @ViewBuilder private func management(_ app: MiniAppRecord) -> some View {
        if model.owner {
            SettingsSection(Text("Manage")) {
                Button { Task { await model.perform(app.status == "active" ? "miniApps.disable" : "miniApps.enable", ["app": appID]) } } label: {
                    SettingsRow(Text(app.status == "active" ? "Disable app" : "Enable app"), role: .action)
                }.buttonStyle(SurfaceRowButtonStyle())
            }
        } else if app.installed {
            SettingsSection(Text("Manage")) {
                SettingsRow(Text("Version updates"), value: Text(app.pinnedVersion.map { "v\($0)" } ?? String(localized: "Follows live version")))
                Button { removing = true } label: { SettingsRow(Text("Uninstall app"), role: .destructive) }
                    .buttonStyle(SurfaceRowButtonStyle())
            }
        }
    }

    private func access(_ app: MiniAppRecord) -> some View {
        SettingsSection(Text("Access")) {
            Picker("Who can open this app", selection: Binding(get: { app.visibility }, set: { value in
                Task {
                    if await model.perform("miniApps.update", ["app": appID, "visibility": value]) {
                        await model.perform("miniApp.refresh", ["app": appID])
                    }
                }
            })) { MiniAppVisibilityOptions() }
            .surfaceRowFrame()
            if app.visibility == "link" {
                if let link = model.linkURL { Text(verbatim: link).font(.footnote).textSelection(.enabled).surfaceRowFrame() }
                else {
                    Button { Task { await model.perform("miniApps.link.publish", ["app": appID]) } } label: {
                        SettingsRow(Text("Create share link"), role: .action)
                    }.buttonStyle(SurfaceRowButtonStyle())
                }
            }
        }
    }

    private func versions(_ app: MiniAppRecord) -> some View {
        SettingsSection(Text("Versions")) {
            Picker("Version", selection: Binding(get: { chosen?.number }, set: { selected = $0 })) {
                ForEach(model.versions.sorted { $0.number > $1.number }) { version in
                    Text(version.live ? "v\(version.number) · Live" : "v\(version.number) · \(versionState(version))")
                        .tag(Optional(version.number))
                }
            }.surfaceRowFrame()
            if let version = chosen {
                if !version.notes.isEmpty { SettingsRow(Text(version.notes)) }
                if let commit = version.commit { SettingsRow(Text("Commit"), value: Text(String(commit.prefix(7))).monospaced()) }
                if version.state == "ready", app.status == "active" {
                    Button {
                        preview = MiniAppTarget(workspaceID: model.workspace.id, appID: appID, version: version.number,
                                                publication: model.publication(for: version))
                    } label: {
                        SettingsRow(Text(model.publication(for: version) == nil ? "Preview version" : "Preview and publish"), role: .action) { SettingsChevron() }
                    }.buttonStyle(SurfaceRowButtonStyle())
                    if model.owner, !version.live {
                        Button { rollback = version } label: { SettingsRow(Text("Make this version live"), role: .action) }
                            .buttonStyle(SurfaceRowButtonStyle())
                    }
                }
                if let task = version.conversationID {
                    Button {
                        if let openBuild { openBuild(task) }
                        else { Task { await store.openTask(id: task) }; dismiss() }
                    } label: {
                        SettingsRow(Text("Open build task"), role: .action) { SettingsChevron() }
                    }.buttonStyle(SurfaceRowButtonStyle())
                }
            }
        }
    }

    private func versionState(_ version: MiniAppVersionRecord) -> String {
        switch version.state {
        case "ready": String(localized: "Ready")
        case "uploading": String(localized: "Uploading")
        default: String(localized: "Failed")
        }
    }
}

struct MiniAppVisibilityOptions: View {
    var body: some View {
        Text("Only me").tag("private")
        Text("Workspace").tag("workspace")
        Text("Anyone with the link").tag("link")
    }
}

/// Publication names the previewed Version and review. The existing server path accepts the review and merges the PR.
struct MiniAppPublishView: View {
    let model: MiniAppsModel
    let publication: MiniAppPublication
    @State private var visibility = "workspace"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsPage {
                SettingsSection {
                    SettingsRow(Text(model.app?.name ?? String(localized: "App")), value: Text("v\(publication.version)"))
                    Picker("Who can open this app", selection: $visibility) { MiniAppVisibilityOptions() }.surfaceRowFrame()
                }
                Text("Publishing accepts this Task’s review, merges its pull request at the previewed commit, and makes v\(publication.version) live.")
                    .font(.subheadline).foregroundStyle(CommaTheme.textSecondary)
                if let failure = model.failure { Text(verbatim: failure).foregroundStyle(CommaTheme.errorPrimary) }
                if model.busy { ProgressView("Publishing…") }
            }
            .navigationTitle("Publish app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish v\(publication.version)") { Task { if await model.publish(publication, visibility: visibility) { dismiss() } } }
                        .disabled(model.busy)
                }
            }
            .disabled(model.busy)
        }
        .interactiveDismissDisabled(model.busy)
        .onChange(of: model.current) { _, current in if !current { dismiss() } }
    }
}

/// Host artwork uses Core authorization. It grants no capability to an app.
struct MiniAppArtwork: View {
    let store: CommaStore
    let url: String?
    let via: [String: String]
    var icon = false
    var iconSize: CGFloat = 40
    var height: CGFloat = 240
    var cover = false
    var progressiveBlur = false
    var coverContrast: ((Bool) -> Void)?
    var cornerRadius: CGFloat? = nil
    var fitAlignment: Alignment = .center
    @State private var loaded: (key: String, image: UIImage)?

    private var key: String { "\(store.boundaryToken)/\(via["workspace"] ?? via["token"] ?? "")/\(url ?? "")" }

    var body: some View {
        ZStack {
            if cover {
                GeometryReader { geometry in
                    MiniAppCoverImage(image: loaded?.key == key ? loaded?.image : UIImage(named: "MiniAppCoverPlaceholder"),
                                      sourceKey: loaded?.key == key ? key : "placeholder",
                                      size: geometry.size, progressive: progressiveBlur, contrast: coverContrast)
                }
            } else if let loaded, loaded.key == key {
                Image(uiImage: loaded.image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fitAlignment)
            } else if icon {
                CentralIcon("icon-square-grid", size: iconSize * 0.6, relativeTo: .body)
                    .foregroundStyle(CommaTheme.textTertiary)
            }
        }
        .frame(width: icon ? iconSize : nil, height: icon ? iconSize : (cover || loaded?.key == key ? height : 0))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? (icon && iconSize != 40 ? iconSize * 0.22 : GroupedSurface.radius)))
        .accessibilityHidden(true)
        .task(id: key) {
            loaded = nil
            let requestKey = key
            guard let url else { return }
            // The core reads the image with the account's session and access path (topic `miniAppImage`).
            var topic: [String: Any] = ["topic": "miniAppImage", "url": url]
            if let workspace = via["workspace"] { topic["workspace"] = workspace } else if let token = via["token"] { topic["link"] = token }
            var src: String?
            for await update in store.core.subscribe(topic, read: { value -> String?? in
                guard let value = value as? [String: Any], value["status"] as? String == "ready" else { return nil }
                return .some(value["src"] as? String)
            }) {
                guard case .value(let read) = update else { return }
                if let read { src = read; break }
            }
            guard !Task.isCancelled, key == requestKey, let value = src,
                  let comma = value.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
                  let image = UIImage(data: data) else { return }
            loaded = (requestKey, image)
        }
    }
}

struct MiniAppScreenshots: View {
    let store: CommaStore
    let urls: [String]
    let via: [String: String]

    var height: CGFloat = 280
    var width: CGFloat = 160
    var inset: CGFloat = GroupedSurface.margin

    var body: some View {
        if !urls.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(spacing: GroupedSurface.margin) {
                    ForEach(Array(urls.prefix(6)), id: \.self) { url in
                        MiniAppArtwork(store: store, url: url, via: via, height: height, fitAlignment: .top)
                            .frame(width: width, height: height)
                    }
                }.padding(.horizontal, inset)
            }
            .frame(height: height)
            .accessibilityLabel("App screenshots")
        }
    }
}

/// A static cover is cropped once, then blurred with a radius that grows toward its bottom edge.
private struct MiniAppCoverImage: View {
    let image: UIImage?
    let sourceKey: String
    let size: CGSize
    let progressive: Bool
    let contrast: ((Bool) -> Void)?
    @Environment(\.displayScale) private var scale
    @State private var rendered: (key: String, image: UIImage)?
    private var key: String { "\(sourceKey)/\(Int(size.width * scale))/\(Int(size.height * scale))/\(progressive)" }

    var body: some View {
        Group {
            if let picture = rendered?.key == key ? rendered?.image : image {
                Image(uiImage: picture).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height, alignment: .top).clipped()
            } else { CommaTheme.bgTertiary }
        }
        .task(id: key) {
            rendered = nil
            guard progressive, let image, let source = image.cgImage, size.width > 0, size.height > 0 else { return }
            let request = key
            let orientation: Int32
            switch image.imageOrientation {
            case .up: orientation = 1
            case .upMirrored: orientation = 2
            case .down: orientation = 3
            case .downMirrored: orientation = 4
            case .leftMirrored: orientation = 5
            case .right: orientation = 6
            case .rightMirrored: orientation = 7
            case .left: orientation = 8
            @unknown default: orientation = 1
            }
            guard let result = await MiniAppCoverProcessor.shared.render(source, orientation: orientation, size: size, scale: scale),
                  !Task.isCancelled, request == key else { return }
            rendered = (request, UIImage(cgImage: result.image))
            contrast?(result.lightText)
        }
        .onDisappear { rendered = nil }
    }
}

actor MiniAppCoverProcessor {
    static let shared = MiniAppCoverProcessor()
    private let context = CIContext(options: [.cacheIntermediates: false])

    func render(_ source: CGImage, orientation: Int32 = 1, size: CGSize, scale: CGFloat) -> (image: CGImage, lightText: Bool)? {
        guard !Task.isCancelled, size.width > 0, size.height > 0 else { return nil }
        // Raster work is bounded by the visible cover, even if its original screenshot is very large.
        let pixelsPerPoint = min(scale, 1200 / size.width, 900 / size.height)
        let bounds = CGRect(x: 0, y: 0, width: ceil(size.width * pixelsPerPoint), height: ceil(size.height * pixelsPerPoint))
        let original = CIImage(cgImage: source).oriented(forExifOrientation: orientation)
        let normalized = original.transformed(by: CGAffineTransform(translationX: -original.extent.minX, y: -original.extent.minY))
        let factor = max(bounds.width / normalized.extent.width, bounds.height / normalized.extent.height)
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let cropped = scaled.transformed(by: CGAffineTransform(translationX: -(scaled.extent.width - bounds.width) / 2,
                                                               y: -(scaled.extent.height - bounds.height))).cropped(to: bounds)
        let gradient = CIFilter.linearGradient()
        gradient.point0 = .zero; gradient.color0 = .white
        gradient.point1 = CGPoint(x: 0, y: bounds.height * 0.38); gradient.color1 = .black
        let blur = CIFilter.maskedVariableBlur()
        blur.inputImage = cropped.clampedToExtent()
        blur.mask = gradient.outputImage?.cropped(to: bounds)
        blur.radius = Float(20 * pixelsPerPoint)
        guard !Task.isCancelled, let output = blur.outputImage,
              let image = context.createCGImage(output, from: bounds) else { return nil }
        let average = CIFilter.areaAverage()
        average.inputImage = cropped
        average.extent = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.3)
        var rgba = [UInt8](repeating: 0, count: 4)
        if let swatch = average.outputImage {
            context.render(swatch, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        let linear = rgba.prefix(3).map { value -> Double in
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        return (image, luminance < 0.2)
    }
}

private struct MiniAppDescription: View {
    let text: String
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var foldedHeight: CGFloat = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: GroupedSurface.groupSpacing) {
                CentralIcon("central-circle-info-fill", size: 20, relativeTo: .headline).foregroundStyle(CommaTheme.textTertiary)
                Text("About this app").font(.headline)
            }
            Text(text).font(.subheadline).lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !expanded { foldedHeight = $0 } }
                .background(alignment: .topLeading) {
                    Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        .hidden().accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
            if fullHeight > foldedHeight + 1 || expanded {
                Button { expanded.toggle() } label: {
                    Text(expanded ? "Less" : "More").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("mini-app-detail-description-toggle")
            }
        }.foregroundStyle(CommaTheme.textPrimary)
    }
}

private struct MiniAppDetailToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) { content.toolbarMinimizationBehavior(.never, for: .navigationBar) }
        else { content }
    }
}
