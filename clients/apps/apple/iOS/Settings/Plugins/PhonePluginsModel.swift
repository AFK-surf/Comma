import Foundation
import Observation
import CommaCore

struct PhonePlugin: Identifiable, Sendable {
    /// Google Colab: its accounts run Colab VMs, which removing the plugin stops first.
    static let colab = "google-colab"
    /// Monoid (`still.fail`): connects workspaces via stations and supports proactive notifications.
    static let stillfail = "stillfail"

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
    let credentialFormat: String?
    let helpURL: URL?
    let toolGroups: Bool
    let stations: Bool
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
        credentialFormat = setup?.string("format")
        helpURL = setup?.string("helpUrl").flatMap(URL.init(string:))
        toolGroups = json.bool("toolGroups")
        stations = json.bool("stations") || id == Self.stillfail
        tools = json.objects("mcps").compactMap { $0.string("name") }
        skills = json.objects("skills").compactMap { $0.string("name") }
    }

    var working: Bool { ["installing", "verifying", "reauthorizing", "uninstalling"].contains(activity) }
    var authorizing: Bool { activity == "authorizing" }
    /// Whether connecting requires the member to enter a secret value (a `show` setup only displays a connect line).
    var requiresCredentialInput: Bool { credentialKey != nil && credentialFormat != "show" }
}

/// The credential form an install or reconnect asks for, as the core's `configure` notice says it: the value to fill
/// in, where to get it, and the attempt and connection it completes. A Google sign-in (`oauth_code`) gives a code to
/// paste back; a `show` setup displays a one-time connect line to copy; a new notice for the same plugin replaces the
/// form (a fresh sign-in link, or why the last code failed).
struct PhonePluginConfiguration: Equatable, Sendable {
    enum Operation: String, Sendable { case install, reauthorize }

    let plugin: String
    let operation: Operation
    let connectionID: String?
    /// The connected account a reconnect is for; the connection alone names it when absent.
    let bindingID: String?
    let key: String
    let label: String?
    /// Where the value comes from: the sign-in page for `oauth_code` (always https).
    let helpURL: URL?
    let format: String?
    /// The one-time connect line shown when `format == "show"`.
    let value: String?
    /// The sign-in attempt the pasted code belongs to.
    let attemptID: String?
    /// Why the last code did not connect, in the server's words.
    let error: String?

    /// The person signs in with Google and pastes the code the page shows.
    var oauthCode: Bool { format == "oauth_code" }
    /// The server returned a one-time connect line to copy into Monoid.
    var showsValue: Bool { format == "show" }

    /// The form of a `configure` notice; nil when it carries none (a core that only names the plugin).
    init?(notice: NSDictionary) {
        guard let plugin = notice.string("plugin"), let configuration = notice.object("configuration"),
              let setup = configuration.object("setup"), let key = setup.string("key") else { return nil }
        self.plugin = plugin
        operation = configuration.string("operation").flatMap(Operation.init(rawValue:)) ?? .install
        connectionID = configuration.string("connectionId")
        bindingID = configuration.string("bindingId")
        self.key = key
        label = setup.string("label")
        helpURL = setup.string("helpUrl").flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        format = setup.string("format")
        value = setup.string("value")
        attemptID = setup.string("attemptId")
        error = setup.string("error")
    }
}

@MainActor @Observable
final class PhonePluginsModel {
    let scope: WorkspaceSettingsScope
    private(set) var plugins: [PhonePlugin] = []
    private(set) var loaded = false
    var authorizationURL: URL?
    var authorizationPlugin: String?
    var configurationPlugin: String?
    /// The form the core asked for last, while it waits to be filled in.
    private(set) var configuration: PhonePluginConfiguration?
    /// Why the value just sent did not connect; the form stays as it was, to correct it in place.
    private(set) var formError: String?
    private let catalogStream = SharedSubscription()
    private let noticesStream = SharedSubscription()

    init(store: CommaStore, workspace: Workspace) { scope = WorkspaceSettingsScope(store: store, workspace: workspace) }

    /// Keeps one catalog subscription alive while either the list or a pushed detail page is shown.
    func follow() async {
        await catalogStream.join { [weak self] in await self?.runFollow() }
    }

