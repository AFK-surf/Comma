import Foundation
import Observation
import UIKit
import UserNotifications

extension CommaStore {
    func retainedMiniApp(for target: MiniAppTarget) -> MiniAppSession? {
        guard let session = miniAppSessions[target.runtimeKey], session.canContinue,
              session.target?.shareToken == target.shareToken,
              target.version == nil || target.version == session.version else { return nil }
        return session
    }

    func canContinueMiniApp(workspaceID: String, appID: String) -> Bool {
        miniAppSessions[workspaceID + "/" + appID]?.target?.shareToken == nil
            && miniAppSessions[workspaceID + "/" + appID]?.isSuspended == true
            && miniAppSessions[workspaceID + "/" + appID]?.canContinue == true
    }

    func retainMiniApp(_ session: MiniAppSession, target: MiniAppTarget) {
        if let previous = miniAppSessions[target.runtimeKey], previous !== session { previous.stop() }
        miniAppSessions[target.runtimeKey] = session
        if miniAppMemoryObserver == nil {
            miniAppMemoryObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.releaseSuspendedMiniApps() } }
        }
    }

    func closeMiniApp(_ session: MiniAppSession, target: MiniAppTarget) {
        if miniAppSessions[target.runtimeKey] === session { miniAppSessions.removeValue(forKey: target.runtimeKey) }
        session.stop()
        stopObservingMemoryIfEmpty()
    }

    func closeMiniApps() {
        let sessions = Array(miniAppSessions.values)
        miniAppSessions.removeAll()
        for session in sessions { session.stop() }
        stopObservingMemoryIfEmpty()
    }

    func releaseSuspendedMiniApps() {
        let suspended = miniAppSessions.filter { $0.value.isSuspended }
        for (key, session) in suspended {
            miniAppSessions.removeValue(forKey: key)
            session.failed(CoreError(code: "unavailable", message: "This app was released to free memory. Reload it to continue."))
        }
        stopObservingMemoryIfEmpty()
    }

    private func stopObservingMemoryIfEmpty() {
        if miniAppSessions.isEmpty, let observer = miniAppMemoryObserver {
            NotificationCenter.default.removeObserver(observer)
            miniAppMemoryObserver = nil
        }
    }

    /// Run links use the active deployment's web origin. This phase opens only the current Workspace.
    func openMiniApp(_ url: URL) -> Bool {
        if let link = MiniAppSharedLink(url: url, apiOrigin: configuration.baseURL) {
            guard session != nil else { return false }
            miniAppPresentation = .shared(link)
            return true
        }
        if MiniAppSharedLink.isClaimed(url) {
            error = String(localized: "This app link is invalid or belongs to another Comma environment.")
            return true
        }
        guard let target = MiniAppTarget(url: url, apiOrigin: configuration.baseURL) else { return false }
        guard session != nil, workspace?.id == target.workspaceID else {
            error = String(localized: "Switch to the app’s workspace before opening it.")
            return true
        }
        miniAppTarget = target
        return true
    }
}

/// A route selects an app. The Core session supplies authority for every app operation.
struct MiniAppTarget: Identifiable, Equatable {
    let workspaceID: String
    let appID: String
    var version: Int?
    var publication: MiniAppPublication?
    var shareToken: String?
    var runtimeKey: String { workspaceID + "/" + appID }
    var id: String { workspaceID + "/" + appID + "/" + (shareToken ?? "workspace") + "/" + (version.map(String.init) ?? "live") }

    /// A Router run link selects a Workspace app. Public links use MiniAppSharedLink instead.
    init?(url: URL, apiOrigin: URL) {
        guard let host = MiniAppSharedLink.webHost(apiOrigin: apiOrigin), url.scheme == "https", url.host == host, url.port == nil,
              url.user == nil, url.password == nil, url.path == "/",
              let fragment = url.fragment,
              let route = URLComponents(string: "https://route.invalid" + fragment) else { return nil }
        let parts = route.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5 || (parts.count == 6 && parts[5].isEmpty),
              parts[0].isEmpty, parts[1] == "apps", parts[4] == "run" else { return nil }
        self.init(parts: parts, query: route.queryItems)
    }

    private init?(parts: [Substring], query: [URLQueryItem]?) {
        guard let workspace = String(parts[2]).removingPercentEncoding,
              let app = String(parts[3]).removingPercentEncoding,
              [workspace, app].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !$0.contains("/") && !$0.contains("\\") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { return nil }
        let versions = (query ?? []).filter { $0.name == "version" }
        guard versions.count <= 1 else { return nil }
        let version = versions.first?.value.flatMap(Int.init)
        guard versions.isEmpty || (version ?? 0) > 0 else { return nil }
        self.init(workspaceID: workspace, appID: app, version: version)
    }

