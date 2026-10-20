import Foundation
import Observation
import CommaCore

/// The workspace's skills, which the composer's / menu lists and a send tags in its `skills` field.
/// The catalog is read when the composer focuses, a / menu opens or a restored draft names a skill, and is kept
/// for five minutes, as on the desktop. A failed read is not kept: the last good catalog stays, nothing is
/// reported, and the next read tries again. A restricted session's refusal settles as an empty catalog until the
/// workspace or session changes, so it is not asked again on every focus.
@MainActor @Observable
final class SkillsModel {
    private(set) var catalog: [Skill] = []
    /// True while the first read is in flight, so the menu shows that it is searching instead of nothing.
    private(set) var loading = false

    @ObservationIgnored private var workspaceID: String?
    @ObservationIgnored private var loadedAt: ContinuousClock.Instant?
    @ObservationIgnored private var refused = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    /// The desktop catalog's lifetime.
    static let freshness: Duration = .seconds(300)

    /// Drops the catalog of a previous workspace or session.
    func reset() {
        revision += 1
        catalog = []; loading = false; workspaceID = nil; loadedAt = nil; refused = false; inFlight = nil
    }

    /// Reads the catalog unless one read within `maxAge` is kept. A caller that arrives while a read is in flight
    /// waits for that read instead of starting another.
    func loadIfStale(store: CommaStore, maxAge: Duration = freshness) async {
        guard let workspace = store.workspace else { return }
        if workspaceID != workspace.id { reset(); workspaceID = workspace.id }
        if let running = inFlight { await running.value; return }
        if refused { return }
        if let loadedAt, loadedAt.duration(to: .now) < maxAge { return }
        let read = Task { await load(workspace, store: store) }
        inFlight = read
        await read.value
    }

    private func load(_ workspace: Workspace, store: CommaStore) async {
        let token = revision, boundary = store.boundaryToken
        loading = catalog.isEmpty
        defer { if revision == token { loading = false; inFlight = nil } }
        do {
            let next = try await store.client.skills(workspace: workspace)
            guard revision == token, store.isCurrent(boundary) else { return }
            if catalog != next { catalog = next }
            loadedAt = .now
        } catch CommaError.http(403, _, _) {
            guard revision == token, store.isCurrent(boundary) else { return }
            catalog = []
            refused = true
        } catch {
            // Unavailable, offline or cancelled: kept for no one, so the next focus or / menu reads again.
        }
    }
}
