import CommaCore
import Foundation
import Observation
import SwiftUI

/// A Link resolves through the Core. It never creates an Install until the member confirms a destination.
@MainActor @Observable
final class MiniAppSharedModel {
    let link: MiniAppSharedLink
    private weak var store: CommaStore?
    private let boundary: Int
    private let accountID: String?
    private(set) var app: MiniAppRecord?
    private(set) var version: Int?
    private(set) var loading = false
    private(set) var busy = false
    private(set) var installation: MiniAppRecord?
    private(set) var installationKnown = false
    private var observedWorkspace: String?
    private(set) var workspaceID: String?
    var followLive = true
    var failure: String?
    var installationFailure: String?

    init(store: CommaStore, link: MiniAppSharedLink) {
        self.store = store; self.link = link
        boundary = store.boundaryToken; accountID = store.session?.user.id; workspaceID = store.workspace?.id
    }

    var current: Bool { accountID != nil && store?.session?.user.id == accountID && store?.boundaryToken == boundary }
    var workspaces: [Workspace] { store?.workspaces ?? [] }
    var ownsApp: Bool { app?.workspaceID == workspaceID }
    var canInstall: Bool {
        current && app != nil && !ownsApp && !busy && installationKnown && observedWorkspace == workspaceID &&
            installation?.installed != true && workspaces.contains { $0.id == workspaceID }
    }

    func selectWorkspace(_ id: String?) {
        workspaceID = id; installation = nil; installationKnown = false; observedWorkspace = nil
        installationFailure = nil; followLive = true
    }

    func resolve() async {
        guard current, !loading, let core = store?.core else { return }
        loading = true; failure = nil; app = nil; version = nil
        defer { loading = false }
        do {
            let resolved = try await core.object("miniApps.link.resolve", ["token": link.token])
            guard current, !Task.isCancelled else { return }
            guard let app = resolved.object("app").flatMap(MiniAppRecord.init), let version = resolved.int("version") else {
                failure = String(localized: "The shared app could not load. Try again.")
                return
            }
            self.app = app; self.version = version
        } catch {
            guard current, !Task.isCancelled else { return }
            failure = (error as? CoreError)?.status == 404
                ? String(localized: "This link expired, was revoked, or its app is unavailable.")
                : String(localized: "The shared app could not load. Try again.")
        }
    }

    /// At most one selected Workspace's Install is observed, with no per-Workspace scans or polling.
    func followInstallation() async {
        installation = nil; installationKnown = false; installationFailure = nil
        guard current, let workspaceID, let app, let core = store?.core else { return }
        observedWorkspace = workspaceID
        if app.workspaceID == workspaceID { installationKnown = true; return }
        let appID = app.id
        let topic: [String: Any] = ["topic": "miniApp", "workspace": workspaceID, "app": appID]
        for await value in core.subscribe(topic, read: { CoreJSON(value: $0) }) {
            guard current, self.workspaceID == workspaceID, !Task.isCancelled else { return }
            switch value {
            case .value(let next):
                let json = next.object
                switch json?.string("status") {
                case "ready": installation = json?.object("app").flatMap(MiniAppRecord.init); installationKnown = true
                case "missing": installation = nil; installationKnown = true
                case "failed": installationFailure = String(localized: "The installation could not load. Try again.")
                default: break
                }
            case .failed: installationFailure = String(localized: "The installation could not load. Try again.")
            }
        }
    }

    @discardableResult
    func install() async -> Bool {
        guard canInstall, let workspaceID, let core = store?.core else { return false }
        busy = true; failure = nil
        defer { busy = false }
        var params: [String: Any] = ["workspace": workspaceID, "token": link.token]
        if !followLive, let version { params["pinnedVersion"] = version }
        do {
            let added = try await core.object("miniApps.install", params)
            guard current, self.workspaceID == workspaceID else { return false }
            installation = MiniAppRecord(added); installationKnown = true
            return true
        } catch {
            if current { failure = String(localized: "The app could not be installed. The link or your workspace access may have changed.") }
            return false
        }
    }

    func sharedTarget() -> MiniAppTarget? {
        guard current, let app else { return nil }
        return MiniAppTarget(workspaceID: store?.workspace?.id ?? "", appID: app.id, shareToken: link.token)
    }

    func installedTarget() -> MiniAppTarget? {
        guard current, let workspaceID, let app, ownsApp || installation?.installed == true else { return nil }
        return MiniAppTarget(workspaceID: workspaceID, appID: app.id)
    }

    @discardableResult
    func uninstall() async -> Bool {
        guard current, !busy, !ownsApp, installation?.installed == true, let workspaceID, let app, let core = store?.core else { return false }
        busy = true; failure = nil
        defer { busy = false }
        do {
            _ = try await core.call("miniApps.uninstall", ["workspace": workspaceID, "app": app.id])
            guard current, self.workspaceID == workspaceID else { return false }
            if let session = store?.miniAppSessions[workspaceID + "/" + app.id], let target = session.target {
                store?.closeMiniApp(session, target: target)
            }
            installation = nil; installationKnown = true
            return true
        } catch {
            if current { failure = String(localized: "The app could not be uninstalled. Try again.") }
            return false
        }
    }
}