    init(workspaceID: String, appID: String, version: Int? = nil, publication: MiniAppPublication? = nil, shareToken: String? = nil) {
        self.workspaceID = workspaceID
        self.appID = appID
        self.version = version
        self.publication = publication
        self.shareToken = shareToken
    }
}

/// An owned native runtime, retained across presentations without exposing WebKit to session authority.
@MainActor protocol MiniAppRuntimeHandle: AnyObject {
    func stop()
    func suspend()
    func resume()
}

/// One in-memory execution. Core authorizes operations. The host confirms each photo delivery.
@MainActor @Observable
final class MiniAppSession {
    private let core: any CoreAPI
    private var session: String?
    private var generation = 0
    private var photoEpoch = 0
    private(set) var hostRequest: MiniAppHostRequest?
    @ObservationIgnored private var hostReply: CheckedContinuation<Bool, Never>?
    @ObservationIgnored var draftHandler: ((String) throws -> Void)?
    private var approved = false
    private var opened = false
    private(set) var target: MiniAppTarget?
    private(set) var isSuspended = false
    var immersive = true
    private(set) var photoRequest: MiniAppPhotoRequest?
    @ObservationIgnored private var photoReply: CheckedContinuation<[MiniAppPhotoAsset], Error>?

    @ObservationIgnored var runtime: (any MiniAppRuntimeHandle)? {
        didSet { if isSuspended { runtime?.suspend() } }
    }
    private(set) var info: CoreJSON?
    private(set) var failure: String?
    private(set) var ready = false
    var needsConsent = false

    init(core: any CoreAPI, target: MiniAppTarget? = nil) { self.core = core; self.target = target }

    var canContinue: Bool { canRun && failure == nil }
    func suspend() { photoEpoch += 1; cancelHostRequest(); cancelPhotoRequest(); isSuspended = canContinue; if isSuspended { runtime?.suspend() } }
    func resume() { isSuspended = false; runtime?.resume() }

    var name: String { info?.object?.object("app")?.string("name") ?? String(localized: "App") }
    var version: Int? { info?.object?.int("version") }
    var canRun: Bool { approved && session != nil }

    func open(_ target: MiniAppTarget) async {
        guard !opened else { return }
        opened = true; self.target = target; failure = nil
        let current = generation
        do {
            let via = target.shareToken.map { ["token": $0] } ?? ["workspace": target.workspaceID]
            var params: [String: Any] = ["app": target.appID, "via": via, "platform": "ios"]
            if target.shareToken == nil, let version = target.version { params["version"] = version }
            let opened = try await core.object("miniApps.session.open", params)
            guard let id = opened.string("session") else { throw CoreError(code: "invalid", message: "The app has no session.") }
            guard current == generation, !Task.isCancelled else {
                _ = try? await core.call("miniApps.session.close", ["session": id])
                return
            }
            session = id
            info = CoreJSON(value: opened)
            needsConsent = true
        } catch { if current == generation && !Task.isCancelled { failure = error.localizedDescription } }
    }

    /// The host's Run button approves cloud access for this run. App messages cannot approve it.
    func approve() { if session != nil { approved = true; needsConsent = false } }

    func bundle() async throws -> NSDictionary {
        guard approved, let session else { throw CoreError(code: "denied", message: "Cloud access was not approved.") }
        let current = generation
        let bundle = try await core.object("miniApps.bundle", ["session": session])
        guard current == generation, !Task.isCancelled else { throw CancellationError() }
        return bundle
    }

    func initialization(dark: Bool, tokens: [String: String] = [:]) -> [String: Any] {
        let info = info?.object
        let app = info?.object("app")
        return ["app": ["id": app?.string("id") ?? "", "name": name, "version": version ?? 0],
                "viewer": (info?.strings("grants").contains("identity.basic") == true ? info?["viewer"] : nil) ?? NSNull(), "theme": dark ? "dark" : "light", "tokens": tokens,
                "locale": Locale.preferredLanguages.first ?? "en", "timeZone": TimeZone.current.identifier, "capabilities": info?.strings("capabilities") ?? [],
                "grants": info?.strings("grants") ?? [], "storage": info?.strings("storage") ?? [],
                "backend": info?.bool("backend") ?? false]
    }

