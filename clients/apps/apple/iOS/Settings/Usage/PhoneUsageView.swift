import SwiftUI

struct PhoneUsageView: View {
    @State var model: PhoneUsageModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SettingsPage {
            if let error = model.scope.error { InlineError(message: error, retry: { Task { await model.refresh() } }) }
            switch model.status {
            case "ready": overview
            case "unavailable":
                InlineError(message: String(localized: "Couldn’t load usage"), retry: { Task { await model.refresh() } })
            default: ProgressView().frame(maxWidth: .infinity)
            }
        }
        .pageTitle("Usage")
        .task { await model.follow() }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refresh() } } }
        .disabled(!model.scope.current)
    }

    @ViewBuilder private var overview: some View {
        SettingsSection(Text("Available credits")) {
            VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing) {
                if model.unlimited { Text("Unlimited").font(.largeTitle.weight(.semibold)) }
                else {
                    Text(model.credits, format: .number).font(.largeTitle.weight(.semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                if !model.unlimited, model.credits == 0 {
                    Text("No credits remain. Paid tasks cannot start until credits are available.")
                        .font(.subheadline).foregroundStyle(CommaTheme.errorPrimary)
                } else if !model.unlimited, let percent = model.allowance?.int("percent"), percent <= 10 {
                    Text("Credits are running low.").font(.subheadline).foregroundStyle(CommaTheme.errorPrimary)
                }
            }.foregroundStyle(CommaTheme.textPrimary).surfaceRowFrame(vertical: GroupedSurface.inset)
        }
        if !model.unlimited {
            SettingsSection(Text("Current plan")) {
                SettingsRow(Text("Plan"), value: Text(model.planName))
                if let subscription = model.subscription {
                    SettingsRow(Text("Status"), value: subscriptionStatus(subscription.string("status")))
                }
                if let usage = model.usage, let percent = usage.int("usedPercent") {
                    VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing) {
                        HStack {
                            Text("Cycle usage").frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(percent)% used").foregroundStyle(CommaTheme.textTertiary)
                        }
                        ProgressView(value: Double(percent), total: 100).tint(CommaTheme.brandSolid)
                            .accessibilityLabel("Cycle usage").accessibilityValue(Text("\(percent)% used"))
                    }.surfaceRowFrame(vertical: GroupedSurface.inset)
                    if let date = model.resetsAt {
                        SettingsRow(Text(usage.bool("ends") ? "Credits expire" : "Credits reset"), value: Text(date, style: .date))
                    }
                    if let other = usage.int("otherCredits"), other > 0 {
                        SettingsRow(Text("Other credits"), value: Text(other, format: .number))
                    }
                }
            }
            if model.showStoreSection { store }
            if !model.grants.isEmpty {
                SettingsSection(Text("Credit balances")) {
                    ForEach(Array(model.grants.enumerated()), id: \.offset) { _, grant in
                        VStack(alignment: .leading, spacing: 4) {
                            SettingsRow(grantTitle(grant.string("source_type")), value: Text(grant.int("remaining_credits") ?? 0, format: .number))
                            if let expiry = PhoneUsageModel.date(grant.string("expires_at")) {
                                Text("Expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                                    .padding(.horizontal, GroupedSurface.inset).padding(.bottom, GroupedSurface.groupSpacing)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Plans and credit packs the App Store sells, restore and the App Store's own management.
    @ViewBuilder private var store: some View {
        if let notice = model.notice {
            let isWarning = notice == .managedElsewhere || notice == .unrecordable
            SettingsSection {
                SettingsNote {
                    CentralIcon(isWarning ? "central-exclamation-triangle" : "icon-check", size: 20, relativeTo: .body)
                        .foregroundStyle(isWarning ? CommaTheme.errorPrimary : CommaTheme.brandSolid)
                } message: {
                    noticeText(notice).font(.subheadline).foregroundStyle(CommaTheme.textPrimary)
                }.surfaceRowFrame(vertical: GroupedSurface.inset)
            }
        }
        if model.showPlansSection {
            SettingsSection(Text("Plans"), footer: Text(model.managedElsewhere
                ? LocalizedStringKey("Your subscription was bought outside the App Store. Change or cancel it where you bought it.")
                : LocalizedStringKey("Subscriptions renew automatically through your Apple Account until you cancel them at least 24 hours before the period ends. [Terms of Use](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/) · [Privacy Policy](https://comma.surf/privacy/)"))) {
                if model.managedElsewhere {
                    SettingsRow(Text("Subscription"), value: Text(model.provider == "stripe" ? "Managed on the web" : "Managed in Google Play"))
                } else {
                    ForEach(model.subscriptionPlans, id: \.self) { plan in purchaseRow(plan) }
                }
                if model.provider == "apple" {
                    Button { Task { await model.manage() } } label: {
                        SettingsRow(Text("Manage subscription"), icon: "central-arrow-up-right", role: .action)
                    }.buttonStyle(SurfaceRowButtonStyle())
                }
            }
        }
        if model.showCreditPacksSection {
            SettingsSection(Text("Credit packs"), footer: Text("Pack credits expire at the end of the month you buy them in (UTC).")) {
                ForEach(model.creditPacks, id: \.self) { plan in purchaseRow(plan) }
            }
        }
        SettingsSection {
            Button { Task { await model.restore() } } label: {
                SettingsRow(Text("Restore purchases"), icon: "central-arrow-rotate-counter-clockwise", role: .action)
            }.buttonStyle(SurfaceRowButtonStyle())
        }
    }

    private func purchaseRow(_ plan: NSDictionary) -> some View {
        let current = model.isCurrent(plan)
        let buying = model.purchasing == plan.string("plan_key")
        return Button { Task { await model.buy(plan) } } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    planTitle(plan).font(.body).foregroundStyle(current ? CommaTheme.textTertiary : CommaTheme.textPrimary)
                    planCredits(plan).font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if buying { ProgressView() }
                else if current { Text("Current").font(.body).foregroundStyle(CommaTheme.textTertiary) }
                else { Text(model.price(plan) ?? "").font(.body.weight(.semibold)).foregroundStyle(CommaTheme.brandSolid) }
            }
            .surfaceRowFrame()
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(SurfaceRowButtonStyle())
        .disabled(current || model.purchasing != nil)
    }

    private func planTitle(_ plan: NSDictionary) -> Text {
        let name = Text(plan.string("name") ?? "")
        return plan.string("billing_period") == "year" ? Text("\(name) · Yearly") : name
    }

    private func planCredits(_ plan: NSDictionary) -> Text {
        let credits = (plan.int("grant_credits") ?? 0).formatted(.number.notation(.compactName))
        guard plan.string("mode") == "subscription" else { return Text("\(credits) credits") }
        return Text("\(credits) credits / month")
    }

    private func noticeText(_ notice: PhoneUsageModel.StoreNotice) -> Text {
        switch notice {
        case .recorded: Text("Purchase complete. Your credits are ready.")
        case .pending: Text("Purchase received. Your credits appear once it is confirmed.")
        case .restored(let count):
            count == 0 ? Text("No purchases to restore.") : Text("Purchases restored.")
        case .managedElsewhere: Text("Your subscription was bought outside the App Store. Change it where you bought it.")
        case .unrecordable: Text("This purchase could not be applied to your account.")
        }
    }

    private func subscriptionStatus(_ status: String?) -> Text {
        switch status {
        case "active": Text("Active")
        case "trialing": Text("Trial")
        case "past_due": Text("Payment overdue")
        case "unpaid": Text("Unpaid")
        case "paused": Text("Paused")
        default: Text("Unavailable")
        }
    }

    private func grantTitle(_ source: String?) -> Text {
        switch source {
        case "subscription_cycle", "redeem_subscription_cycle": Text("Subscription credits")
        case "comma_signup": Text("Welcome credits")
        case "credit_pack", "purchase", "apple_purchase", "google_purchase", "stripe_checkout": Text("Credit pack")
        default: Text("Credits")
        }
    }
}
