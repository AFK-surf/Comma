import Foundation
import Observation
import CommaCore

struct PhonePlugin: Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let description: String
    let brand: String
    let category: String
    let installed: Bool
    let locked: Bool
    let activity: String
    let credentialKey: String?
    let credentialLabel: String?
    let helpURL: URL?
    let toolGroups: Bool
    let tools: [String]
    let skills: [String]

    init?(_ json: NSDictionary) {
        guard let id = json.string("id"), let name = json.string("name") else { return nil }
        self.id = id; self.name = name
        summary = json.text("summary") ?? ""
        description = json.text("description") ?? summary
        brand = json.string("brand") ?? id
        category = json.string("category") ?? String(localized: "Other")
        installed = json.bool("installed"); locked = json.bool("locked")
        activity = json.string("activity") ?? "idle"
        let setup = json.object("credentialSetup")
        credentialKey = setup?.string("key"); credentialLabel = setup?.string("label")
        helpURL = setup?.string("helpUrl").flatMap(URL.init(string:))
        toolGroups = json.bool("toolGroups")
        tools = json.objects("mcps").compactMap { $0.string("name") }
        skills = json.objects("skills").compactMap { $0.string("name") }
    }

    var working: Bool { ["installing", "verifying", "reauthorizing", "uninstalling"].contains(activity) }
    var authorizing: Bool { activity == "authorizing" }
}

@MainActor @Observable
final class PhonePluginsModel {
    let scope: WorkspaceSettingsScope
    private(set) var plugins: [PhonePlugin] = []
    private(set) var loaded = false
    var authorizationURL: URL?
    var authorizationPlugin: String?
    var configurationPlugin: String?

    init(store: CommaStore, workspace: Workspace) { scope = WorkspaceSettingsScope(store: store, workspace: workspace) }

    func follow() async {
        for await value in scope.store.core.subscribe(["topic": "plugins", "prefer": scope.workspace.id], read: { CoreJSON(value: $0) }) {
            guard scope.current, !Task.isCancelled else { return }
            switch value {
            case .value(let next):
                guard let json = next.object else { continue }
                if json.string("status") == "ready", json.string("workspace") == scope.workspace.id {
                    plugins = json.objects("plugins").compactMap(PhonePlugin.init)
                    loaded = true
                    if let id = authorizationPlugin, let plugin = plugins.first(where: { $0.id == id }), !plugin.authorizing && !plugin.working {
                        authorizationURL = nil; authorizationPlugin = nil
                    }
                } else if json.string("status") == "ready" {
                    loaded = true
                    scope.error = String(localized: "Plugins are unavailable in this workspace.")
                } else if json.string("status") == "error" || json.string("status") == "empty" {
                    loaded = true
                    scope.error = json.object("error")?.string("message") ?? String(localized: "Couldn’t load plugins")
                }
            case .failed(let error): loaded = true; scope.error = error.localizedDescription
            }
        }
    }

    func notices() async {
        for await value in scope.store.core.subscribe(["topic": "pluginNotices"], read: { CoreJSON(value: $0) }) {
            guard scope.current, !Task.isCancelled else { return }
            guard case .value(let next) = value else { continue }
            // The core owns delivery and lets exactly one client claim each notice.
            let notices = next.array?.compactMap { $0 as? NSDictionary } ?? next.object?.objects("notices") ?? []
            for notice in notices { await receiveNotice(CoreJSON(value: notice)) }
        }
    }

    func receiveNotice(_ value: CoreJSON) async {
        guard scope.current, let notice = value.object, notice.string("workspace") == scope.workspace.id,
              let id = notice.int("id"),
              let claimed = try? await scope.call("plugin.notice.claim", ["id": id], workspaceParameter: false),
              claimed.value as? Bool == true, scope.current else { return }
        if notice.string("kind") == "authorize", let url = notice.string("url").flatMap(URL.init(string:)) {
            authorizationURL = url; authorizationPlugin = notice.string("plugin")
        } else if notice.string("kind") == "configure" {
            configurationPlugin = notice.string("plugin")
        } else {
            scope.error = notice.string("message") ?? String(localized: "The connection did not finish. Try again.")
        }
    }

    func install(_ plugin: PhonePlugin, credential: String? = nil, connection: String? = nil) async -> URL? {
        guard scope.current else { return nil }
        var params: [String: Any] = ["plugin": plugin.id, "origin": "plugins"]
        if let key = plugin.credentialKey, let credential { params["configValues"] = [key: credential] }
        if let connection { params["connection"] = connection }
        guard let answer = await scope.perform(connection == nil ? "plugin.install" : "plugin.reauthorize", params) else { return nil }
        if answer.object?.string("failure") != nil {
            scope.error = String(localized: "Couldn’t connect this plugin. Check its setup and try again.")
            return nil
        }
        let url = answer.object?.string("authorizationUrl").flatMap(URL.init(string:))
        configurationPlugin = nil
        authorizationURL = url; authorizationPlugin = url == nil ? nil : plugin.id
        return url
    }

    func refresh() async {
        _ = await scope.perform("plugins.refresh")
        _ = try? await scope.call("plugin.authorization.check", workspaceParameter: false)
    }

    func remove(_ plugin: PhonePlugin) async {
        guard scope.current else { return }
        _ = await scope.perform("plugin.uninstall", ["plugin": plugin.id])
    }
}

@MainActor @Observable
final class PhonePluginSourcesModel {
    let scope: WorkspaceSettingsScope
    let plugin: String
    private(set) var sources: [CoreJSON] = []
    private(set) var groups: [CoreJSON] = []
    private(set) var confirmation: CoreJSON?
    private(set) var pending = false

    init(scope: WorkspaceSettingsScope, plugin: String) { self.scope = scope; self.plugin = plugin }

    func followSources() async {
        for await value in scope.store.core.subscribe(["topic": "pluginSources", "workspace": scope.workspace.id, "plugin": plugin], read: { CoreJSON(value: $0) }) {
            guard scope.current, !Task.isCancelled else { return }
            if case .value(let next) = value, let json = next.object {
                sources = json.objects("sources").map { CoreJSON(value: $0) }
                confirmation = json.object("confirmation").map { CoreJSON(value: $0) }
                pending = json.object("pending") != nil
                if json.string("error") != nil { scope.error = String(localized: "Couldn’t load or update connected accounts") }
            } else if case .failed(let error) = value { scope.error = error.localizedDescription }
        }
    }

    func followGroups() async {
        for await value in scope.store.core.subscribe(["topic": "pluginToolGroups", "workspace": scope.workspace.id, "plugin": plugin], read: { CoreJSON(value: $0) }) {
            guard scope.current, !Task.isCancelled else { return }
            if case .value(let next) = value, let json = next.object {
                groups = json.objects("groups").map { CoreJSON(value: $0) }
                if json.string("error") != nil { scope.error = String(localized: "Couldn’t load or update tools") }
            } else if case .failed(let error) = value { scope.error = error.localizedDescription }
        }
    }

    func run(_ name: String, _ params: [String: Any] = [:]) async {
        var params = params; params["plugin"] = plugin
        _ = await scope.perform(name, params)
    }
}
