import Foundation
import Observation
import CommaCore

/// The workspace's Routines briefing, shared by the sidebar strip and the full Routines sheet.
/// Reads happen when a Routines surface appears and on explicit refresh. While the server reports a
/// run in progress, a visible surface polls every two seconds; 45 consecutive failed polls (90 seconds)
/// stop polling, as on the desktop. Nothing polls while no Routines surface is visible.
@MainActor @Observable
final class RoutinesModel {
    enum Failure: Equatable { case unavailable, rateLimited }

    private(set) var feed: RecommendationFeed?
    private(set) var failure: Failure?
    private(set) var requestingRefresh = false
    private(set) var loading = false

    @ObservationIgnored private var workspaceID: String?
    @ObservationIgnored private var revision = 0

    static let pollInterval: Duration = .seconds(2)
    static let maxConsecutivePollFailures = 45

    var isRefreshing: Bool { requestingRefresh || (feed?.isRefreshing == true && failure != .unavailable) }

    /// Drops the briefing of a previous workspace or session.
    func reset() {
        revision += 1
        feed = nil; failure = nil; requestingRefresh = false; loading = false; workspaceID = nil
    }

    @discardableResult
    func load(store: CommaStore) async -> Bool {
        guard let workspace = store.workspace else { return false }
        if workspaceID != workspace.id { reset(); workspaceID = workspace.id }
        let token = revision, boundary = store.boundaryToken
        loading = feed == nil
        defer { if revision == token { loading = false } }
        do {
            let next = try await store.client.recommendations(workspace: workspace)
            guard revision == token, store.isCurrent(boundary) else { return false }
            feed = next
            if failure == .unavailable { failure = nil }
            return true
        } catch {
            guard revision == token, store.isCurrent(boundary) else { return false }
            if !Self.isCancellation(error) { failure = .unavailable }
            return false
        }
    }

    /// An explicit request for a new briefing. The hourly budget refusal is the one failure reported to the member.
    func refresh(store: CommaStore) async {
        guard let workspace = store.workspace, !isRefreshing else { return }
        if workspaceID != workspace.id { reset(); workspaceID = workspace.id }
        let token = revision, boundary = store.boundaryToken
        requestingRefresh = true
        failure = nil
        defer { if revision == token { requestingRefresh = false } }
        do {
            let next = try await store.client.refreshRecommendations(workspace: workspace)
            guard revision == token, store.isCurrent(boundary) else { return }
            feed = next
        } catch {
            guard revision == token, store.isCurrent(boundary), !Self.isCancellation(error) else { return }
            if case CommaError.http(429, _, _) = error {
                failure = .rateLimited
                await load(store: store)
            } else if await load(store: store), feed?.canRefresh == false {
                // Nothing to generate from; the empty state already says so.
            } else {
                failure = .unavailable
            }
        }
    }

    /// Runs while a Routines surface is visible and the server reports a run: polls until the run ends.
    func follow(store: CommaStore) async {
        var failures = 0
        while !Task.isCancelled, feed?.isRefreshing == true, failures < Self.maxConsecutivePollFailures {
            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled else { return }
            failures = await load(store: store) ? 0 : failures + 1
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? CommaError) == .cancelled || (error as? CommaError) == .staleSession
    }
}
