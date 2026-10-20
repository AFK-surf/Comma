import SwiftUI
import UIKit
import CommaCore

/// A platform's pre-tasks, as in mock 8: the app's mark and name as the title, then its suggestions on one
/// rounded surface (`PreTaskGroup`, as in the briefing). A sideways swipe pages to the previous or next platform
/// in the carousel's order, over the system page control, and the title follows the page; it opens on the card that
/// was tapped. Choosing a row hands it to `choose`, which closes the sheet.
struct PreTaskSheet: View {
    let platform: PlatformRoutine
    let store: CommaStore
    let choose: (RecommendationItem, RecommendationSource?) -> Void
    /// The page on screen, by platform id.
    @State private var page: String?
    @Environment(\.dismiss) private var dismiss

    init(platform: PlatformRoutine, store: CommaStore, choose: @escaping (RecommendationItem, RecommendationSource?) -> Void) {
        self.platform = platform
        self.store = store
        self.choose = choose
        _page = State(initialValue: platform.id)
    }

    var body: some View {
        let platforms = pages
        let shown = platforms.first { $0.id == page } ?? platform
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(platforms) { platform in
                            PreTaskPage(platform: platform, store: store, choose: choose)
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $page)
                .scrollIndicators(.hidden)
                if platforms.count > 1 {
                    let ids = platforms.map(\.id)
                    SystemPageControl(count: ids.count, current: Binding(
                        get: { page.flatMap { ids.firstIndex(of: $0) } ?? 0 },
                        set: { index in withAnimation(PlatformScrollIndicator.glide) { page = ids[index] } }))
                        .fixedSize()
                        .padding(.vertical, 4)
                }
            }
            .background(CommaTheme.cardPrimary)
            .pageTitle(verbatim: shown.heading) { ProviderLogo(source: shown.source, size: 20) }
            .sheetCloseButton { dismiss() }
        }
        .commaSheet()
    }

    /// Every platform on Home, in the carousel's order; the tapped one alone if the briefing no longer has it.
    private var pages: [PlatformRoutine] {
        let all = store.routines.feed?.platforms ?? []
        return all.contains { $0.id == platform.id } ? all : [platform]
    }
}

/// One platform's page: its pre-tasks where the title leaves off, or, when it has none, one quiet line in their
/// place. The line sits where the rows would start rather than centred on the page, so paging from a busy platform
/// to an idle one keeps the eye at the same spot, and a sheet that is mostly empty doesn't dress the absence up as a
/// hero. A platform Routines can't read says so instead, since that one needs the member. The page scrolls on its
/// own when the rows outgrow the sheet, and only then.
private struct PreTaskPage: View {
    let platform: PlatformRoutine
    let store: CommaStore
    let choose: (RecommendationItem, RecommendationSource?) -> Void

    var body: some View {
        ScrollView {
            Group {
                if let feed = store.routines.feed, store.hasPreTasks(platform) {
                    PreTaskGroup(platform: platform, items: store.preTasks(of: platform), feed: feed, choose: choose)
                } else {
                    PreTaskPageEmpty(platform: platform)
                }
            }
            .padding(.horizontal, GroupedSurface.margin).padding(.top, 8).padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// An idle platform's line, centred under the title it completes and in the caption's quiet ink, with no mark of
/// its own since the title carries it. A platform that needs reconnecting leads with the desktop's warning glyph.
private struct PreTaskPageEmpty: View {
    let platform: PlatformRoutine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if platform.source?.needsReconnect == true {
                CentralIcon("central-exclamation-triangle", size: 16, relativeTo: .subheadline)
                    .foregroundStyle(CommaTheme.attention)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                Text("Routines can’t read \(platform.name). Reconnect it in Plugins on the desktop.")
            } else {
                Text("Nothing from \(platform.name) needs you right now.")
            }
        }
        .font(.subheadline)
        .foregroundStyle(CommaTheme.textTertiary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, GroupedSurface.inset).padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }
}

/// The system page control, as the system's own pagers draw it: a dot per page, a tap steps a page and a press
/// scrubs across them, with VoiceOver's adjustable page value. Its dots take the text inks so they show on the
/// sheet's light surface.
private struct SystemPageControl: UIViewRepresentable {
    let count: Int
    @Binding var current: Int

    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.hidesForSinglePage = true
        control.pageIndicatorTintColor = .tertiaryLabel
        control.currentPageIndicatorTintColor = .label
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UIPageControl, context: Context) {
        context.coordinator.current = $current
        control.numberOfPages = count
        if control.currentPage != current { control.currentPage = current }
    }

    func makeCoordinator() -> Coordinator { Coordinator(current: $current) }

    @MainActor final class Coordinator: NSObject {
        var current: Binding<Int>
        init(current: Binding<Int>) { self.current = current }
        @objc func changed(_ control: UIPageControl) { current.wrappedValue = control.currentPage }
    }
}
