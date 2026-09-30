import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class NotchRuntimeModel {
    enum PresentationState: Equatable {
        case collapsed
        case active
        case notifying
        case expanded
    }

    var configuration: NotchConfiguration
    var scene: NotchScene = .hidden
    var presentationState: PresentationState = .collapsed

    var screenFrame: CGRect = .zero
    var overlayWindowFrame: CGRect = .zero
    var deviceNotchFrame: CGRect = .zero
    var compactFrame: CGRect = .zero
    var expandedFrame: CGRect = .zero
    var hasRealNotch = false
    var isSelectedScreenInFullScreen = false
    var displayScale: CGFloat = 1

    var compactLeadingSize: CGSize = .zero
    var compactTrailingSize: CGSize = .zero
    var expandedLeadingSize: CGSize = .zero
    var expandedTrailingSize: CGSize = .zero
    var expandedContentSize: CGSize = .zero
    var isCompactHovered = false

    var selectedDisplayID: UInt32?
    var onLayoutInvalidated: (() -> Void)?
    var isAnimatingCollapse = false
    var expandedOverlayVisibleHeight: CGFloat = 0
    /// Incremented to request a one-shot "absorb" scale pulse of the notch shell
    /// (e.g. when an App Shot warps into the notch). The view animates on change.
    var pulseToken: Int = 0

    private var lastNotificationToken: AnyHashable?
    private var pendingNotificationReset: DispatchWorkItem?
    private var pendingCollapseCompletion: DispatchWorkItem?

    init(configuration: NotchConfiguration) {
        self.configuration = configuration
    }

    var packageModel: NotchKitModel {
        NotchKitModel(
            state: packagePresentationState,
            layout: .init(
                deviceNotchSize: deviceNotchFrame.size,
                compactNotchSize: compactNotchSize,
                showsFallbackNotchDebugOverlay: configuration.showsFallbackNotchDebugOverlay && !hasRealNotch,
                collapsedSize: collapsedShellSize,
                compactSideWidth: scene.compactSideWidth,
                compactLeadingWidth: compactSlotWidths.leading,
                compactTrailingWidth: compactSlotWidths.trailing,
                compactSize: compactFrame.size,
                expandedSize: expandedFrame.size,
                backgroundSpacing: configuration.backgroundSpacing,
                topCornerRadiusRatio: configuration.topCornerRadiusRatio,
                collapsedCornerRadius: collapsedCornerRadius,
                compactCornerRadius: configuration.compactCornerRadius,
                notifyingCornerRadius: configuration.notifyingCornerRadius,
                expandedCornerRadius: configuration.expandedCornerRadius,
                compactContentInsets: configuration.compactContentInsets,
                expandedPadding: configuration.expandedPadding,
                notificationHeightBoost: configuration.notificationHeightBoost,
                shadowPadding: configuration.shadowPadding,
                expandedEntranceBlurRadius: configuration.expandedEntranceBlurRadius,
                expandedExitAnimationDuration: configuration.expandedExitAnimationDuration,
                compactHoverOutset: configuration.compactHoverOutset,
                collapseAnimationDuration: configuration.collapseAnimationDuration,
                notificationScale: configuration.notificationScale,
                notificationHoldDuration: configuration.notificationHoldDuration,
                compactHoverAnimation: configuration.compactHoverAnimation,
                notificationIntroAnimation: configuration.notificationIntroAnimation,
                notificationResetAnimation: configuration.notificationResetAnimation,
                materialStyle: configuration.materialStyle,
                liquidGlassHeight: configuration.liquidGlassHeight,
                liquidGlassTransitionHeight: configuration.liquidGlassTransitionHeight
            ),
            animation: shellAnimation,
            horizontalOffset: resolvedHorizontalOffset,
            isCompactHovered: isCompactHovered
        )
    }

    var windowShouldBeVisible: Bool {
        !isSelectedScreenInFullScreen
    }

    func updateScene(_ scene: NotchScene) {
        cancelPendingCollapseCompletion()
        isAnimatingCollapse = false

        let shouldNotify = scene.hasActivity
            && scene.notificationToken != nil
            && scene.notificationToken != lastNotificationToken

        self.scene = scene
        lastNotificationToken = scene.notificationToken

        if !scene.hasActivity {
            transitionToCollapsed()
            recalculateLayout()
            return
        }

        if presentationState == .collapsed {
            presentationState = .active
        }

        recalculateLayout()

        guard shouldNotify, presentationState != .expanded else {
            invalidateLayout()
            return
        }

        triggerNotification()
    }

    func updateScreen(_ screen: NSScreen, fallbackSize: CGSize, isFullScreen: Bool) {
        selectedDisplayID = screen.notchDisplayID
        screenFrame = screen.frame
        isSelectedScreenInFullScreen = isFullScreen
        displayScale = max(screen.backingScaleFactor, 1)

        let notchSize = screen.notchKitSize == .zero ? fallbackSize : screen.notchKitSize
        hasRealNotch = screen.notchKitSize != .zero
        deviceNotchFrame = .init(
            x: screen.frame.midX - notchSize.width / 2,
            y: screen.frame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )

        recalculateLayout()
    }

    func open() {
        guard scene.hasActivity, windowShouldBeVisible else { return }
        cancelPendingNotificationReset()
        cancelPendingCollapseCompletion()
        isAnimatingCollapse = false
        presentationState = .expanded
        recalculateLayout()
    }

    func close() {
        cancelPendingNotificationReset()
        cancelPendingCollapseCompletion()
        let wasExpanded = presentationState == .expanded
        isAnimatingCollapse = false
        presentationState = scene.hasActivity ? .active : .collapsed
        updateCompactHoverState(for: NSEvent.mouseLocation)
        if wasExpanded || presentationState == .collapsed {
            startCollapseAnimation()
        }
        recalculateLayout()
    }

    func toggle() {
        guard windowShouldBeVisible else { return }

        if presentationState == .expanded {
            close()
        } else {
            open()
        }
    }

    /// Request a one-shot "absorb" scale pulse of the notch shell.
    func pulse() {
        guard windowShouldBeVisible else { return }
        pulseToken &+= 1
    }

    func handleMouseDown(at point: NSPoint) {
        guard windowShouldBeVisible else { return }

        switch presentationState {
        case .collapsed:
            return
        case .active, .notifying:
            guard compactHitFrame.contains(point) else { return }
            open()
        case .expanded:
            if compactHitFrame.contains(point) {
                close()
                return
            }
            if !expandedHitFrame.contains(point) {
                close()
            }
        }
    }

    func handleMouseMoved(at point: NSPoint) {
        updateCompactHoverState(for: point)
    }

    func updateCompactLeadingSize(_ size: CGSize) {
        guard hasMeaningfulChange(compactLeadingSize, size) else { return }
        compactLeadingSize = size
        recalculateLayout()
    }

    func updateCompactTrailingSize(_ size: CGSize) {
        guard hasMeaningfulChange(compactTrailingSize, size) else { return }
        compactTrailingSize = size
        recalculateLayout()
    }

    func updateExpandedLeadingSize(_ size: CGSize) {
        guard hasMeaningfulChange(expandedLeadingSize, size) else { return }
        expandedLeadingSize = size
        recalculateLayout()
    }

    func updateExpandedTrailingSize(_ size: CGSize) {
        guard hasMeaningfulChange(expandedTrailingSize, size) else { return }
        expandedTrailingSize = size
        recalculateLayout()
    }

    func updateExpandedContentSize(_ size: CGSize) {
        guard hasMeaningfulChange(expandedContentSize, size) else { return }
        expandedContentSize = size
        recalculateLayout()
    }

    func containsInteractivePoint(_ point: NSPoint) -> Bool {
        guard windowShouldBeVisible else { return false }

        return switch presentationState {
        case .collapsed:
            false
        case .active, .notifying:
            compactHitFrame.contains(point)
        case .expanded:
            expandedHitFrame.contains(point)
        }
    }

    private func updateCompactHoverState(for point: NSPoint) {
        guard windowShouldBeVisible else {
            guard isCompactHovered else { return }
            isCompactHovered = false
            invalidateLayout()
            return
        }

        let shouldHover = switch presentationState {
        case .active, .notifying:
            compactHitFrame.contains(point)
        case .collapsed, .expanded:
            false
        }

        guard isCompactHovered != shouldHover else { return }
        isCompactHovered = shouldHover
        invalidateLayout()
    }

    private var compactHitFrame: CGRect {
        compactFrame.insetBy(
            dx: hasRealNotch ? -configuration.interactionOutset : 0,
            dy: hasRealNotch ? -configuration.interactionOutset : 0
        )
    }

    private var expandedHitFrame: CGRect {
        expandedFrame
    }

    private var packagePresentationState: NotchKitModel.State {
        switch presentationState {
        case .collapsed:
            .collapsed
        case .active:
            .active
        case .notifying:
            .notifying
        case .expanded:
            .expanded
        }
    }

    private var shellAnimation: Animation {
        if isAnimatingCollapse {
            return .smooth(duration: configuration.collapseAnimationDuration, extraBounce: 0)
        }

        return configuration.animation
    }

    private var collapsedCornerRadius: CGFloat {
        guard hasRealNotch else { return 0 }

        return min(
            configuration.compactCornerRadius,
            deviceNotchFrame.width / 2,
            deviceNotchFrame.height / 2
        )
    }

    private var collapsedShellSize: CGSize {
        guard hasRealNotch else { return .zero }

        return .init(
            width: max(0, deviceNotchFrame.width - collapsedCornerRadius * 2),
            height: deviceNotchFrame.height
        )
    }

    private var compactNotchSize: CGSize {
        let reservesNotchWidth = hasRealNotch || !scene.collapsesVirtualCompactNotchWidth

        return .init(
            width: reservesNotchWidth ? deviceNotchFrame.width : 0,
            height: deviceNotchFrame.height
        )
    }

    private var compactSlotWidths: (leading: CGFloat, trailing: CGFloat) {
        let sideWidth = max(0, scene.compactSideWidth)
        guard scene.collapsesVirtualCompactNotchWidth, !hasRealNotch else {
            return (sideWidth, sideWidth)
        }

        return (
            max(0, scene.compactLeadingWidth ?? sideWidth),
            max(0, scene.compactTrailingWidth ?? sideWidth)
        )
    }

    private var resolvedHorizontalOffset: CGFloat {
        guard overlayWindowFrame != .zero else { return 0 }

        let targetMidX: CGFloat = switch presentationState {
        case .collapsed, .active, .notifying:
            compactFrame.midX
        case .expanded:
            expandedFrame.midX
        }

        return targetMidX - overlayWindowFrame.midX
    }

    private func triggerNotification() {
        cancelPendingNotificationReset()
        presentationState = .notifying
        recalculateLayout()

        if configuration.hapticFeedbackEnabled, NSEvent.pressedMouseButtons == 0 {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard presentationState == .notifying else { return }
            presentationState = .active
            recalculateLayout()
        }

        pendingNotificationReset = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + configuration.notificationHoldDuration,
            execute: workItem
        )
    }

    private func transitionToCollapsed() {
        cancelPendingNotificationReset()
        presentationState = .collapsed
        expandedOverlayVisibleHeight = 0
        startCollapseAnimation()
    }

    private func cancelPendingNotificationReset() {
        pendingNotificationReset?.cancel()
        pendingNotificationReset = nil
    }

    private func startCollapseAnimation() {
        cancelPendingCollapseCompletion()
        isAnimatingCollapse = true

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard presentationState == .collapsed else { return }
            isAnimatingCollapse = false
            invalidateLayout()
        }

        pendingCollapseCompletion = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + configuration.collapseAnimationDuration,
            execute: workItem
        )
    }

    private func cancelPendingCollapseCompletion() {
        pendingCollapseCompletion?.cancel()
        pendingCollapseCompletion = nil
    }

    private func recalculateLayout() {
        guard screenFrame != .zero, deviceNotchFrame != .zero else {
            invalidateLayout()
            return
        }

        let compactSlotWidths = compactSlotWidths
        let compactHeight = max(
            deviceNotchFrame.height,
            max(compactLeadingSize.height, compactTrailingSize.height) + configuration.compactContentInsets.top + configuration.compactContentInsets.bottom
        )
        let compactNotchWidth = compactNotchSize.width
        let compactWidth = configuration.compactContentInsets.leading
            + compactSlotWidths.leading
            + compactNotchWidth
            + compactSlotWidths.trailing
            + configuration.compactContentInsets.trailing
        let compactOriginX = if scene.collapsesVirtualCompactNotchWidth, !hasRealNotch {
            deviceNotchFrame.midX - compactWidth / 2
        } else {
            deviceNotchFrame.midX
                - configuration.compactContentInsets.leading
                - compactSlotWidths.leading
                - compactNotchWidth / 2
        }
        compactFrame = .init(
            x: compactOriginX,
            y: screenFrame.maxY - compactHeight,
            width: max(0, compactWidth),
            height: max(0, compactHeight)
        )

        expandedFrame = .init(
            origin: .init(
                x: deviceNotchFrame.midX - resolvedExpandedSize.width / 2,
                y: screenFrame.maxY - resolvedExpandedSize.height
            ),
            size: resolvedExpandedSize
        )

        let expandedVisibleHeight: CGFloat
        if presentationState == .expanded {
            expandedOverlayVisibleHeight = max(expandedOverlayVisibleHeight, resolvedExpandedSize.height)
            expandedVisibleHeight = expandedOverlayVisibleHeight
        } else {
            expandedOverlayVisibleHeight = resolvedExpandedSize.height
            expandedVisibleHeight = resolvedExpandedSize.height
        }

        let tallestVisibleHeight = max(compactFrame.height, expandedVisibleHeight)
        let overlayHeight = tallestVisibleHeight + configuration.shadowPadding.height
        overlayWindowFrame = backingPixelAligned(
            .init(
                x: screenFrame.minX,
                y: screenFrame.maxY - overlayHeight,
                width: screenFrame.width,
                height: overlayHeight + topEdgeOverscan
            )
        )

        updateCompactHoverState(for: NSEvent.mouseLocation)
        invalidateLayout()
    }

    private var topEdgeOverscan: CGFloat {
        1 / max(displayScale, 1)
    }

    private func backingPixelAligned(_ frame: CGRect) -> CGRect {
        let scale = max(displayScale, 1)
        let minX = (frame.minX * scale).rounded(.down) / scale
        let minY = (frame.minY * scale).rounded(.down) / scale
        let maxX = (frame.maxX * scale).rounded(.up) / scale
        let maxY = (frame.maxY * scale).rounded(.up) / scale

        return .init(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private var resolvedExpandedSize: CGSize {
        let headerMinimumWidth = expandedLeadingSize.width
            + deviceNotchFrame.width
            + expandedTrailingSize.width
            + configuration.expandedPadding.leading
            + configuration.expandedPadding.trailing
        let headerHeight = deviceNotchFrame.height
            + configuration.expandedPadding.top
            + configuration.expandedPadding.bottom

        switch scene.expandedSizing {
        case let .fixed(size):
            return size
        case .intrinsic:
            let proposed = CGSize(
                width: max(headerMinimumWidth, expandedContentSize.width + configuration.expandedPadding.leading + configuration.expandedPadding.trailing),
                height: max(headerHeight, expandedContentSize.height + deviceNotchFrame.height + configuration.expandedPadding.top + configuration.expandedPadding.bottom)
            )
            return clampExpandedSize(proposed, min: configuration.minimumExpandedSize, max: configuration.maximumExpandedSize)
        case let .clamped(minSize, maxSize):
            let proposed = CGSize(
                width: max(headerMinimumWidth, expandedContentSize.width + configuration.expandedPadding.leading + configuration.expandedPadding.trailing),
                height: max(headerHeight, expandedContentSize.height + deviceNotchFrame.height + configuration.expandedPadding.top + configuration.expandedPadding.bottom)
            )
            return clampExpandedSize(proposed, min: minSize, max: maxSize)
        }
    }

    private func clampExpandedSize(_ size: CGSize, min: CGSize, max: CGSize) -> CGSize {
        .init(
            width: Swift.max(min.width, Swift.min(max.width, size.width)),
            height: Swift.max(min.height, Swift.min(max.height, size.height))
        )
    }

    private func invalidateLayout() {
        onLayoutInvalidated?()
    }

    private func hasMeaningfulChange(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) > 0.5 || abs(lhs.height - rhs.height) > 0.5
    }
}
