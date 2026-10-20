import SwiftUI
import UIKit
import CommaCore

/// Home's platform cards: one per connected app, two and a peek per screen (one and a peek at accessibility text
/// sizes, where two would cut every name short), with a scroll indicator under them once they do not all fit. Stands
/// in with placeholders, a retry or a hint to connect apps when there are no cards to show. Cards line up with the
/// page's 20pt text margin.
struct PlatformCarousel: View {
    let store: CommaStore
    let open: (PlatformRoutine) -> Void
    @State private var track = PlatformStripTrack()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.layoutDirection) private var layoutDirection

    static let spacing: CGFloat = 12
    static let margin: CGFloat = 20

    var body: some View {
        let model = store.routines
        let platforms = model.feed?.platforms ?? []
        VStack(alignment: .leading, spacing: 16) {
            if !platforms.isEmpty {
                // The indicator scrolls the strip for VoiceOver through the reader: a bound scroll position also wrote
                // to the strip as it settled, which sent it back to the first card and left it between two.
                ScrollViewReader { reader in
                    VStack(alignment: .leading, spacing: 16) {
                        strip {
                            ForEach(platforms) { platform in
                                PlatformCard(platform: platform, count: store.preTasks(of: platform).count,
                                             refreshing: model.isRefreshing) { open(platform) }
                                    .cardWidth(perScreen)
                                    .contextMenu {
                                        Button { Task { await model.refresh(store: store) } } label: {
                                            Label("Refresh routines", image: "central-arrow-rotate-clockwise")
                                        }
                                        .disabled(model.isRefreshing || model.feed?.canRefresh != true)
                                    }
                            }
                        }
                        .onScrollGeometryChange(for: PlatformStripReading.self) { geometry in
                            PlatformStripReading(geometry, count: platforms.count, spacing: Self.spacing,
                                                 rightToLeft: layoutDirection == .rightToLeft)
                        } action: { _, reading in track.reading = reading }
                        if platforms.count > Int(perScreen) {
                            PlatformScrollIndicator(ids: platforms.map(\.id), span: Int(perScreen), track: track) { id in
                                withAnimation(PlatformScrollIndicator.glide) { reader.scrollTo(id, anchor: .leading) }
                            }
                        }
                    }
                }
            } else if model.feed == nil, model.failure == nil {
                strip { ForEach(0..<2, id: \.self) { PlatformCard.placeholder($0).cardWidth(perScreen) } }
                    .scrollDisabled(true)
            } else if model.feed == nil {
                unavailable(retry: { Task { await model.load(store: store) } })
            } else {
                RoutineStatusCard().padding(.horizontal, Self.margin).padding(.top, 8)
            }
            if model.failure == .rateLimited {
                Text("Too many refreshes in the last hour. Try again later.").font(.footnote)
                    .foregroundStyle(CommaTheme.textQuaternary).padding(.horizontal, Self.margin)
            }
        }
        // Each return to Home is a revisit, and so is the briefing being dropped, which selecting the workspace
        // again on launch does after a background restore already showed it.
        .task(whileShowing: .home, id: RoutinesKey(workspace: store.workspace?.id, resets: model.resets)) {
            await model.reloadIfStale(store: store)
        }
        .task(id: model.feed?.isRefreshing) { await model.follow(store: store) }
        // The app coming back counts as a revisit. This listens for the notification rather than reading the
        // scene phase, because the card's hosting controller forwards only a few environment values.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await model.reloadIfStale(store: store) }
        }
    }

    private struct RoutinesKey: Equatable {
        let workspace: String?
        let resets: Int
    }

    /// How many cards a screen shows, the last fraction being the next card's peek.
    private var perScreen: CGFloat { typeSize.isAccessibilitySize ? 1.2 : 2.2 }

    /// Cards in a row that settles on a card's leading edge, inset like the list below it. A throw carries the row as far
    /// as its speed takes it, as any scroll does, and it settles on the card nearest where it would come to rest.
    private func strip(@ViewBuilder _ cards: () -> some View) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: Self.spacing) { cards() }
                .scrollTargetLayout()
                // Every card takes the tallest card's height.
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentMargins(.horizontal, Self.margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
        .scrollIndicators(.hidden)
    }

    private func unavailable(retry: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text("Routines couldn’t be loaded.").font(.subheadline).foregroundStyle(CommaTheme.textQuaternary)
            Spacer(minLength: 0)
            // Borderless, so only the button dims under the finger instead of the whole list row.
            Button("Retry", action: retry).font(.subheadline.weight(.semibold)).tint(CommaTheme.brandSolid)
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, Self.margin)
    }
}

private extension View {
    /// `perScreen` cards per screen, the fraction a peek of the next. The container's width already leaves out
    /// the margins.
    func cardWidth(_ perScreen: CGFloat) -> some View {
        containerRelativeFrame(.horizontal) { width, _ in (width - PlatformCarousel.spacing) / perScreen }
    }
}

