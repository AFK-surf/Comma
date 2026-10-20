import SwiftUI

private enum NotchTaskMetrics {
    static let contentHorizontalPadding: CGFloat = 16
    static let listBottomInset: CGFloat = 16
    static let listBottomEdgeBlurHeight: CGFloat = 28
    static let listHeaderHeight: CGFloat = 34
    static let listSectionSpacing: CGFloat = 10
    static let listItemSpacing: CGFloat = 10
    static let taskCardHeight: CGFloat = 48
    static let maximumListSurfaceHeight: CGFloat = 280

    static func contentHeight(taskCount: Int) -> CGFloat {
        let cardsHeight = CGFloat(taskCount) * taskCardHeight
        let spacingHeight = CGFloat(max(0, taskCount - 1)) * listItemSpacing
        return listHeaderHeight + listSectionSpacing + cardsHeight + spacingHeight + listBottomInset
    }
}

struct CommaNotchActivityLeadingSlotView: View {
    /// Narrower than this, a title shows too few letters to read; the Notch
    /// keeps its activity mark alone. The Settings preview uses the same line.
    private static let minimumTitleWidth: CGFloat = 36

    /// Task ids and the notification count change in one render when a
    /// notification adds a Task, so the rotation reads them together.
    private struct RotationInput: Equatable {
        let taskIDs: [String]
        let notificationSequence: Int
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = CommaNotchTaskRotation()
    let tasks: [CommaNotchScenePayloadTask]
    /// Changes with each notification; the newest Task then comes to the front.
    let notificationSequence: Int
    let availableWidth: CGFloat

    private var currentTask: CommaNotchScenePayloadTask? {
        tasks.first { $0.id == rotation.currentTaskID } ?? tasks.first
    }

    // Reserve the activity mark (20pt) and spacing (10pt); long titles truncate.
    private var titleWidth: CGFloat {
        max(0, availableWidth - 30)
    }

    private var showsTitle: Bool {
        titleWidth >= Self.minimumTitleWidth
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Group {
                    if currentTask?.status == .inProgress {
                        CommaNotchLogoAnimation()
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: currentTask?.status == .sent ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }
                .id(currentTask?.status)
                .transition(reduceMotion ? .opacity : .commaStateSwap)
            }
            .frame(width: 20, height: 18)
            .animation(Self.textSwap(reduceMotion), value: currentTask?.status)

            if showsTitle {
                ZStack(alignment: .leading) {
                    if let task = currentTask {
                        CommaNotchTitleText(
                            text: task.title,
                            running: task.status == .inProgress,
                            font: .system(size: 12, weight: .semibold, design: .rounded)
                        )
                        .id(task.id)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .offset(y: 12).combined(with: .opacity),
                            removal: .offset(y: -12).combined(with: .opacity)
                        ))
                    }
                }
                .frame(width: titleWidth, height: 18, alignment: .leading)
                .clipped()
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.15)
                        : .timingCurve(0.23, 1, 0.32, 1, duration: 0.25),
                    value: currentTask?.id
                )
                .transition(.opacity)
            }
        }
        .frame(width: availableWidth, alignment: .leading)
        .onChange(
            of: RotationInput(taskIDs: tasks.map(\.id), notificationSequence: notificationSequence),
            initial: true
        ) { previous, input in
            rotation.update(
                taskIDs: input.taskIDs,
                showsNewest: input.notificationSequence != previous.notificationSequence
            )
        }
        // One local timer per mounted compact slot, not per task or workspace.
        // The incoming projection is capped at 100 tasks; no RPC/polling is added.
        // A notification restarts it, so the newest Task stays a full interval.
        .task(id: tasks.count > 1 ? notificationSequence : nil) {
            guard tasks.count > 1 else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(CommaNotchTaskRotation.interval))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                rotation.advance()
            }
        }
    }
}

extension CommaNotchActivityLeadingSlotView {
    static func textSwap(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1)
    }
}

struct CommaNotchActivityTrailingSlotView: View {
    let count: Int
    let availableWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            CommaNotchRollingNumberText(number: count)
        }
        .frame(width: availableWidth, alignment: .trailing)
    }
}

private struct CommaNotchRollingNumberText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .monospacedDigit()
            .fixedSize()
            .id(number)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .commaBlurFromBottom,
                removal: .commaBlurToTop
            ))
            .animation(
                reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35),
                value: number
            )
    }
}

