import Foundation
import Observation
import CommaCore

/// Reads the shared billing projection. This page never starts checkout or changes a subscription.
@MainActor @Observable
final class PhoneUsageModel {
    let scope: WorkspaceSettingsScope
    private(set) var value = CoreJSON(value: nil)

    init(store: CommaStore, workspace: Workspace) { scope = WorkspaceSettingsScope(store: store, workspace: workspace) }

    var status: String { value.object?.string("status") ?? "loading" }
    var summary: NSDictionary? { value.object?.object("summary") }
    var subscription: NSDictionary? { summary?.object("active_subscription") }
    var usage: NSDictionary? { value.object?.object("planUsage") }
    var allowance: NSDictionary? { value.object?.object("allowance") }
    var credits: Int { summary?.int("current_credits") ?? 0 }
    var unlimited: Bool { value.object?.bool("unlimited") == true }
    var resetsAt: Date? { Self.date(usage?.string("resetsAt")) }
    var grants: [NSDictionary] { summary?.objects("active_grants") ?? [] }
    var planName: String {
        guard let subscription else { return String(localized: "No active subscription") }
        return subscription.object("plan")?.string("name") ?? value.object?.objects("plans").first {
            $0.string("package_code") == subscription.string("package_code") &&
                $0.string("package_version") == subscription.string("package_version")
        }?.string("name") ?? String(localized: "Subscription")
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    func follow() async {
        for await update in scope.store.core.subscribe(["topic": "billing", "prefer": scope.workspace.id], read: { CoreJSON(value: $0) }) {
            guard scope.current, !Task.isCancelled else { return }
            if case .value(let next) = update {
                if next.object?.string("status") == "ready", next.object?.object("workspace")?.string("id") != scope.workspace.id {
                    value = CoreJSON(value: ["status": "unavailable"])
                } else { value = next }
            } else { value = CoreJSON(value: ["status": "unavailable"]) }
        }
    }

    func refresh() async { _ = await scope.perform("billing.refresh") }
}
