import SwiftUI

/// Home's first row: a greeting for the time of day. Once the routine has anything to show, a summary or a connected
/// app, the greeting carries a small chevron and opens the whole routine. Task search opens from the tab bar.
struct HomeHeader: View {
    let store: CommaStore
    let openBriefing: () -> Void
    /// Half the greeting's cap height: the chevron's centre sits this far above the last line's baseline.
    @ScaledMetric(relativeTo: .title3) private var capMiddle: CGFloat = 7

    var body: some View {
        let name = firstName
        // Redrawn each minute, so the greeting turns at noon and at six without a relaunch. It waits
        // unseen for the name rather than greeting the email first and correcting itself.
        TimelineView(.everyMinute) { context in
            greeting(Text(Self.greeting(at: context.date, name: name ?? "")))
        }
        // A touch target's height, with or without the routine's button, so the cards below never move.
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .opacity(name == nil ? 0 : 1)
        .animation(CommaMotion.stateChange, value: name == nil)
        .padding(.horizontal, 20).padding(.top, 8)
    }

    /// The greeting, and with a routine to read, a button with a chevron after it that opens the routine. Not only
    /// a written briefing: the routine sheet shows the connected apps' suggestions, or that none needs the member.
    @ViewBuilder private func greeting(_ text: Text) -> some View {
        let title = text.font(.title3.weight(.semibold)).foregroundStyle(CommaTheme.textPrimary)
        let capMiddle = capMiddle
        if let feed = store.routines.feed, feed.hasSnapshot || !feed.platforms.isEmpty {
            Button(action: openBriefing) {
                // On the last line, so a greeting that wraps at large text sizes still ends in its chevron.
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    title
                    // The small chevron draws inside its square, so it is set larger than the type to read at
                    // the greeting's weight.
                    CentralIcon("central-chevron-right-small", size: 24, relativeTo: .title3)
                        .foregroundStyle(CommaTheme.textTertiary)
                        .padding(.leading, -2)
                        .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + capMiddle }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.97))
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint("Shows your whole routine")
            .accessibilityIdentifier("openRoutine")
        } else {
            title.accessibilityAddTraits(.isHeader)
        }
    }

    /// The first word of the member's name, else, once the profile has been read, the local part of their
    /// email; nil while the name may still arrive.
    private var firstName: String? {
        if let first = store.memberName?.split(separator: " ").first { return String(first) }
        guard store.profileRead || store.profile != nil else { return nil }
        let email = store.memberEmail
        return String(email.split(separator: "@").first ?? Substring(email))
    }

    /// Morning until noon, afternoon until six, then evening, as on the desktop.
    private static func greeting(at date: Date, name: String) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        if hour < 12 { return String(localized: "Good morning, \(name).") }
        if hour < 18 { return String(localized: "Good afternoon, \(name).") }
        return String(localized: "Good evening, \(name).")
    }
}