struct CommaNotchTasksView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tasks: [CommaNotchScenePayloadTask]
    let listTitle: String
    let listSubtitle: String
    let openChatLabel: String
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTaskMetrics.listSectionSpacing) {
            VStack(alignment: .leading, spacing: 3) {
                Text(listTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                Text(listSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(height: NotchTaskMetrics.listHeaderHeight, alignment: .topLeading)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: NotchTaskMetrics.listItemSpacing) {
                    ForEach(tasks, id: \.id) { task in
                        CommaNotchTaskCardView(
                            task: task,
                            openChatLabel: openChatLabel,
                            onOpen: { onOpen(task.id) }
                        )
                        .transition(reduceMotion ? .opacity : .commaTaskCardMutation)
                    }
                }
                .padding(.bottom, NotchTaskMetrics.listBottomInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.15)
                        : .spring(response: 0.34, dampingFraction: 0.84, blendDuration: 0.08),
                    value: tasks.map(\.id)
                )
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .bottom) {
                if tasks.count > 3 {
                    Rectangle()
                        .fill(.clear)
                        .background(.ultraThinMaterial)
                        .mask(alignment: .bottom) {
                            LinearGradient(
                                stops: [
                                    .init(color: .black.opacity(0), location: 0),
                                    .init(color: .black.opacity(0.2), location: 0.38),
                                    .init(color: .black.opacity(0.7), location: 0.72),
                                    .init(color: .black, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .frame(height: NotchTaskMetrics.listBottomEdgeBlurHeight)
                        .padding(.horizontal, -NotchTaskMetrics.contentHorizontalPadding)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, NotchTaskMetrics.contentHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    static func expandedSurfaceSize(taskCount: Int, notchHeight: CGFloat = 31) -> CGSize {
        let contentHeight = min(
            NotchTaskMetrics.contentHeight(taskCount: taskCount),
            NotchTaskMetrics.maximumListSurfaceHeight
        )
        return CGSize(width: 600, height: notchHeight + contentHeight)
    }
}

private struct CommaNotchTaskCardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: CommaNotchScenePayloadTask
    let openChatLabel: String
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        // A settled send has no task progress to display.
                        Group {
                            if task.status != .inProgress {
                                Image(systemName: task.status == .sent ? "checkmark.circle" : "exclamationmark.circle")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.58))
                            } else {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                        }
                        .id(task.status)
                        .transition(reduceMotion ? .opacity : .commaStateSwap)
                    }
                    .frame(width: 24, height: 24)
                    .animation(CommaNotchActivityLeadingSlotView.textSwap(reduceMotion), value: task.status)

                    VStack(alignment: .leading, spacing: 2) {
                        CommaNotchTitleText(
                            text: task.title,
                            running: task.status == .inProgress,
                            font: .system(size: 12, weight: .medium)
                        )

                        if !task.subtitle.isEmpty {
                            CommaNotchTaskStepText(text: task.subtitle)
                        }
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            actionButton(title: openChatLabel, emphasized: true, action: onOpen)
            .fixedSize()
        }
        .padding(.init(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
                .allowsHitTesting(false)
        }
        .frame(minHeight: NotchTaskMetrics.taskCardHeight, alignment: .center)
    }

    private func actionButton(
        title: String,
        emphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(emphasized ? .white.opacity(0.2) : .clear)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }

}

/// A row's title. When the row stays and its text or state changes (a Quick
/// Chat message's words becoming the Task the Router made of them), the old
/// text blurs out upward as the new one blurs in from below, the direction of
/// the step text under it. A running row's title shimmers.
private struct CommaNotchTitleText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let running: Bool
    let font: Font

    private struct Content: Hashable {
        let text: String
        let running: Bool
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Group {
                if running {
                    CommaNotchThinkingHighlightText(
                        text: text,
                        font: font,
                        baseColor: .white.opacity(0.58),
                        highlightColor: .white.opacity(0.98)
                    )
                } else {
                    Text(text)
                        .font(font)
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(Content(text: text, running: running))
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .commaTextFromBottom,
                removal: .commaTextToTop
            ))
        }
        .animation(
            CommaNotchActivityLeadingSlotView.textSwap(reduceMotion),
            value: Content(text: text, running: running)
        )
    }
}

/// The Worker's latest step under a Task title. A new step rises in from
/// below as the old one leaves upward, the same direction as the compact
/// title rotation. The spring is critically damped and starts from the
/// on-screen value, so steps that change in quick succession retarget the
/// motion instead of queueing it. Only offset and opacity animate.
private struct CommaNotchTaskStepText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.46))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(text)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .offset(y: 8).combined(with: .opacity),
                    removal: .offset(y: -8).combined(with: .opacity)
                ))
        }
        .clipped()
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.15)
                : .spring(response: 0.35, dampingFraction: 1),
            value: text
        )
    }
}