struct MiniAppSharedView: View {
    let store: CommaStore
    @State private var model: MiniAppSharedModel
    @State private var preview: MiniAppTarget?
    @State private var installationRead = 0
    @State private var removing = false
    @Environment(\.dismiss) private var dismiss

    init(store: CommaStore, link: MiniAppSharedLink) {
        self.store = store
        _model = State(initialValue: MiniAppSharedModel(store: store, link: link))
    }

    var body: some View {
        NavigationStack {
            SettingsPage {
                if let failure = model.failure {
                    InlineError(message: failure) { Task { await model.resolve() } }
                }
                if let app = model.app {
                    SettingsSection {
                        HStack {
                            MiniAppArtwork(store: store, url: app.iconURL, via: ["token": model.link.token], icon: true)
                            SettingsRow(Text(app.name), value: Text("v\(model.version ?? 0)"))
                        }.padding(.leading, GroupedSurface.margin)
                        if !app.summary.isEmpty { SettingsRow(Text(app.summary)) }
                        SettingsRow(Text("By \(app.author)"))
                        Button { preview = model.sharedTarget() } label: {
                            SettingsRow(Text(model.sharedTarget().flatMap { store.retainedMiniApp(for: $0) }?.isSuspended == true ? "Continue" : "Run shared app"), role: .action) { SettingsChevron() }
                        }.buttonStyle(SurfaceRowButtonStyle())
                    }
                    MiniAppScreenshots(store: store, urls: app.screenshotURLs, via: ["token": model.link.token])
                    SettingsSection(Text("Install in a workspace")) {
                        if model.workspaces.isEmpty {
                            SettingsRow(Text("Choose or create a workspace in Comma before installing this app."))
                        } else {
                            SettingsRow(Text("Workspace")) {
                                Picker("Workspace", selection: Binding(get: { model.workspaceID }, set: { model.selectWorkspace($0) })) {
                                    Text("Choose a workspace").tag(String?.none)
                                    ForEach(model.workspaces) {
                                        Text($0.name.isEmpty ? String(localized: "Untitled workspace") : $0.name).tag(Optional($0.id))
                                    }
                                }.labelsHidden().pickerStyle(.menu)
                            }
                            installation
                        }
                    }
                } else if model.loading { ProgressView("Loading shared app…").frame(maxWidth: .infinity) }
            }
            .navigationTitle("Shared app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(model.busy) } }
            .disabled(model.busy)
        }
        .task { await model.resolve() }
        .task(id: "\(model.app?.id ?? "")/\(model.workspaceID ?? "")/\(installationRead)") { await model.followInstallation() }
        .fullScreenCover(item: $preview) { target in MiniAppRunView(store: store, target: target).id(target.id) }
        .interactiveDismissDisabled(model.busy)
        .alert("Uninstall this app?", isPresented: $removing) {
            Button("Uninstall", role: .destructive) { Task { await model.uninstall() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this workspace’s installation and its permissions. The app and its cloud data are not deleted.")
        }
        .onChange(of: model.current) { _, current in if !current { preview = nil; dismiss() } }
    }

    @ViewBuilder private var installation: some View {
        if model.ownsApp {
            SettingsRow(Text("This workspace owns the app."))
            openInstalled
        } else if let app = model.installation, app.installed {
            SettingsRow(Text("Installed"), value: Text(app.pinnedVersion.map { "v\($0)" } ?? String(localized: "Follows live version")))
            openInstalled
            Button { removing = true } label: { SettingsRow(Text("Uninstall app"), role: .destructive) }.buttonStyle(SurfaceRowButtonStyle())
        } else if let failure = model.installationFailure {
            InlineError(message: failure) { installationRead += 1 }.surfaceRowFrame()
        } else if model.workspaceID != nil, !model.installationKnown {
            ProgressView("Checking installation…").surfaceRowFrame()
        } else if model.workspaceID != nil {
            SettingsToggle(title: Text("Follow live version"), isOn: $model.followLive)
            Button { Task { await model.install() } } label: {
                SettingsRow(Text(model.followLive ? "Install app" : "Install v\(model.version ?? 0)"), role: .action)
            }.buttonStyle(SurfaceRowButtonStyle()).disabled(!model.canInstall)
        }
    }

    private var openInstalled: some View {
        Button { preview = model.installedTarget() } label: {
            SettingsRow(Text(model.installedTarget().flatMap { store.retainedMiniApp(for: $0) }?.isSuspended == true ? "Continue" : "Open workspace app"), role: .action) { SettingsChevron() }
        }.buttonStyle(SurfaceRowButtonStyle())
    }
}