    func invoke(_ request: NSDictionary) async -> [String: Any] {
        guard approved, let session else { return Self.error("denied", "The app is not running.") }
        guard let op = request.string("op"), Self.permits(op) else { return Self.error("unsupported", "This operation is not available on iOS.") }
        let current = generation
        let epoch = photoEpoch
        guard !isSuspended else { return Self.error("unavailable", "The app is not in the foreground.") }
        do {
            let params: [String: Any] = ["session": session, "op": op, "args": request["args"] ?? [:]]
            var answer = try await core.object("miniApps.invoke", params)
            guard current == generation, !Task.isCancelled else { return Self.error("unavailable", "The app closed.") }
            if answer.string("status") == "grant" {
                guard let capability = answer.string("capability"), ["ai.chat", "web.search", "identity.basic", "drive.app_folder", "notifications"].contains(capability) else {
                    return Self.error("unsupported", "This capability is not available on iOS.")
                }
                if !["ai.chat", "web.search"].contains(capability) {
                    guard await requestHostPermission(op: capability, args: [:]), current == generation, epoch == photoEpoch, !isSuspended else { return Self.error("denied", "The request was cancelled.") }
                }
                _ = try await core.call("miniApps.grant", ["session": session, "capability": capability])
                guard current == generation, !Task.isCancelled else { return Self.error("unavailable", "The app closed.") }
                answer = try await core.object("miniApps.invoke", params)
            }
            guard current == generation, !Task.isCancelled else { return Self.error("unavailable", "The app closed.") }
            if op != "files.pick", answer.string("status") == "confirm" {
                guard await requestHostPermission(op: op, args: request["args"] as? NSDictionary ?? [:]), current == generation, epoch == photoEpoch, !isSuspended else { return Self.error("denied", "The request was cancelled.") }
                var confirmed = params; confirmed["confirmed"] = true
                answer = try await core.object("miniApps.invoke", confirmed)
            }
            if op == "files.pick", answer.string("status") == "confirm" {
                guard epoch == photoEpoch, !isSuspended else { return Self.error("unavailable", "The app left the foreground.") }
                let args = request["args"] as? NSDictionary ?? [:]
                let assets = try await requestPhotos(args)
                guard current == generation, epoch == photoEpoch, !isSuspended, !Task.isCancelled else { return Self.error("unavailable", "The app left the foreground.") }
                if assets.isEmpty { return ["ok": true, "value": []] }
                var confirmed = params
                confirmed["confirmed"] = true
                answer = try await core.object("miniApps.invoke", confirmed)
                guard current == generation, epoch == photoEpoch, !isSuspended, !Task.isCancelled else { return Self.error("unavailable", "The app left the foreground.") }
                if answer.string("status") == "host" {
                    return ["ok": true, "value": assets.enumerated().map { index, asset in
                        ["name": "photo-\(index + 1)." + (asset.png ? "png" : "jpg"),
                         "mime": asset.png ? "image/png" : "image/jpeg", "data": ["$bytes": asset.data.base64EncodedString()]] as [String: Any]
                    }]
                }
            }
            if answer.string("status") == "host" {
                // Only the device side effect waits for the foreground; a call the server already completed reports its result.
                guard current == generation, epoch == photoEpoch, !isSuspended else { return Self.error("unavailable", "The app left the foreground.") }
                let args = answer.object("args") ?? request["args"] as? NSDictionary ?? [:]
                switch op {
                case "chat.draft":
                    guard let text = args.string("text"), let draftHandler else { return Self.error("unavailable", "Open a chat first.") }
                    try draftHandler(text)
                    return ["ok": true, "value": NSNull()]
                case "clipboard.write":
                    guard let text = args.text("text") else { return Self.error("invalid", "Text is required.") }
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(120)])
                    return ["ok": true, "value": NSNull()]
                case "links.open":
                    guard let text = args.string("url"), let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil else { return Self.error("invalid", "Only HTTPS links open.") }
                    let opened = await UIApplication.shared.open(url)
                    return ["ok": true, "value": ["opened": opened]]
                case "notify":
                    let center = UNUserNotificationCenter.current()
                    guard try await center.requestAuthorization(options: [.alert, .sound]) else { return Self.error("denied", "Notifications are disabled.") }
                    guard current == generation, epoch == photoEpoch, !isSuspended else { return Self.error("unavailable", "The app left the foreground.") }
                    let content = UNMutableNotificationContent(); content.title = args.string("title") ?? name; content.body = args.text("body") ?? ""
                    try await center.add(UNNotificationRequest(identifier: "mini-app-" + UUID().uuidString, content: content, trigger: nil))
                    return ["ok": true, "value": NSNull()]
                default: return Self.error("unsupported", "This host operation is unavailable.")
                }
            }
            if answer.string("status") == "done" { return ["ok": true, "value": answer["value"] ?? NSNull()] }
            return Self.error(answer.string("code") ?? "unsupported", answer.string("message") ?? "The app call was refused.")
        } catch { return Self.error((error as? CoreError)?.code ?? "unavailable", "The app call failed.") }
    }

    private func requestPhotos(_ args: NSDictionary) async throws -> [MiniAppPhotoAsset] {
        guard photoRequest == nil, hostRequest == nil else { throw CoreError(code: "rate_limited", message: "Finish the current photo request first.") }
        let request = try MiniAppPhotoRequest(args: args)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reply in
                guard !Task.isCancelled else { reply.resume(throwing: CancellationError()); return }
                photoReply = reply
                photoRequest = request
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPhotoRequest(id: request.id) }
        }
    }

    func finishPhotoRequest(id: UUID, assets: [MiniAppPhotoAsset]) {
        guard let request = photoRequest, request.id == id, !isSuspended else { return }
        guard assets.count <= (request.multiple ? 6 : 1),
              assets.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 4 * 1024 * 1024 && $0.png == request.png }),
              assets.reduce(0, { $0 + $1.data.count }) <= 8 * 1024 * 1024 else {
            let reply = photoReply
            photoReply = nil; photoRequest = nil
            reply?.resume(throwing: CoreError(code: "quota_exceeded", message: "The photo selection is too large."))
            return
        }
        let reply = photoReply
        photoReply = nil; photoRequest = nil
        reply?.resume(returning: assets)
    }

    func cancelPhotoRequest(id: UUID? = nil) {
        guard id == nil || id == photoRequest?.id else { return }
        let reply = photoReply
        photoReply = nil; photoRequest = nil
        reply?.resume(returning: [])
    }

    static func permits(_ op: String) -> Bool {
        if ["ai.chat", "ai.decide", "web.search", "backend.fetch", "files.pick", "viewer", "chat.draft", "clipboard.write", "links.open", "tasks.propose", "drive.list", "drive.read", "drive.write", "drive.delete", "notify"].contains(op) { return true }
        let parts = op.split(separator: ".")
        return parts.count == 3 && parts[0] == "storage" && ["user", "app"].contains(parts[1]) &&
            ["get", "put", "delete", "list"].contains(parts[2])
    }

    private func requestHostPermission(op: String, args: NSDictionary) async -> Bool {
        guard hostRequest == nil, photoRequest == nil, !isSuspended else { return false }
        let request = MiniAppHostRequest(op: op, detail: String((args.string("text") ?? args.string("url") ?? "").prefix(4000)))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { reply in
                guard !Task.isCancelled else { reply.resume(returning: false); return }
                hostReply = reply; hostRequest = request
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finishHostRequest(id: request.id, approved: false) } }
    }

    func finishHostRequest(id: UUID, approved: Bool) {
        guard hostRequest?.id == id else { return }
        let reply = hostReply; hostReply = nil; hostRequest = nil
        reply?.resume(returning: approved && !isSuspended)
    }
    func cancelHostRequest() { if let id = hostRequest?.id { finishHostRequest(id: id, approved: false) } }

    func started() { if approved { ready = true } }
    func failed(_ error: Error) { failure = error.localizedDescription; stop() }

    func stop() {
        cancelHostRequest()
        cancelPhotoRequest()
        draftHandler = nil
        let previousRuntime = runtime
        runtime = nil
        opened = false
        isSuspended = false
        generation += 1
        approved = false
        needsConsent = false
        ready = false
        let id = session
        session = nil
        if let id { Task { _ = try? await core.call("miniApps.session.close", ["session": id]) } }
        previousRuntime?.stop()
    }

    private static func error(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": ["code": code, "message": message]]
    }
}

