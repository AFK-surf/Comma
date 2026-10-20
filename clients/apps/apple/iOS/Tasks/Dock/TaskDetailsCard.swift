import SwiftUI
import CommaCore

/// The dock header, which grows in place into the Task's properties (status, origin, Worker, labels),
/// like Slack's channel header: the glass starts as a capsule hugging the title and widens and lengthens
/// into a full-width card, while the header row itself stays put. Any tap outside the card closes it.
struct TaskDetailsCard<Header: View>: View {
    /// The card's inset from the sheet edge, equal on the top and both sides.
    static var inset: CGFloat { 8 }
    /// Header row height inside the card; with the inset it lands the row where the dock bar puts it.
    private static var headerHeight: CGFloat { TaskDockViewController.barHeight - inset }
    private static var radius: CGFloat { 30 }
    /// Critically damped throughout: a tap opens the card, and a tap carries no momentum to overshoot with.
    private static var spring: Animation { .spring(response: 0.4, dampingFraction: 1) }
    /// The two axes run on their own springs: opening leads with height, closing leads with width.
    private static var leadingAxis: Animation { .spring(response: 0.25, dampingFraction: 1) }
    private static var trailingAxis: Animation { .spring(response: 0.38, dampingFraction: 1) }

    let store: CommaStore
    @Bindable var pane: ConversationPane
    @Bindable var state: TaskDockState
    @ViewBuilder let header: () -> Header
    @State private var naturalHeight: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var titleFrame: CGRect = .zero
    /// Vertical travel of a drag outside the open card: it stretches the card, and a pull up closes it on release.
    @State private var dragTravel: CGFloat = 0
    /// Drive the card's width and height separately, each following `detailsOpen` on its own spring.
    @State private var wide = false
    @State private var tall = false
    /// Drives the details' opacity: on with the growth, but off only once the shrink has finished.
    @State private var surfaceShown = false

