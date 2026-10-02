import SwiftUI
import CommaCore

/// The sidebar's Routines entry, above Tasks: one medium card at a time in a Smart Stack, with the
/// section header's refresh and a button that opens every card in the Routines sheet.
struct RoutinesStrip: View {
    let store: CommaStore
    let actions: RoutineActions
    let openAll: () -> Void

    var body: some View {
        let model = store.routines
        let feed = model.feed
        let cards = feed?.cards ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: openAll) {
                    HStack(spacing: 4) {
                        Text("Routines").font(.system(size: 14, weight: .medium)).foregroundStyle(CommaTheme.textSecondary)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(CommaTheme.textPlaceholder)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("openRoutines")
                Spacer()
                Button { Task { await model.refresh(store: store) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CommaTheme.textQuaternary)
                        .symbolEffect(.rotate, isActive: model.isRefreshing)
                        .frame(width: 28, height: 22)
                }
                .disabled(model.isRefreshing || (feed?.canRefresh != true && model.failure != .unavailable))
                .accessibilityLabel("Refresh routines")
            }
            .padding(.horizontal, 4)
            RoutineReconnectNotice(feed: feed).padding(.horizontal, 4)
            if cards.isEmpty {
                RoutineStatusCard(feed: feed, model: model, family: .medium) { Task { await model.refresh(store: store) } }
            } else {
                RoutineStack(cards: cards) { card in
                    RoutineCardView(card: card, feed: feed!, family: .medium, actions: actions)
                }
                .id(feed?.generation)
            }
        }
        .task(id: store.workspace?.id) { await model.load(store: store) }
        .task(id: model.feed?.isRefreshing) { await model.follow(store: store) }
    }
}

/// A Smart Stack: cards in a glass well, swiped vertically and looping past either end. At rest the card
/// fills the well exactly, so only the card shows. While dragged, the stack shrinks with the drag distance,
/// most halfway between two cards, revealing the glass well and the neighbouring card across the gap.
/// Vertical page dots sit beside the well.
struct RoutineStack<Card: Identifiable, Content: View>: View {
    let cards: [Card]
    @ViewBuilder let content: (Card) -> Content
    @State private var index = 0
    @State private var offset: CGFloat = 0
    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var gap: CGFloat { 12 }
    /// The smallest scale, reached halfway between two cards.
    static var minimumScale: CGFloat { 0.95 }
    private var height: CGFloat { RoutineCardFamily.medium.height }
    private var radius: CGFloat { RoutineCardFamily.cornerRadius }

    var body: some View {
        let well = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let step = height + Self.gap
        ZStack {
            // Neighbours by position; with one card there are none, with two both neighbours are the other card.
            ForEach(positions, id: \.self) { position in
                content(cards[wrap(index + position)])
                    .offset(y: CGFloat(position) * step)
                    .allowsHitTesting(position == 0 && !dragging)
                    .accessibilityHidden(position != 0)
            }
        }
        .frame(height: height)
        .modifier(StackMotion(offset: offset, step: step, minimumScale: Self.minimumScale))
        .frame(maxWidth: .infinity)
        .clipShape(well)
        .commaGlass(in: well)
        .contentShape(well)
        // Ahead of the rows' buttons: once a touch moves 8 points it is a swipe, and the row it began on
        // no longer acts on release. A tap still reaches the row.
        .highPriorityGesture(drag(step: step), including: cards.count > 1 ? .all : .subviews)
        .overlay(alignment: .trailing) {
            if cards.count > 1 {
                VerticalPageDots(count: cards.count, index: index).offset(x: 12)
            }
        }
        .sensoryFeedback(.selection, trigger: index)
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(by: 1)
            case .decrement: move(by: -1)
            @unknown default: break
            }
        }
        .accessibilityValue(Text("Card \(index + 1) of \(cards.count)"))
    }

    private var positions: [Int] { cards.count > 1 ? [-1, 0, 1] : [0] }

    private func wrap(_ value: Int) -> Int { ((value % cards.count) + cards.count) % cards.count }

    private func drag(step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                dragging = true
                offset = value.translation.height
            }
            .onEnded { value in
                dragging = false
                let projected = value.predictedEndTranslation.height
                let direction = projected < -step / 3 ? 1 : projected > step / 3 ? -1 : 0
                // Re-base the offset on the new centre card so nothing jumps, then settle; the scale follows.
                index = wrap(index + direction)
                offset += CGFloat(direction) * step
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.84)) { offset = 0 }
            }
    }

    private func move(by direction: Int) {
        guard cards.count > 1 else { return }
        index = wrap(index + direction)
    }
}

