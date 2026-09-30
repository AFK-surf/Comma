import SwiftUI

public struct NotchKitView<
    CompactLeading: View,
    CompactTrailing: View,
    ExpandedLeading: View,
    ExpandedTrailing: View,
    ExpandedContent: View
>: View {
    private let model: NotchKitModel
    private let compactLeading: CompactLeading
    private let compactTrailing: CompactTrailing
    private let expandedLeading: ExpandedLeading
    private let expandedTrailing: ExpandedTrailing
    private let expandedContent: ExpandedContent
    private let onCompactLeadingSizeChange: (CGSize) -> Void
    private let onCompactTrailingSizeChange: (CGSize) -> Void
    private let onExpandedLeadingSizeChange: (CGSize) -> Void
    private let onExpandedTrailingSizeChange: (CGSize) -> Void
    private let onExpandedContentSizeChange: (CGSize) -> Void

    @State private var blurRadius: CGFloat
    @State private var notchScale: CGSize = .init(width: 1, height: 1)
    @State private var shellOuterSize: CGSize
    @State private var shellCornerRadius: CGFloat
    @State private var shellShoulderInset: CGFloat
    @State private var expandedSurfaceSize: CGSize
    @State private var compactHoverOutset: CGFloat
    @State private var rendersCompactAccessories: Bool
    @State private var keepsExpandedContentMounted: Bool
    @State private var expandedContentScale: CGFloat
    @State private var expandedContentOffsetY: CGFloat
    @State private var expandedContentRemovalWorkItem: DispatchWorkItem?
    @State private var compactAccessoriesWorkItem: DispatchWorkItem?
    @State private var isHandlingStateChange = false

    public init(
        model: NotchKitModel,
        @ViewBuilder compactLeading: () -> CompactLeading,
        @ViewBuilder compactTrailing: () -> CompactTrailing,
        @ViewBuilder expandedLeading: () -> ExpandedLeading,
        @ViewBuilder expandedTrailing: () -> ExpandedTrailing,
        @ViewBuilder expandedContent: () -> ExpandedContent
    ) {
        self.init(
            model: model,
            onCompactLeadingSizeChange: { _ in },
            onCompactTrailingSizeChange: { _ in },
            onExpandedLeadingSizeChange: { _ in },
            onExpandedTrailingSizeChange: { _ in },
            onExpandedContentSizeChange: { _ in },
            compactLeading: compactLeading,
            compactTrailing: compactTrailing,
            expandedLeading: expandedLeading,
            expandedTrailing: expandedTrailing,
            expandedContent: expandedContent
        )
    }

    init(
        model: NotchKitModel,
        onCompactLeadingSizeChange: @escaping (CGSize) -> Void,
        onCompactTrailingSizeChange: @escaping (CGSize) -> Void,
        onExpandedLeadingSizeChange: @escaping (CGSize) -> Void,
        onExpandedTrailingSizeChange: @escaping (CGSize) -> Void,
        onExpandedContentSizeChange: @escaping (CGSize) -> Void,
        @ViewBuilder compactLeading: () -> CompactLeading,
        @ViewBuilder compactTrailing: () -> CompactTrailing,
        @ViewBuilder expandedLeading: () -> ExpandedLeading,
        @ViewBuilder expandedTrailing: () -> ExpandedTrailing,
        @ViewBuilder expandedContent: () -> ExpandedContent
    ) {
        self.model = model
        self.onCompactLeadingSizeChange = onCompactLeadingSizeChange
        self.onCompactTrailingSizeChange = onCompactTrailingSizeChange
        self.onExpandedLeadingSizeChange = onExpandedLeadingSizeChange
        self.onExpandedTrailingSizeChange = onExpandedTrailingSizeChange
        self.onExpandedContentSizeChange = onExpandedContentSizeChange
        self.compactLeading = compactLeading()
        self.compactTrailing = compactTrailing()
        self.expandedLeading = expandedLeading()
        self.expandedTrailing = expandedTrailing()
        self.expandedContent = expandedContent()
        _blurRadius = State(
            initialValue: model.state == .expanded ? 0 : model.layout.expandedEntranceBlurRadius
        )
        _shellOuterSize = State(initialValue: model.shellOuterSize)
        _shellCornerRadius = State(initialValue: model.shellCornerRadius)
        _shellShoulderInset = State(initialValue: model.shellShoulderInset)
        _expandedSurfaceSize = State(initialValue: model.layout.expandedSize)
        _compactHoverOutset = State(
            initialValue: model.isCompactHovered ? model.layout.compactHoverOutset : 0
        )
        _rendersCompactAccessories = State(initialValue: model.showsCompactAccessories)
        _keepsExpandedContentMounted = State(initialValue: model.state == .expanded)
        _expandedContentScale = State(initialValue: 1)
        _expandedContentOffsetY = State(initialValue: 0)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            shellBackground
                .zIndex(0)

            shellContentLayer
                .zIndex(1)
        }
        .animation(model.animation, value: model.state)
        .offset(x: model.horizontalOffset)
        .onChange(of: model.state) { oldValue, newValue in
            isHandlingStateChange = true
            handleStateChange(from: oldValue, to: newValue)
            DispatchQueue.main.async {
                isHandlingStateChange = false
            }
        }
        .onChange(of: model.layout.expandedSize) { _, newValue in
            guard !isHandlingStateChange else { return }
            withAnimation(model.animation) {
                expandedSurfaceSize = newValue
                shellOuterSize = model.shellOuterSize
            }
        }
        .onChange(of: model.shellOuterSize) { _, newValue in
            guard !isHandlingStateChange else { return }
            withAnimation(model.animation) {
                shellOuterSize = newValue
            }
        }
        .onChange(of: model.shellCornerRadius) { _, newValue in
            guard !isHandlingStateChange else { return }
            withAnimation(model.animation) {
                shellCornerRadius = newValue
            }
        }
        .onChange(of: model.shellShoulderInset) { _, newValue in
            guard !isHandlingStateChange else { return }
            withAnimation(model.animation) {
                shellShoulderInset = newValue
            }
        }
        .onChange(of: model.isCompactHovered) { _, isHovered in
            handleCompactHoverChange(isHovered)
        }
        .onDisappear {
            expandedContentRemovalWorkItem?.cancel()
            compactAccessoriesWorkItem?.cancel()
        }
    }

    private var compactAccessories: some View {
        HStack(spacing: 0) {
            compactLeading
                .fixedSize()
                .onMeasuredSizeChange(onCompactLeadingSizeChange)
                .frame(width: compactLeadingWidth, alignment: .leading)

            compactNotchReservedArea

            compactTrailing
                .fixedSize()
                .onMeasuredSizeChange(onCompactTrailingSizeChange)
                .frame(width: compactTrailingWidth, alignment: .trailing)
        }
        .padding(.top, model.layout.compactContentInsets.top)
        .padding(.leading, model.layout.compactContentInsets.leading)
        .padding(.bottom, model.layout.compactContentInsets.bottom)
        .padding(.trailing, model.layout.compactContentInsets.trailing)
    }

    private var shellContentLayer: some View {
        ZStack(alignment: .top) {
            if rendersCompactAccessories {
                compactAccessories
                    .frame(
                        width: model.compactContentSize.width,
                        height: model.compactContentSize.height
                    )
                    .transition(
                        .asymmetric(
                            insertion: .opacity.animation(model.animation),
                            removal: .opacity.animation(model.animation)
                        )
                    )
            }

            if model.showsExpandedContent || keepsExpandedContentMounted {
                expandedSurface
                    .frame(
                        width: expandedSurfaceSize.width,
                        height: expandedSurfaceSize.height
                    )
                    .scaleEffect(expandedContentScale, anchor: .top)
                    .offset(y: expandedContentOffsetY)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.96, anchor: .top)
                                .combined(with: .opacity)
                                .combined(with: .offset(y: -24))
                                .combined(with: .blur(radius: model.layout.expandedEntranceBlurRadius))
                                .animation(model.animation),
                            removal: .identity
                        )
                    )
                    .blur(radius: blurRadius)
            }
        }
        .frame(
            width: animatedShellOuterSize.width,
            height: animatedShellOuterSize.height,
            alignment: .top
        )
        .compositingGroup()
        .mask(alignment: .top) {
            shellShape
                .fill(.white)
                .frame(
                    width: animatedShellOuterSize.width,
                    height: animatedShellOuterSize.height
                )
        }
    }

    private var compactLeadingWidth: CGFloat {
        max(0, model.layout.compactLeadingWidth)
    }

    private var compactTrailingWidth: CGFloat {
        max(0, model.layout.compactTrailingWidth)
    }

    private var expandedSurface: some View {
        VStack(spacing: 0) {
            expandedHeader
            expandedContent
                .onMeasuredSizeChange(onExpandedContentSizeChange)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, model.layout.expandedPadding.top)
        .padding(.leading, model.layout.expandedPadding.leading)
        .padding(.bottom, model.layout.expandedPadding.bottom)
        .padding(.trailing, model.layout.expandedPadding.trailing)
    }

    private var expandedHeader: some View {
        HStack {
            HStack {
                expandedLeading
                    .onMeasuredSizeChange(onExpandedLeadingSizeChange)
                Spacer()
            }
            .frame(maxWidth: .infinity)

            expandedNotchReservedArea

            HStack {
                Spacer()
                expandedTrailing
                    .onMeasuredSizeChange(onExpandedTrailingSizeChange)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: model.layout.deviceNotchSize.height)
    }

    private var compactNotchReservedArea: some View {
        notchReservedArea(size: model.layout.compactNotchSize)
    }

    private var expandedNotchReservedArea: some View {
        notchReservedArea(size: model.layout.deviceNotchSize)
    }

    private func notchReservedArea(size: CGSize) -> some View {
        let width = max(0, size.width)
        let height = max(0, size.height)
        let bottomCornerRadius = min(
            max(6, height * 0.35),
            height / 2
        )

        return ZStack {
            if model.layout.showsFallbackNotchDebugOverlay, width > 0, height > 0 {
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: 0,
                        bottomLeading: bottomCornerRadius,
                        bottomTrailing: bottomCornerRadius,
                        topTrailing: 0
                    ),
                    style: .continuous
                )
                .fill(Color.red.opacity(0.1))
                .overlay {
                    UnevenRoundedRectangle(
                        cornerRadii: .init(
                            topLeading: 0,
                            bottomLeading: bottomCornerRadius,
                            bottomTrailing: bottomCornerRadius,
                            topTrailing: 0
                        ),
                        style: .continuous
                    )
                    .stroke(Color.red.opacity(0.5), lineWidth: 1)
                }
            } else {
                Color.clear
            }
        }
        .frame(
            width: width,
            height: height
        )
    }

    private var shellBackground: some View {
        shellSurface
            .scaleEffect(notchScale, anchor: .top)
            .shadow(
                color: .black.opacity(primaryShellShadowOpacity),
                radius: 16,
                x: 0,
                y: 9
            )
            .shadow(
                color: .black.opacity(secondaryShellShadowOpacity),
                radius: 4,
                x: 0,
                y: 1
            )
            .frame(
                width: animatedShellOuterSize.width + model.layout.shadowPadding.width,
                height: animatedShellOuterSize.height + model.layout.shadowPadding.height,
                alignment: .top
            )
    }

    @ViewBuilder
    private var shellSurface: some View {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *), usesLiquidGlassShell {
                clearGlassShellSurface
            } else {
                blackShellSurface
            }
        #else
            blackShellSurface
        #endif
    }

    #if compiler(>=6.2)
        @available(macOS 26.0, *)
        private var clearGlassShellSurface: some View {
            shellShape
                .fill(Color.black.opacity(shellBottomGlassTintOpacity))
                .frame(
                    width: animatedShellOuterSize.width,
                    height: animatedShellOuterSize.height
                )
                .contentShape(shellShape)
                .glassEffect(.clear, in: shellShape)
                .overlay { shellBlackUpperSurface }
                .overlay { shellEdgeChrome }
                .overlay { shellOpaqueBlackOverlay }
                .clipShape(shellShape)
        }
    #endif

    private var blackShellSurface: some View {
        shellShape
            .fill(.black)
            .frame(
                width: animatedShellOuterSize.width,
                height: animatedShellOuterSize.height
            )
    }

    private var primaryShellShadowOpacity: Double {
        guard model.showsShadow else { return 0 }
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) { return 0.18 }
        #endif
        return 0.32
    }

    private var secondaryShellShadowOpacity: Double {
        guard model.showsShadow else { return 0 }
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) { return 0.06 }
        #endif
        return 0.12
    }

    private var shellBlackUpperSurface: some View {
        VStack(spacing: 0) {
            Color.black.frame(height: shellBlackSolidHeight)
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.82), location: 0.28),
                    .init(color: .black.opacity(0.30), location: 0.72),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: shellGlassTransitionHeight)
            Spacer(minLength: 0)
        }
        .frame(width: animatedShellOuterSize.width, height: animatedShellOuterSize.height)
        .clipShape(shellShape)
        .allowsHitTesting(false)
    }

    private var shellBlackSolidHeight: CGFloat {
        max(0, animatedShellOuterSize.height - shellGlassLayerHeight)
    }

    private var shellGlassLayerHeight: CGFloat {
        let maximumGlassHeight = max(0, animatedShellOuterSize.height * 0.5)
        return min(maximumGlassHeight, max(0, model.layout.liquidGlassHeight))
    }

    private var shellGlassTransitionHeight: CGFloat {
        min(model.layout.liquidGlassTransitionHeight, shellGlassLayerHeight)
    }

    private var shellBottomGlassTintOpacity: Double {
        switch model.state {
        case .collapsed: 0
        case .active, .notifying: 0.12
        case .expanded: 0.08
        }
    }

    private var shellEdgeChrome: some View {
        shellShape
            .stroke(.white.opacity(0.16), lineWidth: 1)
            .frame(width: animatedShellOuterSize.width, height: animatedShellOuterSize.height)
            .clipShape(shellShape)
            .allowsHitTesting(false)
    }

    private var shellOpaqueBlackOverlay: some View {
        shellShape
            .fill(.black)
            .frame(width: animatedShellOuterSize.width, height: animatedShellOuterSize.height)
            .opacity(shellOpaqueBlackOverlayOpacity)
            .clipShape(shellShape)
            .allowsHitTesting(false)
    }

    private var usesLiquidGlassShell: Bool {
        model.layout.materialStyle == .liquidGlass
    }

    private var shellOpaqueBlackOverlayOpacity: Double {
        guard usesLiquidGlassShell else { return 1 }
        switch model.state {
        case .collapsed, .active, .notifying: return 1
        case .expanded: return 0
        }
    }

    private var shellShape: NotchShellShape {
        NotchShellShape(
            cornerRadius: shellCornerRadius,
            shoulderInset: shellShoulderInset
        )
    }

    private var animatedShellOuterSize: CGSize {
        let hoverOutset = model.showsCompactAccessories ? compactHoverOutset : 0

        return .init(
            width: shellOuterSize.width + hoverOutset * 2,
            height: shellOuterSize.height + hoverOutset
        )
    }

    private var expandedCollapseScale: CGFloat {
        let sourceSize = expandedSurfaceSize

        guard sourceSize.width > 0, sourceSize.height > 0 else { return 0.001 }

        let widthScale = model.shellSize.width / sourceSize.width
        let heightScale = model.shellSize.height / sourceSize.height

        return max(0.001, min(1, min(widthScale, heightScale)))
    }

    private var expandedCollapseOffsetY: CGFloat {
        0
    }

    private var expandedExitAnimation: Animation {
        .easeIn(duration: model.layout.expandedExitAnimationDuration)
    }

    private func handleCompactHoverChange(_ isHovered: Bool) {
        withAnimation(model.layout.compactHoverAnimation) {
            compactHoverOutset = isHovered ? model.layout.compactHoverOutset : 0
        }
    }

    private func handleStateChange(from oldState: NotchKitModel.State, to newState: NotchKitModel.State) {
        compactAccessoriesWorkItem?.cancel()
        compactAccessoriesWorkItem = nil

        let shellAnimation = shellAnimation(from: oldState, to: newState)

        withAnimation(shellAnimation) {
            shellOuterSize = model.shellOuterSize
            shellCornerRadius = model.shellCornerRadius
            shellShoulderInset = model.shellShoulderInset
            expandedSurfaceSize = model.layout.expandedSize
        }

        if newState == .expanded {
            expandedContentRemovalWorkItem?.cancel()
            expandedContentRemovalWorkItem = nil
            rendersCompactAccessories = false
            keepsExpandedContentMounted = true
            withAnimation(model.animation) {
                expandedContentScale = 1
                expandedContentOffsetY = 0
                blurRadius = 0
            }
        } else if oldState == .expanded {
            expandedContentRemovalWorkItem?.cancel()
            keepsExpandedContentMounted = true
            rendersCompactAccessories = false

            withAnimation(expandedExitAnimation) {
                expandedContentScale = expandedCollapseScale
                expandedContentOffsetY = expandedCollapseOffsetY
                blurRadius = model.layout.expandedEntranceBlurRadius
            }

            let workItem = DispatchWorkItem {
                keepsExpandedContentMounted = false
                expandedContentScale = 1
                expandedContentOffsetY = 0
                expandedContentRemovalWorkItem = nil
            }

            expandedContentRemovalWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + model.layout.expandedExitAnimationDuration,
                execute: workItem
            )

            if newState == .active || newState == .notifying {
                let compactAccessoriesWorkItem = DispatchWorkItem {
                    withAnimation(model.animation) {
                        rendersCompactAccessories = true
                    }
                    self.compactAccessoriesWorkItem = nil
                }

                self.compactAccessoriesWorkItem = compactAccessoriesWorkItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + model.layout.collapseAnimationDuration,
                    execute: compactAccessoriesWorkItem
                )
            }
        } else {
            rendersCompactAccessories = model.showsCompactAccessories
        }

        if newState != .expanded, oldState != .expanded {
            blurRadius = model.layout.expandedEntranceBlurRadius
        }

        if newState == .notifying {
            withAnimation(model.layout.notificationIntroAnimation) {
                notchScale = model.layout.notificationScale
            }
            return
        }

        if oldState == .notifying {
            withAnimation(model.layout.notificationResetAnimation) {
                notchScale = .init(width: 1, height: 1)
            }
            return
        }

        notchScale = .init(width: 1, height: 1)
    }

    private func shellAnimation(from oldState: NotchKitModel.State, to newState: NotchKitModel.State) -> Animation {
        if oldState == .expanded, newState != .expanded {
            return .smooth(duration: model.layout.collapseAnimationDuration, extraBounce: 0)
        }

        return model.animation
    }
}

