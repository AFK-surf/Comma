import CommaCore
import Foundation
import Observation

/// A model the workspace can run, which the router chat's @ menu offers to start a Task with.
struct MentionModel: Equatable, Sendable {
    let id: String
    let name: String
    let vendor: String
    /// The thinking efforts it takes; none: it has only its default.
    let efforts: [String]
}

/// The models the router chat's @ menu lists (desktop `useComposerMentionSources`' `models`): the core's `models` topic
/// for the Workspace, the Settings page's read (three requests), followed from the first time that menu opens. Only a
/// model some profile of the Workspace serves is listed.
@MainActor @Observable
final class MentionModelsModel {
    private(set) var catalog: [MentionModel] = []
    /// True until the first read answers, so the menu shows that it is searching instead of nothing.
    private(set) var loading = false

    @ObservationIgnored private var workspaceID: String?
    @ObservationIgnored private var following: Task<Void, Never>?

    /// Drops the models of a previous workspace or session.
    func reset() {
        following?.cancel(); following = nil
        catalog = []; loading = false; workspaceID = nil
    }

    /// Follows the Workspace's models, once per Workspace.
    func follow(store: CommaStore) {
        guard let workspace = store.workspace, workspaceID != workspace.id || following == nil else { return }
        following?.cancel()
        workspaceID = workspace.id
        catalog = []
        loading = true
        let updates = store.core.subscribe(["topic": "models", "prefer": workspace.id]) { value in
            Self.models(value as? NSDictionary)
        }
        following = Task { [weak self] in
            for await value in updates {
                guard let self, self.workspaceID == workspace.id else { return }
                switch value {
                case .value(let next?):
                    if self.catalog != next { self.catalog = next }
                    self.loading = false
                case .value: continue
                case .failed: self.loading = false
                }
            }
        }
    }

    /// The models a value lists once its catalog is read, those some profile serves; an empty list for a read that
    /// failed, and nil while the first read is in flight.
    nonisolated static func models(_ value: NSDictionary?) -> [MentionModel]? {
        guard let value, value.object("catalog") != nil else { return value?.bool("error") == true ? [] : nil }
        return value.objects("models").compactMap { model in
            guard let id = model.string("id"), let name = model.string("name"),
                  let serving = model.array("serving"), serving.count > 0 else { return nil }
            return MentionModel(id: id, name: name, vendor: model.string("vendor") ?? "", efforts: model.strings("efforts"))
        }
    }
}
