import Foundation
import Observation
import CommaCore

/// The existing recommendations and proactive topics, scoped to the Settings page's Workspace.
@MainActor @Observable
final class PhoneRoutinesSettingsModel {
    let scope: WorkspaceSettingsScope
    private(set) var settings = CoreJSON(value: nil)
    private(set) var sources: [RecommendationSource] = []
    private(set) var loaded = false
    private(set) var proactive = CoreJSON(value: nil)
    var proactiveAttempt = 0

    init(store: CommaStore, workspace: Workspace) { scope = WorkspaceSettingsScope(store: store, workspace: workspace) }

    var enabled: Bool { schedule?.bool("enabled") == true }
    var autoEnable: Bool { settings.object?.bool("autoEnableNewSources") == true }
    var schedule: NSDictionary? { settings.object?.object("schedule") }
    var timezone: String { schedule?.string("timezone") ?? TimeZone.current.identifier }
    var time: Date {
        Calendar.current.date(from: DateComponents(hour: schedule?.int("hour") ?? 8, minute: schedule?.int("minute") ?? 0)) ?? .now
    }

    func follow() async {
        // One settings read, at most 12 sources. Home owns generation polling. Saves update both topics in the core.
        for await update in scope.store.core.subscribe(["topic": "recommendations", "workspace": scope.workspace.id,
            "timezone": TimeZone.current.identifier, "reads": "once"], read: { CoreJSON(value: $0) }) {
            guard scope.current, !Task.isCancelled else { return }
            if case .value(let value) = update, let envelope = value.object?.object("envelope"), let next = envelope.object("settings") {
                settings = CoreJSON(value: next)
                sources = CoreJSON(value: envelope).decode(JSONValue.self).flatMap { try? RecommendationFeed(envelope: $0) }?.sources ?? []
                loaded = true
            } else if case .failed = update {
                loaded = true; scope.error = String(localized: "Couldn’t load Routines settings")
            } else if case .value(let value) = update, value.object?.string("failure") == "unavailable" {
                loaded = true; scope.error = String(localized: "Couldn’t load Routines settings")
            }
        }
    }

    func followProactive() async {
        for await update in scope.store.core.subscribe(["topic": "proactive", "prefer": scope.workspace.id], read: { CoreJSON(value: $0) }) {
            guard scope.current, !Task.isCancelled else { return }
            if case .value(let value) = update {
                if value.object?.string("kind") == "ready", value.object?.string("groupId") != scope.workspace.groupID {
                    proactive = CoreJSON(value: ["kind": "failed"])
                } else { proactive = value }
            }
            else { proactive = CoreJSON(value: ["kind": "failed"]) }
        }
    }

    func save(_ patch: [String: Any]) async { _ = await scope.perform("recommendations.updateSettings", ["patch": patch]) }

    func setSchedule(enabled: Bool? = nil, time: Date? = nil) async {
        guard let schedule else { return }
        let components = time.map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
        await save(["schedule": ["enabled": enabled ?? self.enabled,
            "hour": components?.hour ?? schedule.int("hour") ?? 8,
            "minute": components?.minute ?? schedule.int("minute") ?? 0,
            "timezone": TimeZone.current.identifier]])
    }

    func setSource(_ source: RecommendationSource, enabled: Bool) async {
        await save(["sources": [["connectionId": source.connectionID, "enabled": enabled]]])
    }

    func setProactive(_ enabled: Bool) async {
        guard proactive.object?.string("kind") == "ready", proactive.object?.string("groupId") == scope.workspace.groupID else { return }
        _ = await scope.perform("proactive.set", ["prefer": scope.workspace.id, "enabled": enabled], workspaceParameter: false)
    }

    func refresh() async { _ = await scope.perform("recommendations.visit") }
}
