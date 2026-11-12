import CommaCore
import Foundation
import Observation

/// UI projections of the existing Mini App and Version contracts. The server owns publication and authorization.
struct MiniAppRecord: Identifiable, Equatable, Sendable {
    let id: String
    let workspaceID: String
    let name: String
    let summary: String
    let iconURL: String?
    /// The shown Version's cover, for gallery cards; screenshots show on its details page.
    let coverURL: String?
    let screenshotURLs: [String]
    let visibility: String
    let status: String
    let liveVersion: Int?
    let latestVersion: Int?
    let installed: Bool
    let pinnedVersion: Int?
    let author: String
    var runningVersion: Int? { installed ? pinnedVersion ?? liveVersion : liveVersion ?? latestVersion }

    init?(_ json: NSDictionary) {
        guard let id = json.string("id"), let workspace = json.string("workspace_id") else { return nil }
        self.id = id; workspaceID = workspace
        name = json.string("name") ?? String(localized: "App")
        summary = json.string("description") ?? ""
        iconURL = json.string("icon_url")
        coverURL = json.string("cover_url")
        screenshotURLs = Array((json["screenshot_urls"] as? [String] ?? []).prefix(6))
        visibility = json.string("visibility") ?? "private"
        status = json.string("status") ?? "disabled"
        liveVersion = json.int("live_version")
        latestVersion = json.int("latest_version")
        installed = json.bool("installed")
        pinnedVersion = json.object("install")?.int("pinned_version")
        author = json.object("author")?.string("name") ?? ""
    }
}

struct MiniAppVersionRecord: Identifiable, Equatable, Sendable {
    let number: Int
    let state: String
    let live: Bool
    let commit: String?
    let notes: String
    let conversationID: String?
    var id: Int { number }

    init?(_ json: NSDictionary) {
        guard let number = json.int("number"), number > 0 else { return nil }
        self.number = number; state = json.string("state") ?? "failed"
        live = json.bool("live"); commit = json.string("commit")
        notes = json.string("notes") ?? ""; conversationID = json.string("conversation_id")
    }
}

struct MiniAppPublication: Equatable, Sendable {
    let appID: String
    let version: Int
    let conversationID: String
    let reviewVersion: Int
}

/// One management surface. It follows one list or app, and at most one selected build Task. It adds no polling.
@MainActor @Observable
final class MiniAppsModel {
    let workspace: Workspace
    private weak var store: CommaStore?
    private let boundary: Int
    private(set) var apps: [MiniAppRecord] = []
    private(set) var app: MiniAppRecord?
    private(set) var versions: [MiniAppVersionRecord] = []
    private(set) var loaded = false
    private(set) var missing = false
    private(set) var busy = false
    private(set) var review: CoreJSON?
    private(set) var linkURL: String?
    var failure: String?

    init(store: CommaStore, workspace: Workspace) {
        self.store = store; self.workspace = workspace; boundary = store.boundaryToken
    }

    var current: Bool { store?.session != nil && store?.boundaryToken == boundary && store?.workspace?.id == workspace.id }
    var owner: Bool { app?.workspaceID == workspace.id }

    func followList() async {
        guard let core = store?.core, current else { return }
        for await value in core.subscribe(["topic": "miniApps", "workspace": workspace.id], read: { CoreJSON(value: $0) }) {
            guard current, !Task.isCancelled else { return }
            switch value {
            case .value(let next):
                guard let json = next.object else { continue }
                apps = json.objects("apps").compactMap(MiniAppRecord.init)
                loaded = json.string("status") != "loading"
                failure = json.string("status") == "failed" ? String(localized: "Apps could not load. Try again.") : nil
            case .failed(let error): loaded = true; failure = error.localizedDescription
            }
        }
    }

    func followApp(_ id: String) async {
        guard let core = store?.core, current else { return }
        loaded = false; app = nil; versions = []; review = nil; linkURL = nil; missing = false; failure = nil
        for await value in core.subscribe(["topic": "miniApp", "workspace": workspace.id, "app": id], read: { CoreJSON(value: $0) }) {
            guard current, !Task.isCancelled else { return }
            switch value {
            case .value(let next):
                guard let json = next.object else { continue }
                app = json.object("app").flatMap(MiniAppRecord.init)
                linkURL = json.object("link")?.string("url")
                versions = json.objects("versions").compactMap(MiniAppVersionRecord.init)
                loaded = json.string("status") != "loading"; missing = json.string("status") == "missing"
                failure = json.string("status") == "failed" ? String(localized: "The app could not load. Try again.") : nil
            case .failed(let error): loaded = true; failure = error.localizedDescription
            }
        }
    }

    func followReview(_ conversationID: String?) async {
        review = nil
        guard let conversationID, let core = store?.core, current, owner else { return }
        let topic: [String: Any] = ["topic": "chatView", "workspace": workspace.id, "group": workspace.groupID,
                                    "conversation": conversationID, "surface": "ios-mini-app-review"]
        for await value in core.subscribe(topic, read: { CoreJSON(value: ($0 as? NSDictionary)?.object("state")?.object("conversation")) }) {
            guard current, !Task.isCancelled else { return }
            if case .value(let next) = value { review = next }
            else { review = nil }
        }
    }

    func publication(for version: MiniAppVersionRecord) -> MiniAppPublication? {
        guard current, owner, let app, app.status == "active", app.liveVersion != version.number, version.state == "ready", !version.live,
              let conversation = version.conversationID, let task = review?.object,
              task.string("id") == conversation, task.string("kind") == "agent_task",
              ["ready_for_review", "completed"].contains(task.string("status") ?? ""),
              let reviewVersion = task.int("review_version"), reviewVersion > 0 else { return nil }
        return MiniAppPublication(appID: app.id, version: version.number, conversationID: conversation, reviewVersion: reviewVersion)
    }

    @discardableResult
    func publish(_ publication: MiniAppPublication, visibility: String) async -> Bool {
        guard let version = versions.first(where: { $0.number == publication.version }),
              self.publication(for: version) == publication else {
            failure = String(localized: "The Task changed. Open its latest preview before publishing.")
            return false
        }
        return await perform("miniApps.publish", ["app": publication.appID, "version": publication.version,
                                                  "group": workspace.groupID, "conversation": publication.conversationID,
                                                  "reviewVersion": publication.reviewVersion, "visibility": visibility])
    }

    @discardableResult
    func perform(_ operation: String, _ params: [String: Any] = [:]) async -> Bool {
        guard current, !busy, let core = store?.core else { return false }
        busy = true; failure = nil
        defer { busy = false }
        do {
            var params = params; params["workspace"] = workspace.id
            _ = try await core.call(operation, params)
            if current, ["miniApps.uninstall", "miniApps.disable", "miniApps.delete"].contains(operation),
               let appID = params["app"] as? String,
               let session = store?.miniAppSessions[workspace.id + "/" + appID], let target = session.target {
                store?.closeMiniApp(session, target: target)
            }
            return current
        } catch {
            if current, !Task.isCancelled { failure = error.localizedDescription }
            return false
        }
    }
}