/// How far the cards' strip has scrolled, written on every scrolled frame. Only the indicator reads it, so scrolling
/// redraws the indicator and not the cards.
@MainActor @Observable final class PlatformStripTrack {
    var reading = PlatformStripReading()
}

/// The strip's scroll, in points from its first resting place: one card's step, and the last resting place.
struct PlatformStripReading: Equatable {
    var offset: CGFloat = 0
    var step: CGFloat = 0
    var end: CGFloat = 0

    init() {}

    /// The container leaves out the strip's margins. The offset counts from the first resting place, which right to
    /// left the scroll reports a margin past zero rather than a margin before it.
    init(_ geometry: ScrollGeometry, count: Int, spacing: CGFloat, rightToLeft: Bool) {
        let margin = geometry.contentInsets.leading
        offset = geometry.contentOffset.x + (rightToLeft ? -margin : margin)
        step = count > 0 ? (geometry.contentSize.width + spacing) / CGFloat(count) : 0
        end = max(0, geometry.contentSize.width - geometry.containerSize.width)
    }

    /// The card at the leading edge, between two while the cards move, up to the last whole card; the scroll's last
    /// stretch, shorter than a card, counts as reaching the last cards, which the strip at its end shows whole.
    func leadingCard(count: Int, span: Int) -> CGFloat {
        guard step > 0 else { return 0 }
        let last = CGFloat(max(count - span, 0))
        let position = min(max(offset, 0), end) / step, rest = end / step
        let whole = rest.rounded(.down)
        guard position > whole, rest > whole else { return min(position, last) }
        return whole + (position - whole) / (rest - whole) * (last - whole)
    }
}

/// Where the cards' strip is, as a thumb sliding along a track: at the track's start with the first card at the leading
/// edge, at its end with the last card in view, and between them in step with the cards under the finger. It shows
/// where the row is rather than how many cards it holds, so the thumb keeps one length; pulled past either end, it
/// shortens against that end as the row stretches. VoiceOver adjusts it a card at a time. The platform sheet pages
/// through the same cards under the system's page control.
struct PlatformScrollIndicator: View {
    let ids: [String]
    /// How many cards a screen shows whole.
    let span: Int
    let track: PlatformStripTrack
    let scroll: (String) -> Void

    /// Critically damped, as for anything that moves into place without a throw behind it.
    static let glide = Animation.spring(response: 0.3, dampingFraction: 1)
    private static let width: CGFloat = 44
    private static let height: CGFloat = 4
    /// The thumb's share of the track, as in the design.
    private static let thumb: CGFloat = 0.4
    /// Points the row is pulled past an end for the thumb to lose half its length.
    private static let squeeze: CGFloat = 120

    var body: some View {
        let reading = track.reading
        let first = min(max(Int(reading.leadingCard(count: ids.count, span: span).rounded()), 0), ids.count - 1)
        let (start, length) = Self.thumbFrame(reading)
        ZStack(alignment: .leading) {
            Capsule().fill(CommaTheme.borderSecondary)
            // Placed by its leading padding, which follows the layout direction as the strip does.
            Capsule().fill(CommaTheme.textPrimary)
                .frame(width: length)
                .padding(.leading, start)
        }
        .frame(width: Self.width, height: Self.height)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Platforms")
        .accessibilityValue(Text("Card \(first + 1) of \(ids.count)"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: scroll(ids[min(first + 1, ids.count - 1)])
            case .decrement: scroll(ids[max(first - 1, 0)])
            @unknown default: break
            }
        }
    }

    /// The thumb's leading inset and length with the strip at `reading`.
    private static func thumbFrame(_ reading: PlatformStripReading) -> (start: CGFloat, length: CGFloat) {
        let full = width * thumb
        guard reading.end > 0 else { return (0, full) }
        let progress = reading.offset / reading.end
        let past = max(-reading.offset, reading.offset - reading.end, 0)
        let length = max(height, full * squeeze / (squeeze + past))
        let start = progress <= 0 ? 0 : progress >= 1 ? width - length : progress * (width - full)
        return (start, length)
    }
}

/// Stands in for the cards before any app is connected: the sample marks the desktop shows, and where to
/// connect apps.
private struct RoutineStatusCard: View {
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 104

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PlatformCard.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            ProviderLogoStack(sources: ProviderArtwork.samples.map {
                RecommendationSource(connectionID: $0, appID: $0, appName: $0)
            })
            Text("Connect apps in Comma on your computer").font(.subheadline).foregroundStyle(CommaTheme.textQuaternary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .bottomLeading)
        .overlay(shape.strokeBorder(CommaTheme.borderPrimary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .combine)
    }
}
