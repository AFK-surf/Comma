import Foundation
import Observation
import CommaCore

/// One page's account and Workspace. A retired page cannot send commands or expose late results.
@MainActor @Observable
final class WorkspaceSettingsScope {
    let store: CommaStore
    let workspace: Workspace
    private let boundary: Int
    private(set) var busy = false
    var error: String?

    init(store: CommaStore, workspace: Workspace) {
        self.store = store
        self.workspace = workspace
        boundary = store.boundaryToken
    }

    var current: Bool { store.isCurrent(boundary) && store.workspace?.id == workspace.id && store.session != nil }

    func call(_ name: String, _ params: [String: Any] = [:], workspaceParameter: Bool = true) async throws -> CoreJSON {
        guard current, !Task.isCancelled else { throw CancellationError() }
        var params = params
        if workspaceParameter { params["workspace"] = workspace.id }
        let value = try await store.core.call(name, params)
        guard current, !Task.isCancelled else { throw CancellationError() }
        return value
    }

    @discardableResult
    func perform(_ name: String, _ params: [String: Any] = [:], workspaceParameter: Bool = true) async -> CoreJSON? {
        guard current, !busy else { return nil }
        busy = true
        error = nil
        defer { busy = false }
        do { return try await call(name, params, workspaceParameter: workspaceParameter) }
        catch is CancellationError { return nil }
        catch {
            if current { self.error = error.localizedDescription }
            return nil
        }
    }
}