/// One host-owned photo selection. It holds no platform permission or library identifier.
struct MiniAppPhotoRequest: Identifiable {
    let id = UUID()
    let multiple: Bool
    let png: Bool
    init(args: NSDictionary) throws {
        let accept = args["accept"] as? [String] ?? ["image/*"]
        let jpeg = accept.isEmpty || accept.contains { ["image/*", "*/*", "image/jpeg", ".jpg", ".jpeg"].contains($0.lowercased()) }
        let png = accept.contains { ["image/*", "*/*", "image/png", ".png"].contains($0.lowercased()) }
        guard jpeg || png else { throw CoreError(code: "unsupported", message: "This device can select JPEG and PNG photos.") }
        self.png = !jpeg && png
        multiple = args["multiple"] as? Bool ?? false
    }
}

struct MiniAppPhotoAsset: Sendable {
    let data: Data
    let png: Bool
}

struct MiniAppHostRequest: Identifiable {
    let id = UUID()
    let op: String
    let detail: String
    var title: String {
        switch op {
        case "tasks.propose": String(localized: "Create this task?")
        case "links.open": String(localized: "Open this link?")
        case "identity.basic": String(localized: "Share your name and avatar?")
        case "drive.app_folder": String(localized: "Allow access to this app’s Drive folder?")
        case "notifications": String(localized: "Allow this app to send notifications?")
        default: String(localized: "Allow this app action?")
        }
    }
}
