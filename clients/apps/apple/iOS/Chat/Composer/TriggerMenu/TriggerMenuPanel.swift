import SwiftUI
import CommaCore

/// The open menu: a glass card above the composer, the width of the field (at most 400pt, leading, where the
/// width is regular), as tall as its rows up to `cap` (`TriggerMenuMetrics.cap`). Past that it scrolls. A row
/// lights on touch-down and its pick keeps the keyboard up.
struct TriggerMenuPanel: View {
    let match: ComposerTriggerMatch
    let sections: [TriggerMenuSection]
    let label: LocalizedStringResource
    let cap: CGFloat
    var metrics: TriggerMenuMetrics
    /// A model's efforts shown in place of the list, under the way back to it; nil on the list.
    var back: TriggerMenuBack? = nil
    let choose: (TriggerMenuItem) -> Void
    /// Shows the efforts behind a model's row.
    var browse: (TriggerMenuItem) -> Void = { _ in }
    let dismiss: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Filtering returns the list to its very top, its inset included.
    @State private var position = ScrollPosition(edge: .top)

    private static let radius: CGFloat = 24
    private static let regularWidth: CGFloat = 400

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let natural = metrics.naturalHeight(of: sections, back: back != nil)
        Group {
            if natural <= cap {
                // No scroll view: nothing delays a row's light under the finger.
                VStack(alignment: .leading, spacing: 0) { rows(pinned: false) }
                    .padding(TriggerMenuMetrics.inset)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    // Each section's header stays at the top while its rows pass under it, as on the desktop.
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) { rows(pinned: true) }
                        .padding(TriggerMenuMetrics.inset)
                }
                .scrollPosition($position)
                .scrollDismissesKeyboard(.never)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: cap)
                .onChange(of: match.query) { _, _ in position.scrollTo(edge: .top) }
                .onChange(of: back?.title) { _, _ in position.scrollTo(edge: .top) }
            }
        }
        .frame(maxWidth: sizeClass == .regular ? Self.regularWidth : .infinity)
        .contentShape(shape)
        .commaGlassCard(in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("composerMenu")
        .accessibilityAction(.escape, dismiss)
        // A hardware keyboard's Escape closes it, as on the desktop. The focused field keeps key presses from
        // `onKeyPress`, so Escape is a key command here, named Close in the iPad shortcut list.
        .background {
            Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: announce)
        .onChange(of: match.trigger) { _, _ in announce() }
        .onChange(of: back?.title) { _, _ in announce() }
    }

    /// The way back from a second level, then each section's header and rows, then No results or Searching when it
    /// applies. The gap between sections closes a section rather than opening the next, so a pinned header is a
    /// header's height wherever it pins.
    @ViewBuilder private func rows(pinned: Bool) -> some View {
        let fade = UnderPinnedHeader(active: pinned, header: metrics.headerHeight, row: metrics.rowHeight)
        if let back { TriggerMenuBackRow(back: back, metrics: metrics).modifier(fade) }
        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
            Section {
                ForEach(section.items) { item in
                    TriggerMenuRow(item: item, metrics: metrics, browse: item.effortsBehind.map { _ in { browse(item) } }) {
                        choose(item)
                    }
                    .modifier(fade)
                }
                if index < sections.count - 1 { Color.clear.frame(height: TriggerMenuMetrics.sectionGap) }
            } header: {
                TriggerMenuHeader(title: section.title, metrics: metrics)
            }
        }
        if sections.allSatisfy(\.items.isEmpty) || sections.contains(where: \.loading) {
            TriggerMenuStateRow(loading: sections.contains(where: \.loading), height: metrics.rowHeight).modifier(fade)
        }
    }

    /// VoiceOver hears which menu opened and how much it holds; a typed trigger keeps its focus in the field.
    private func announce() {
        let count = sections.reduce(0) { $0 + $1.items.count }
        let results = count == 0 ? String(localized: "No results") : String(localized: "\(count) results")
        AccessibilityNotification.Announcement(String(localized: label) + ", " + results).post()
    }
}

/// A row passing under a pinned header fades out before its text meets the header's, as content does under a
/// bar, so the header needs no fill of its own on the glass. Only rows in the scroll view, whose frame it reads.
private struct UnderPinnedHeader: ViewModifier {
    let active: Bool
    let header: CGFloat
    let row: CGFloat

    func body(content: Content) -> some View {
        if active {
            content.visualEffect { [header, row] effect, proxy in
                effect.opacity(min(1, max(0, (proxy.frame(in: .scrollView).minY - header) / (row / 2) + 1)))
            }
        } else {
            content
        }
    }
}

/// The desktop's menu motion on a card that is solid glass with its rows at every frame, as the + card is: a
/// see-through card would print its rows over the conversation's text, so nothing in it fades. It comes in over
/// 120ms from 98% and 2pt low, and goes over 80ms to 99% and then in one frame, both anchored on the edge that
/// faces the composer. A send or the + card closes it at once; filtering and switching menus are not animated.
/// Reduce Motion shows and hides it at once.
enum TriggerMenuMotion {
    static let enter = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.12)
    static let exit = Animation.easeOut(duration: 0.08)

    static func transition(reduced: Bool) -> AnyTransition {
        guard !reduced else { return .identity }
        return .asymmetric(insertion: .scale(scale: 0.98, anchor: .bottom).combined(with: .offset(y: 2)),
                           removal: .scale(scale: 0.99, anchor: .bottom))
    }

    static func animation(open: Bool, instant: Bool, reduced: Bool) -> Animation? {
        if instant || reduced { return nil }
        return open ? enter : exit
    }
}
