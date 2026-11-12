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
        case "credit_pack", "purchase": Text("Credit pack")
        default: Text("Credits")
        }
    }
}
