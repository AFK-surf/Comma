import Foundation
import Observation
import CommaCore

/// Reads the shared billing projection, and buys plans and credit packs through the App Store (`billing.store*`).
/// A subscription sold on the web is changed on the web: this page never starts a Stripe checkout.
@MainActor @Observable
final class PhoneUsageModel {
    let scope: WorkspaceSettingsScope
    private(set) var value = CoreJSON(value: nil)
    /// The plan key a purchase is under way for.
    private(set) var purchasing: String?
    /// What came of the last purchase or restore, when the page says it in words.
    private(set) var notice: StoreNotice?

    enum StoreNotice: Equatable { case recorded, pending, restored(Int), managedElsewhere, unrecordable }

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

    /// The App Store's price for each plan it sells, by plan key; nil where the app sells through no store.
    var storePrices: NSDictionary? { value.object?.object("store")?.object("prices") }
    /// Who sells the running subscription: `stripe` (the web), `apple`, `google`, or `comma` (a redeemed code).
    var provider: String? { subscription?.string("provider") }
    /// A running subscription that the web or another store renews: it is changed where it was bought, and the server
    /// refuses an App Store subscription beside it. A redeemed code's (`comma`) does not block one.
    var managedElsewhere: Bool { subscription != nil && (provider == "stripe" || provider == "google") }
    var subscriptionPlans: [NSDictionary] { storePlans("subscription") }
    var creditPacks: [NSDictionary] { storePlans("payment") }
    var showPlansSection: Bool { managedElsewhere || provider == "apple" || !subscriptionPlans.isEmpty }
    var showCreditPacksSection: Bool { !creditPacks.isEmpty }
    var showStoreSection: Bool { storePrices != nil && (showPlansSection || showCreditPacksSection || notice != nil) }

    private func storePlans(_ mode: String) -> [NSDictionary] {
        guard let storePrices else { return [] }
        return (value.object?.objects("plans") ?? []).filter {
            $0.string("mode") == mode && $0.string("plan_key").flatMap(storePrices.string) != nil
        }
    }

    func price(_ plan: NSDictionary) -> String? { plan.string("plan_key").flatMap { storePrices?.string($0) } }

    /// The running subscription is this plan.
    func isCurrent(_ plan: NSDictionary) -> Bool {
        guard let subscription, provider != "comma" else { return false }
        return plan.string("package_code") == subscription.string("package_code") &&
            plan.string("package_version") == subscription.string("package_version")
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

    func buy(_ plan: NSDictionary) async {
        guard let key = plan.string("plan_key"), purchasing == nil else { return }
        purchasing = key
        notice = nil
        defer { purchasing = nil }
        let result = await scope.perform("billing.storePurchase", ["plan": key]) { refusal in
            guard refusal.code == "subscription_active_elsewhere" else { return false }
            notice = .managedElsewhere
            return true
        }
        switch result?.object?.string("status") {
        case "recorded": notice = .recorded
        case "pending": notice = .pending
        case "unrecordable": notice = .unrecordable
        default: break
        }
    }

    func restore() async {
        notice = nil
        if let result = await scope.perform("billing.storeRestore") {
            notice = .restored(result.object?.int("recorded") ?? 0)
        }
    }

    func manage() async { _ = await scope.perform("billing.storeManage", workspaceParameter: false) }
}
