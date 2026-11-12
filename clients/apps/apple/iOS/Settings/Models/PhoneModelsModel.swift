import Foundation
import Observation
import CommaCore

struct PhoneModelOption: Identifiable, Sendable {
    let id: String
    let name: String
    let vendor: String
    let efforts: [String]
    let serving: [String]

    init?(_ json: NSDictionary) {
        guard let id = json.string("id"), let name = json.string("name") else { return nil }
        self.id = id; self.name = name
        vendor = json.string("vendor") ?? ""
        efforts = json.strings("efforts"); serving = json.strings("serving")
    }
}

struct PhoneModelSelection: Equatable {
    var kind = "builtin"
    var model: String?
    var effort: String?
    var profile: String?
    var allowPaid = false

    init(_ json: NSDictionary? = nil) {
        kind = json?.string("kind") ?? "builtin"
        model = json?.string("model"); effort = json?.string("reasoning_effort")
        profile = json?.string("profile_id"); allowPaid = json?.bool("allow_paid") == true
    }

    var params: [String: Any] {
        guard kind != "builtin", let model else { return ["kind": "builtin"] }
        return ["kind": kind, "model": model, "reasoning_effort": effort as Any? ?? NSNull(),
                "profile_id": profile as Any? ?? NSNull(), "allow_paid": allowPaid]
    }
}

@MainActor @Observable
final class PhoneModelsModel {
    let scope: WorkspaceSettingsScope
    private(set) var value = CoreJSON(value: nil)
    private(set) var loaded = false

    init(store: CommaStore, workspace: Workspace) { scope = WorkspaceSettingsScope(store: store, workspace: workspace) }

    var models: [PhoneModelOption] { value.object?.objects("models").compactMap(PhoneModelOption.init) ?? [] }
    var profiles: [NSDictionary] { value.object?.objects("profiles") ?? [] }
    var presets: [NSDictionary] { value.object?.objects("presets") ?? [] }
    var router: NSDictionary? { value.object?.object("agents")?.object("agents")?.object("router") }
    var taskSelection: PhoneModelSelection { PhoneModelSelection(value.object?.object("agents")?.object("task_model")?.object("selection")) }
    var routerSelection: PhoneModelSelection { PhoneModelSelection(router?.object("selection")) }

    func follow() async {
        for await update in scope.store.core.subscribe(["topic": "models", "prefer": scope.workspace.id], read: { CoreJSON(value: $0) }) {
            guard scope.current, !Task.isCancelled else { return }
            switch update {
            case .value(let next):
                guard next.object?.string("workspace") == scope.workspace.id else {
                    if next.object?.bool("error") == true || next.object?.string("workspace") != nil {
                        loaded = true
                        scope.error = String(localized: "Model settings are unavailable in this workspace.")
                    }
                    continue
                }
                value = next
                loaded = next.object?.object("catalog") != nil || next.object?.bool("error") == true
                if next.object?.bool("error") == true { scope.error = String(localized: "Couldn’t load model settings") }
            case .failed(let error): loaded = true; scope.error = error.localizedDescription
            }
        }
    }

    func title(_ selection: PhoneModelSelection) -> String {
        guard selection.kind != "builtin", let id = selection.model else { return String(localized: "Comma default") }
        return models.first { $0.id == id }?.name ?? id
    }

    func providerName(_ source: String) -> String {
        value.object?.object("catalog")?.object("sources")?.object(source)?.string("name") ?? source
    }

    func presetName(_ preset: NSDictionary) -> String {
        if let name = preset.string("name") { return name }
        return providerName(preset.string("keySource") ?? preset.string("subscriptionSource") ?? preset.string("id") ?? "")
    }

    func saveSelection(_ selection: PhoneModelSelection, task: Bool) async -> Bool {
        var params: [String: Any] = ["selection": selection.params]
        if !task {
            guard let agent = router?.string("agent_id") else { return false }
            params["agent"] = agent
        }
        return await scope.perform(task ? "models.setTaskModel" : "models.setAgentModel", params) != nil
    }
}

@MainActor @Observable
final class PhoneRouterSettingsModel {
    let scope: WorkspaceSettingsScope
    private(set) var name = ""
    private(set) var style = "default"
    private(set) var loaded = false
    var draftName = ""
    var instructions = ""
    private(set) var savedInstructions: String?
    private var hash: String?
    private(set) var instructionsChanged = false
    private(set) var savingInstructions = false

    init(store: CommaStore, workspace: Workspace) { scope = WorkspaceSettingsScope(store: store, workspace: workspace) }

    func follow() async {
        let updates = scope.store.core.subscribe(["topic": "router", "workspace": scope.workspace.id, "read": "settings"], read: { CoreJSON(value: $0) })
        await refresh()
        for await update in updates {
            guard scope.current, !Task.isCancelled else { return }
            if case .value(let next) = update, let json = next.object {
                install(json)
            } else if case .failed(let error) = update { scope.error = error.localizedDescription }
        }
    }

    func refresh() async {
        if let next = await scope.perform("router.refresh"), let json = next.object { install(json) }
        else if scope.current, scope.error == nil { scope.error = String(localized: "Couldn’t load model settings") }
    }

    private func install(_ json: NSDictionary) {
        guard let name = json.string("name") else { return }
        let previous = self.name
        self.name = name
        if !loaded || draftName == previous { draftName = name }
        style = json.string("reply_style") ?? "default"
        loaded = true
    }

    func loadInstructions() async {
        do {
            let value = try await scope.call("systemFiles.instructions", ["group": scope.workspace.groupID], workspaceParameter: false)
            guard let json = value.object, let content = json.text("content") else { return }
            instructions = content; savedInstructions = content; hash = json.string("hash")
        } catch is CancellationError { }
        catch { if scope.current { scope.error = error.localizedDescription } }
    }

    func saveInstructions(_ content: String) async -> Bool {
        guard savedInstructions != nil, scope.current, !scope.busy, !savingInstructions else { return false }
        savingInstructions = true
        defer { savingInstructions = false }
        instructionsChanged = false
        var params: [String: Any] = ["group": scope.workspace.groupID, "content": content]
        if let hash { params["expectedHash"] = hash }
        do {
            let next = try await scope.call("systemFiles.writeInstructions", params, workspaceParameter: false)
            guard let json = next.object, let saved = json.text("content") else { return false }
            instructions = saved; savedInstructions = saved; hash = json.string("hash")
            return true
        } catch is CancellationError { return false }
        catch {
            guard scope.current else { return false }
            if let coreError = error as? CoreError, coreError.status == 409 {
                // Keep the member's edit. Refresh only the expected version before another explicit save.
                let draft = instructions
                await loadInstructions()
                instructions = draft
                instructionsChanged = true
                scope.error = String(localized: "Instructions changed on another device. Review the latest text before saving again.")
            } else { scope.error = error.localizedDescription }
            return false
        }
    }
}