private struct CommaNotchBlurTransitionModifier: ViewModifier {
    let blur: CGFloat
    let offsetY: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: blur).offset(y: offsetY).opacity(opacity)
    }
}

private struct CommaNotchTaskCardMutationTransitionModifier: ViewModifier {
    let opacity: Double
    let scaleX: CGFloat
    let scaleY: CGFloat
    let offsetY: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(x: scaleX, y: scaleY, anchor: .center)
            .offset(y: offsetY)
    }
}

private extension AnyTransition {
    static var commaBlurToTop: AnyTransition {
        .modifier(
            active: CommaNotchBlurTransitionModifier(blur: 4, offsetY: -12, opacity: 0),
            identity: CommaNotchBlurTransitionModifier(blur: 0, offsetY: 0, opacity: 1)
        )
    }

    static var commaBlurFromBottom: AnyTransition {
        .modifier(
            active: CommaNotchBlurTransitionModifier(blur: 4, offsetY: 12, opacity: 0),
            identity: CommaNotchBlurTransitionModifier(blur: 0, offsetY: 0, opacity: 1)
        )
    }

    static var commaTextToTop: AnyTransition {
        .modifier(
            active: CommaNotchBlurTransitionModifier(blur: 3, offsetY: -8, opacity: 0),
            identity: CommaNotchBlurTransitionModifier(blur: 0, offsetY: 0, opacity: 1)
        )
    }

    static var commaTextFromBottom: AnyTransition {
        .modifier(
            active: CommaNotchBlurTransitionModifier(blur: 3, offsetY: 8, opacity: 0),
            identity: CommaNotchBlurTransitionModifier(blur: 0, offsetY: 0, opacity: 1)
        )
    }

    /// A row's mark changing state in place: blur through, no movement.
    static var commaStateSwap: AnyTransition {
        .modifier(
            active: CommaNotchBlurTransitionModifier(blur: 3, offsetY: 0, opacity: 0),
            identity: CommaNotchBlurTransitionModifier(blur: 0, offsetY: 0, opacity: 1)
        )
    }

    static var commaTaskCardMutation: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: CommaNotchTaskCardMutationTransitionModifier(
                    opacity: 0,
                    scaleX: 0.96,
                    scaleY: 0.94,
                    offsetY: 18
                ),
                identity: CommaNotchTaskCardMutationTransitionModifier(
                    opacity: 1,
                    scaleX: 1,
                    scaleY: 1,
                    offsetY: 0
                )
            ),
            removal: .modifier(
                active: CommaNotchTaskCardMutationTransitionModifier(
                    opacity: 0,
                    scaleX: 0.98,
                    scaleY: 0.72,
                    offsetY: 0
                ),
                identity: CommaNotchTaskCardMutationTransitionModifier(
                    opacity: 1,
                    scaleX: 1,
                    scaleY: 1,
                    offsetY: 0
                )
            )
        )
    }
}

private struct CommaNotchThinkingHighlightText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let font: Font
    let baseColor: Color
    let highlightColor: Color
    @State private var phase: CGFloat = 0

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(baseColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        Text(text)
                            .font(font)
                            .foregroundStyle(highlightColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                            .mask(alignment: .leading) {
                                highlightSweep(width: proxy.size.width, height: proxy.size.height)
                            }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .clipped()
                }
            }
            .onAppear(perform: startHighlightAnimation)
            .onChange(of: text) { _, _ in startHighlightAnimation() }
    }

    private func highlightSweep(width: CGFloat, height: CGFloat) -> some View {
        let sweepWidth = max(96, width * 0.72)
        let travel = width + sweepWidth * 2

        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: highlightColor.opacity(0.08), location: 0.18),
                .init(color: highlightColor.opacity(0.9), location: 0.5),
                .init(color: highlightColor.opacity(0.08), location: 0.82),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: sweepWidth, height: max(1, height))
        .blur(radius: 5)
        .offset(x: phase * travel - sweepWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func startHighlightAnimation() {
        guard !reduceMotion else { return }
        phase = 0
        withAnimation(.linear(duration: 1.9).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}