private struct BlurTransitionModifier: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

private extension AnyTransition {
    static func blur(radius: CGFloat) -> AnyTransition {
        .modifier(
            active: BlurTransitionModifier(radius: radius),
            identity: BlurTransitionModifier(radius: 0)
        )
    }
}

#Preview("Collapsed") {
    NotchKitPreviewScene(state: .collapsed)
}

#Preview("Active") {
    NotchKitPreviewScene(state: .active)
}

#Preview("Notifying") {
    NotchKitPreviewScene(state: .notifying)
}

#Preview("Expanded") {
    NotchKitPreviewScene(state: .expanded)
}

private struct NotchKitPreviewScene: View {
    let state: NotchKitModel.State

    @State private var compactLeadingSize: CGSize = .zero
    @State private var compactTrailingSize: CGSize = .zero

    private let deviceNotchSize = CGSize(width: 150, height: 28)
    private let compactInsets = EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)

    private var model: NotchKitModel {
        let resolvedCompactSideWidth = max(44, compactLeadingSize.width, compactTrailingSize.width)
        let resolvedCompactSize = CGSize(
            width: compactInsets.leading
                + resolvedCompactSideWidth
                + deviceNotchSize.width
                + resolvedCompactSideWidth
                + compactInsets.trailing,
            height: max(
                deviceNotchSize.height,
                max(compactLeadingSize.height, compactTrailingSize.height)
                    + compactInsets.top
                    + compactInsets.bottom
            )
        )

        return NotchKitModel(
            state: state,
            layout: .init(
                deviceNotchSize: deviceNotchSize,
                compactSideWidth: resolvedCompactSideWidth,
                compactSize: resolvedCompactSize,
                expandedSize: .init(width: 600, height: 180)
            )
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.13, blue: 0.18),
                    Color(red: 0.04, green: 0.05, blue: 0.08),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            NotchKitView(
                model: model,
                onCompactLeadingSizeChange: { compactLeadingSize = $0 },
                onCompactTrailingSizeChange: { compactTrailingSize = $0 },
                onExpandedLeadingSizeChange: { _ in },
                onExpandedTrailingSizeChange: { _ in },
                onExpandedContentSizeChange: { _ in }
            ) {
                previewCompactLabel(symbol: "waveform.circle.fill", title: "2 running")
            } compactTrailing: {
                Text("3")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.trailing, 8)
                    .fixedSize()
            } expandedLeading: {
                previewHeaderButton(symbol: "archivebox.fill")
            } expandedTrailing: {
                previewHeaderButton(symbol: "gearshape.fill")
            } expandedContent: {
                previewExpandedContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 20)
        }
        .frame(width: 760, height: 320)
        .preferredColorScheme(.dark)
    }

    private func previewCompactLabel(symbol: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.leading, 8)
        .fixedSize()
    }

    private func previewHeaderButton(symbol: String) -> some View {
        Button {} label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.08), in: .circle)
        }
        .buttonStyle(.plain)
    }

    private var previewExpandedContent: some View {
        HStack(spacing: 12) {
            ForEach(0 ..< 2, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    Text(index == 0 ? "Generate landing page" : "Refactor NotchKit")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(index == 0 ? "Rendering snapshots are ready" : "Slots and previews are injected")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    HStack(spacing: 8) {
                        Text(index == 0 ? "Running" : "Completed")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(index == 0 ? .white : .green)
                        Spacer()
                        Image(systemName: index == 0 ? "ellipsis.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(index == 0 ? .white.opacity(0.9) : .green)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.white.opacity(index == 0 ? 0.12 : 0.08), in: .rect(cornerRadius: 20))
            }
        }
        .frame(width: 568, height: 104)
    }
}
