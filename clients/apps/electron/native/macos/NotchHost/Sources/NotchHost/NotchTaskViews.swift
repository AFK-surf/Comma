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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = CommaNotchTaskRotation()
    let tasks: [CommaNotchScenePayloadTask]
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
            CommaNotchLogoAnimation()
                .frame(width: 14, height: 14)
                .frame(width: 20, height: 18)

            if showsTitle {
                ZStack(alignment: .leading) {
                    if let task = currentTask {
                        CommaNotchThinkingHighlightText(
                            text: task.title,
                            font: .system(size: 12, weight: .semibold, design: .rounded),
                            baseColor: .white.opacity(0.58),
                            highlightColor: .white.opacity(0.98)
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
        .onChange(of: tasks.map(\.id), initial: true) { _, ids in
            rotation.update(taskIDs: ids)
        }
        // One local timer per mounted compact slot, not per task or workspace.
        // The incoming projection is capped at 100 tasks; no RPC/polling is added.
        .task(id: tasks.count > 1) {
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
    let task: CommaNotchScenePayloadTask
    let openChatLabel: String
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        CommaNotchThinkingHighlightText(
                            text: task.title,
                            font: .system(size: 13, weight: .medium),
                            baseColor: .white.opacity(0.58),
                            highlightColor: .white.opacity(0.98)
                        )

                        Text(task.subtitle)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.46))
                            .lineLimit(1)
                            .truncationMode(.tail)
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
