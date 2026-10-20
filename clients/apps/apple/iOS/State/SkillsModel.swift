import CommaCore
import Foundation
import Observation

/// The workspace's skills, which the composer's / menu lists and a send tags in its `skills` field: the core's
/// `skills` topic (kept on the device; read again when shown if older than five minutes).
@MainActor @Observable
final class SkillsModel {
    private(set) var catalog: [Skill] = []
    /// True while the first read is in flight, so the menu shows that it is searching instead of nothing.
    private(set) var loading = false

    @ObservationIgnored private var workspaceID: String?
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var first: [CheckedContinuation<Void, Never>] = []

    /// Drops the catalog of a previous workspace or session.
    func reset() {
        following?.cancel(); following = nil
        catalog = []; loading = false; workspaceID = nil
        settle()
    }

    /// Follows the Workspace's catalog; returns once it has been read (or could not be).
    func loadIfStale(store: CommaStore) async {
        guard let workspace = store.workspace else { return }
        guard workspaceID != workspace.id || following == nil else {
            if loading { await withCheckedContinuation { first.append($0) } }
            return
        }
        following?.cancel()
        workspaceID = workspace.id
        loading = catalog.isEmpty
        let updates = store.core.subscribe(["topic": "skills", "workspace": workspace.id]) { value -> [Skill]? in
            let json = value as? NSDictionary
            guard json?.string("status") != "loading" else { return nil }
            return CoreJSON(value: json?.array("skills")).decode([Skill].self) ?? []
        }
        following = Task { [weak self] in
            for await value in updates {
                guard let self, self.workspaceID == workspace.id else { return }
                switch value {
                case .value(let next?):
                    if self.catalog != next { self.catalog = next }
                    self.loading = false
                    self.settle()
                case .value: continue
                case .failed:
                    self.loading = false
                    self.settle()
                }
            }
        }
        await withCheckedContinuation { first.append($0) }
    }

    private func settle() {
        let waiting = first
        first = []
        for waiter in waiting { waiter.resume() }
    }
}
