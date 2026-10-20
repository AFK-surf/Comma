import CommaCore
import Foundation
import Observation

/// The workspace's Routines briefing, which Home shows as platform cards: the core's `recommendations` topic, which
/// reads it again while a run is under way and when the app comes back.
@MainActor @Observable
final class RoutinesModel {
    enum Failure: Equatable { case unavailable, rateLimited }

    private(set) var feed: RecommendationFeed?
    private(set) var failure: Failure?
    private(set) var requestingRefresh = false
    private(set) var loading = false
    /// Advances when the store drops the briefing (`reset`), so a surface showing the routines follows it again.
    private(set) var resets = 0

    @ObservationIgnored private var workspaceID: String?
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var refreshingInCore = false

    var isRefreshing: Bool { requestingRefresh || refreshingInCore || (feed?.isRefreshing == true && failure != .unavailable) }

    /// Drops the briefing of a previous workspace or session.
    func reset() {
        resets += 1
        following?.cancel(); following = nil
        feed = nil; failure = nil; requestingRefresh = false; loading = false; workspaceID = nil; refreshingInCore = false
    }

    /// Follows the Workspace's briefing while a surface shows it; the core reads it again as it goes stale.
    func reloadIfStale(store: CommaStore) async { await load(store: store) }

    @discardableResult
    func load(store: CommaStore) async -> Bool {
        guard let workspace = store.workspace else { return false }
        if workspaceID != workspace.id || following == nil { follow(workspace, store: store) }
        else { _ = try? await store.core.call("recommendations.visit", ["workspace": workspace.id]) }
        return failure == nil
    }

    private func follow(_ workspace: Workspace, store: CommaStore) {
        following?.cancel()
        workspaceID = workspace.id
        loading = feed == nil
        let updates = store.core.subscribe(["topic": "recommendations", "workspace": workspace.id,
                                            "timezone": TimeZone.current.identifier]) { value in RoutinesValue(value) }
        following = Task { [weak self] in
            for await value in updates {
                guard let self, self.workspaceID == workspace.id else { return }
                self.loading = false
                switch value {
                case .value(let next):
                    if let feed = next.feed { self.feed = feed }
                    self.refreshingInCore = next.refreshing
                    self.failure = next.failure
                case .failed:
                    self.failure = .unavailable
                }
            }
        }
    }

    /// An explicit request for a new briefing. The hourly budget refusal is the one failure reported to the member.
    func refresh(store: CommaStore) async {
        guard let workspace = store.workspace, !isRefreshing else { return }
        if workspaceID != workspace.id || following == nil { follow(workspace, store: store) }
        requestingRefresh = true
        failure = nil
        defer { requestingRefresh = false }
        do {
            let answer = try await store.core.object("recommendations.refresh", ["workspace": workspace.id])
            if answer.bool("rateLimited") { failure = .rateLimited }
        } catch {
            failure = .unavailable
        }
    }

    /// The core follows a run under way by itself while the topic is shown.
    func follow(store: CommaStore) async {}
}

/// The core's `recommendations` value, read into the feed the cards draw.
private struct RoutinesValue: Sendable {
    let feed: RecommendationFeed?
    let failure: RoutinesModel.Failure?
    let refreshing: Bool

    init(_ value: Any?) {
        let json = value as? NSDictionary
        feed = CoreJSON(value: json?.object("envelope")).decode(JSONValue.self).flatMap { try? RecommendationFeed(envelope: $0) }
        failure = switch json?.string("failure") {
        case "unavailable": .unavailable
        case "rate_limited": .rateLimited
        default: nil
        }
        refreshing = json?.bool("refreshing") == true
    }
}