    /// Keeps one notices subscription alive while either the list or a pushed detail page is shown.
    func notices() async {
        await noticesStream.join { [weak self] in await self?.runNotices() }
    }

    private func runFollow() async {
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

    private func runNotices() async {
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
            configuration = PhonePluginConfiguration(notice: notice)
            formError = nil
        } else {
            scope.error = notice.string("message") ?? String(localized: "The connection did not finish. Try again.")
        }
    }

    /// The form shown for `plugin`, if the core asked for one.
    func configuration(for plugin: PhonePlugin) -> PhonePluginConfiguration? {
        configuration?.plugin == plugin.id ? configuration : nil
    }

    /// Starts connecting `plugin` (or reconnecting its `connection` and `binding`), or sends the `credential` its form
    /// asked for. Sent, the value goes to the attempt and operation of the form the core asked for last. Returns the
    /// browser authorization link when there is one.
    func install(_ plugin: PhonePlugin, credential: String? = nil, connection: String? = nil, binding: String? = nil) async -> URL? {
        guard scope.current else { return nil }
        let form = credential == nil ? nil : configuration(for: plugin)
        let reauthorize = form.map { $0.operation == .reauthorize } ?? (connection != nil || binding != nil)
        var params: [String: Any] = ["plugin": plugin.id, "origin": "plugins"]
        if let key = form?.key ?? plugin.credentialKey, let credential { params["configValues"] = [key: credential] }
        if let attempt = form?.attemptID { params["attemptId"] = attempt }
        if reauthorize {
            if let connection = form?.connectionID ?? connection { params["connection"] = connection }
            if let binding = form?.bindingID ?? binding { params["bindingId"] = binding }
        }
        // A new start replaces the form; its own `configure` notice may come before this call answers.
        if credential == nil { configuration = nil; configurationPlugin = nil }
        formError = nil
        guard let answer = await scope.perform(reauthorize ? "plugin.reauthorize" : "plugin.install", params) else { return nil }
        if let failure = answer.object?.string("failure") {
            if let form {
                // The server's own words (a code for another Google account, say) say what to do instead.
                let message = answer.object?.string("message")
                formError = message ?? (form.oauthCode && failure == "credential_rejected"
                    ? String(localized: "That code didn’t work. Check that you pasted the whole code, then try again.")
                    : String(localized: "Couldn’t connect this plugin. Check its setup and try again."))
            } else {
                scope.error = String(localized: "Couldn’t connect this plugin. Check its setup and try again.")
            }
            return nil
        }
        let url = answer.object?.string("authorizationUrl").flatMap(URL.init(string:))
        // A form the core replaced while the value was on its way (a fresh sign-in) stays.
        if credential != nil, configuration == form { configuration = nil; configurationPlugin = nil }
        authorizationURL = url; authorizationPlugin = url == nil ? nil : plugin.id
        return url
    }

    /// Puts the form away without sending anything.
    func dismissConfiguration() {
        configuration = nil; configurationPlugin = nil; formError = nil
    }

    func refresh() async {
        _ = await scope.perform("plugins.refresh")
        await checkAuthorization()
    }

    func checkAuthorization() async {
        _ = try? await scope.call("plugin.authorization.check", workspaceParameter: false)
    }

    func cancel(_ plugin: PhonePlugin) async {
        guard scope.current else { return }
        guard await scope.perform("plugin.cancel", ["plugin": plugin.id]) != nil else { return }
        if authorizationPlugin == plugin.id {
            authorizationURL = nil; authorizationPlugin = nil
        }
    }

    func remove(_ plugin: PhonePlugin) async {
        guard scope.current else { return }
        _ = await scope.perform("plugin.uninstall", ["plugin": plugin.id])
    }
}