/// Moves the stack and scales it from the same animated offset, so the scale tracks the distance to the
/// nearest resting card on every frame of a drag or a settle.
private struct StackMotion: ViewModifier, @preconcurrency Animatable {
    var offset: CGFloat
    let step: CGFloat
    let minimumScale: CGFloat

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func body(content: Content) -> some View {
        let travel = abs(offset).truncatingRemainder(dividingBy: step)
        let distance = min(travel, step - travel)
        let progress = min(1, distance / (step / 2))
        content
            .offset(y: offset)
            .scaleEffect(1 - (1 - minimumScale) * progress)
    }
}

private struct VerticalPageDots: View {
    let count: Int
    let index: Int
    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<min(count, 8), id: \.self) { dot in
                Circle().fill(dot == index ? CommaTheme.textSecondary : CommaTheme.textPlaceholder.opacity(0.5))
                    .frame(width: 5, height: 5)
            }
        }
        .animation(CommaMotion.spatialMove, value: index)
        .accessibilityHidden(true)
    }
}

/// Every Routine: the greeting and briefing, then each card in the large layout.
struct RoutinesView: View {
    let store: CommaStore
    let actions: RoutineActions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let model = store.routines
        let feed = model.feed
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(greeting).font(.system(size: 22, weight: .semibold)).foregroundStyle(CommaTheme.textPrimary)
                        if let feed, !feed.summary.isEmpty {
                            RoutineProse(parts: feed.summary, feed: feed, size: 15, color: CommaTheme.textTertiary)
                                .lineSpacing(3)
                        }
                    }
                    .padding(.horizontal, 4).padding(.bottom, 4)
                    RoutineReconnectNotice(feed: feed).padding(.horizontal, 4)
                    if model.failure == .rateLimited {
                        Text("Too many refreshes in the last hour. Try again later.")
                            .font(.system(size: 13)).foregroundStyle(CommaTheme.errorPrimary).padding(.horizontal, 4)
                    }
                    if let feed, !feed.cards.isEmpty {
                        ForEach(feed.cards) { card in
                            RoutineCardView(card: card, feed: feed, family: .large, actions: dismissing(actions), fitsContent: true)
                        }
                    } else {
                        RoutineStatusCard(feed: feed, model: model, family: .large) { Task { await model.refresh(store: store) } }
                    }
                    if let generated = feed?.generatedAt {
                        Text("Updated \(generated.formatted(.relative(presentation: .named)))")
                            .font(.footnote).foregroundStyle(CommaTheme.textPlaceholder).frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            .background(CommaTheme.bgWindow.ignoresSafeArea())
            .refreshable { await model.load(store: store) }
            .navigationTitle("Routines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { Task { await model.refresh(store: store) } } label: {
                        Image(systemName: "arrow.clockwise").symbolEffect(.rotate, isActive: model.isRefreshing)
                    }
                    .disabled(model.isRefreshing || (feed?.canRefresh != true && model.failure != .unavailable))
                    .accessibilityLabel("Refresh routines")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(CommaTheme.brandSolid)
        .task { await model.load(store: store) }
        .task(id: model.feed?.isRefreshing) { await model.follow(store: store) }
    }

    /// The greeting is chrome the client owns, not model output, as on the desktop.
    private var greeting: String {
        let name = store.profile?.name ?? store.session?.user.name ?? ""
        let first = name.split(separator: " ").first.map(String.init) ?? name
        let hour = Calendar.current.component(.hour, from: Date())
        if first.isEmpty { return String(localized: "Your briefing") }
        if hour < 12 { return String(localized: "Good morning, \(first).") }
        if hour < 18 { return String(localized: "Good afternoon, \(first).") }
        return String(localized: "Good evening, \(first).")
    }

    /// Acting on a Routine leaves the sheet for the place it acts on.
    private func dismissing(_ actions: RoutineActions) -> RoutineActions {
        RoutineActions(usePrompt: { dismiss(); actions.usePrompt($0) },
                       openTask: { dismiss(); actions.openTask($0) },
                       openURL: actions.openURL)
    }
}