    var body: some View {
        let open = state.detailsOpen
        let pressed = state.titlePressed && !wide && !tall
        let closed = pressed ? closedRect.scaled(TaskTitlePress.scale) : closedRect
        let open_ = openRect
        let rect = CGRect(x: wide ? open_.minX : closed.minX, y: tall ? open_.minY : closed.minY,
                          width: wide ? open_.width : closed.width, height: tall ? open_.height : closed.height)
        // A capsule while short, the card radius once tall enough.
        let shape = RoundedRectangle(cornerRadius: min(Self.radius, rect.height / 2), style: .continuous)
        ZStack(alignment: .topLeading) {
            if open {
                // Outside the card: a tap closes it; a drag pulls on it without moving it.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { state.detailsOpen = false }
                    .simultaneousGesture(drag)
                    .accessibilityHidden(true)
            }
            ZStack(alignment: .topLeading) {
                surface(rect: rect, shape: shape, open: open, pressed: pressed, lifted: tall)
                VStack(alignment: .leading, spacing: 0) {
                    // A 50pt row centred where the dock bar centres it (10pt below the sheet top).
                    header()
                        .frame(height: 50)
                        .padding(.top, Self.headerHeight - 50)
                        .padding(.horizontal, -Self.inset)
                    TaskDetailsContent(store: store, pane: pane, task: pane.summary ?? store.taskSummary(id: pane.taskID ?? ""),
                                       shown: surfaceShown)
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 20)
                        .opacity(surfaceShown ? 1 : 0)
                        .blur(radius: surfaceShown ? 0 : 6)
                        .allowsHitTesting(open)
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
                .padding([.horizontal, .top], Self.inset)
                // The details show only inside the growing surface; the header row is never clipped.
                .mask(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Rectangle().frame(height: TaskDockViewController.barHeight)
                        shape.axisFrame(rect)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            // A drag outside the card pulls on it: up, it gives a little; down, it stretches a little.
            .scaleEffect(stretch, anchor: .top)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(taskDetailsCardSpace))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onPreferenceChange(TaskTitleFrameKey.self) { value in
            MainActor.assumeIsolated { titleFrame = value }
        }
        .animation(TaskTitlePress.animation(state.titlePressed), value: state.titlePressed)
        .animation(Self.spring, value: naturalHeight)
        .onChange(of: closedRect.minY, initial: true) { _, top in state.capsuleTop = top }
        .onChange(of: open) { _, open in
            if open {
                // Opening, the card drops down first and widens behind it.
                withAnimation(Self.leadingAxis) { tall = true }
                withAnimation(Self.trailingAxis) { wide = true }
                withAnimation(.easeOut(duration: 0.16)) { surfaceShown = true }
            } else {
                // Closing, it narrows first and lifts behind it, fully opaque; only then does it fade.
                withAnimation(Self.leadingAxis) { wide = false }
                withAnimation(Self.trailingAxis, completionCriteria: .logicallyComplete) {
                    tall = false
                } completion: {
                    guard !state.detailsOpen else { return }
                    withAnimation(.easeOut(duration: 0.12)) { surfaceShown = false }
                }
            }
        }
        .task(id: open) {
            if open { await pane.loadLabelCatalog() }
        }
    }

    /// The title always sits on glass; pressed, a fill tints through it, and open, the same glass grows
    /// into the card and lifts with a deeper shadow.
    private func surface(rect: CGRect, shape: RoundedRectangle, open: Bool, pressed: Bool, lifted: Bool) -> some View {
        ZStack {
            shape.fill(CommaTheme.bgTertiary)
                .opacity(pressed ? 1 : 0)
            Color.clear
                .detailsGlass(in: shape, lifted: lifted)
        }
        .frame(width: rect.width)
        .frame(height: rect.height)
        .contentShape(shape)
        .onTapGesture {}
        .allowsHitTesting(open)
        .offset(x: rect.minX)
        .offset(y: rect.minY)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { dragTravel = $0.translation.height }
            .onEnded { value in
                // Released after pulling up, the card closes; after pulling down, it springs back.
                if value.translation.height < -12 || value.predictedEndTranslation.height < -60 {
                    state.detailsOpen = false
                }
                // The release carries the pull's momentum, so it may settle with a little give.
                withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { dragTravel = 0 }
            }
    }

    /// Rubber-banded: the further the finger goes, the less the card follows.
    private var stretch: CGFloat {
        dragTravel < 0 ? 1 - 0.06 * tanh(-dragTravel / 260) : 1 + 0.04 * tanh(dragTravel / 260)
    }

    private var openRect: CGRect {
        CGRect(x: Self.inset, y: Self.inset, width: max(0, width - Self.inset * 2),
               height: max(naturalHeight, Self.headerHeight))
    }

    /// A capsule just around the title and status; the full header band until the title is measured.
    private var closedRect: CGRect {
        guard titleFrame != .zero else {
            return CGRect(x: Self.inset, y: Self.inset, width: max(0, width - Self.inset * 2), height: Self.headerHeight)
        }
        return titleFrame.insetBy(dx: -14, dy: -5)
    }
}

private extension Shape {
    /// Width, height and position as separate modifiers, so each axis animates on its own transaction.
    func axisFrame(_ rect: CGRect) -> some View {
        frame(width: rect.width).frame(height: rect.height).offset(x: rect.minX).offset(y: rect.minY)
    }
}

private extension CGRect {
    /// Grown about its own centre.
    func scaled(_ factor: CGFloat) -> CGRect {
        insetBy(dx: -width * (factor - 1) / 2, dy: -height * (factor - 1) / 2)
    }
}

private extension View {
    /// A dense glass: the card holds text, so the transcript only tints through it. Lifted (the open card)
    /// it grows thicker, so a saturated bubble under it reads as a tint rather than a shape, and casts a
    /// deeper shadow than the resting title capsule.
    @ViewBuilder func detailsGlass<S: Shape>(in shape: S, lifted: Bool) -> some View {
        let shadow = Color.black.opacity(lifted ? 0.12 : 0.05)
        let radius: CGFloat = lifted ? 24 : 8
        if #available(iOS 26.0, *) {
            self.background(shape.fill(CommaTheme.bgPrimary.opacity(lifted ? 0.6 : 0.35)))
                .glassEffect(.regular.tint(CommaTheme.bgPrimary.opacity(0.6)), in: shape)
                .shadow(color: shadow, radius: radius, y: lifted ? 8 : 2)
        } else {
            self.background {
                ZStack {
                    shape.fill(CommaTheme.bgPrimary.opacity(0.5))
                    shape.fill(.thickMaterial)
                    shape.stroke(CommaTheme.borderPrimary.opacity(0.7), lineWidth: 0.5)
                }
                .shadow(color: shadow, radius: radius, y: lifted ? 8 : 2)
            }
        }
    }
}