/// Shares one core topic task across sibling SwiftUI views (such as a list and a pushed detail page),
/// cancelling it only when the last awaiting view disappears.
@MainActor
private final class SharedSubscription {
    private var task: Task<Void, Never>?
    private var taskID: UUID?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func join(_ run: @escaping @MainActor () async -> Void) async {
        if Task.isCancelled { return }
        let id = UUID()
        if task == nil {
            let currentTaskID = UUID()
            taskID = currentTaskID
            task = Task { @MainActor [weak self] in
                await run()
                guard let self, self.taskID == currentTaskID else { return }
                self.task = nil
                self.taskID = nil
                let waiting = self.waiters
                self.waiters.removeAll()
                for continuation in waiting.values { continuation.resume() }
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || task == nil {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let continuation = self.waiters.removeValue(forKey: id) {
                    continuation.resume()
                }
                if self.waiters.isEmpty {
                    self.task?.cancel()
                    self.task = nil
                    self.taskID = nil
                }
            }
        }
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

/// A Monoid (`still.fail`) workspace connected to Comma through one of its stations (core `pluginStations`).
struct PhonePluginStation: Identifiable, Equatable, Sendable {
    let id: String
    let name: String?
    let workspace: String?
    let emoji: String?
    let station: String?
    let stationCount: Int?
    let connected: Bool
    let connectedAt: String?

    init?(_ json: NSDictionary) {
        guard let id = json.string("id") else { return nil }
        self.id = id
        name = json.string("name")
        workspace = json.string("workspace")
        emoji = json.string("emoji")
        station = json.string("station")
        stationCount = json.int("stationCount")
        connected = json.bool("connected")
        connectedAt = json.string("connectedAt")
    }

    var displayName: String { workspace ?? String(localized: "Not connected yet") }
    var isOfflineConnected: Bool { connectedAt != nil && !connected }
}

/// Proactive notification level for connected Monoid chats.
enum StillfailNotificationLevel: String, CaseIterable, Identifiable, Sendable {
    case off
    case actionNeeded = "action_needed"
    case issues
    case all

    var id: String { rawValue }
}

@MainActor @Observable
final class PhonePluginStationsModel {
    let scope: WorkspaceSettingsScope
    let plugin: String
    private(set) var stations: [PhonePluginStation]?
    private(set) var notificationLevel: StillfailNotificationLevel = .actionNeeded
    private(set) var pending: String?
    private(set) var notificationPending = false
    private(set) var error: String?
    /// Local request failure message shown under the workspaces when a disconnect or the subscription fails.
    private(set) var actionError: String?
    /// Local failure message shown under the notification levels when saving one fails.
    private(set) var notificationError: String?

    init(scope: WorkspaceSettingsScope, plugin: String) {
        self.scope = scope
        self.plugin = plugin
    }

    var hasOfflineConnectedStation: Bool {
        (stations ?? []).contains(where: \.isOfflineConnected)
    }

    func follow() async {
        for await value in scope.store.core.subscribe(
            ["topic": "pluginStations", "workspace": scope.workspace.id, "plugin": plugin],
            read: { CoreJSON(value: $0) }
        ) {
            guard scope.current, !Task.isCancelled else { return }
            switch value {
            case .value(let next):
                guard let json = next.object else { continue }
                if let rawStations = json.array("stations") {
                    stations = rawStations.compactMap { ($0 as? NSDictionary).flatMap(PhonePluginStation.init) }
                } else {
                    stations = nil
                }
                notificationLevel = json.string("notificationLevel")
                    .flatMap(StillfailNotificationLevel.init(rawValue:)) ?? .actionNeeded
                pending = json.string("pending")
                notificationPending = json.bool("notificationPending")
                error = json.string("error")
                if error == nil { actionError = nil }
            case .failed(let err):
                actionError = err.localizedDescription
            }
        }
    }

    @discardableResult
    func disconnect(_ station: PhonePluginStation) async -> Bool {
        guard scope.current, pending == nil else { return false }
        actionError = nil
        do {
            _ = try await scope.call("plugin.station.disconnect", ["plugin": plugin, "station": station.id])
            return true
        } catch {
            actionError = station.workspace.map { String(localized: "Couldn’t disconnect \($0). Try again.") }
                ?? String(localized: "Couldn’t disconnect workspace. Try again.")
            return false
        }
    }

    @discardableResult
    func setNotificationLevel(_ level: StillfailNotificationLevel) async -> Bool {
        guard scope.current, !notificationPending, level != notificationLevel else { return false }
        notificationError = nil
        do {
            _ = try await scope.call("plugin.station.notificationLevel.set", ["plugin": plugin, "level": level.rawValue])
            return true
        } catch {
            notificationError = String(localized: "Couldn’t save notification level. Try again.")
            return false
        }
    }
}
