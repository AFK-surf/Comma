import SwiftUI

public struct NotchKitModel {
    public enum State: Equatable {
        case collapsed
        case active
        case notifying
        case expanded
    }

    public struct Layout {
        public var deviceNotchSize: CGSize
        public var compactNotchSize: CGSize
        public var showsFallbackNotchDebugOverlay: Bool
        public var collapsedSize: CGSize
        public var compactSideWidth: CGFloat
        public var compactLeadingWidth: CGFloat
        public var compactTrailingWidth: CGFloat
        public var compactSize: CGSize
        public var expandedSize: CGSize
        public var backgroundSpacing: CGFloat
        public var topCornerRadiusRatio: CGFloat
        public var collapsedCornerRadius: CGFloat
        public var compactCornerRadius: CGFloat
        public var notifyingCornerRadius: CGFloat
        public var expandedCornerRadius: CGFloat
        public var compactContentInsets: EdgeInsets
        public var expandedPadding: EdgeInsets
        public var notificationHeightBoost: CGFloat
        public var shadowPadding: CGSize
        public var expandedEntranceBlurRadius: CGFloat
        public var expandedExitAnimationDuration: Double
        public var compactHoverOutset: CGFloat
        public var collapseAnimationDuration: Double
        public var notificationScale: CGSize
        public var notificationHoldDuration: Double
        public var compactHoverAnimation: Animation
        public var notificationIntroAnimation: Animation
        public var notificationResetAnimation: Animation
        public var materialStyle: NotchConfiguration.MaterialStyle
        public var liquidGlassHeight: CGFloat
        public var liquidGlassTransitionHeight: CGFloat

        public init(
            deviceNotchSize: CGSize,
            compactNotchSize: CGSize? = nil,
            showsFallbackNotchDebugOverlay: Bool = false,
            collapsedSize: CGSize = .zero,
            compactSideWidth: CGFloat = 0,
            compactLeadingWidth: CGFloat? = nil,
            compactTrailingWidth: CGFloat? = nil,
            compactSize: CGSize,
            expandedSize: CGSize,
            backgroundSpacing: CGFloat = 15,
            topCornerRadiusRatio: CGFloat = 0.5,
            collapsedCornerRadius: CGFloat = 0,
            compactCornerRadius: CGFloat = 12,
            notifyingCornerRadius: CGFloat = 14,
            expandedCornerRadius: CGFloat = 32,
            compactContentInsets: EdgeInsets = .init(top: 0, leading: 8, bottom: 0, trailing: 8),
            expandedPadding: EdgeInsets = .init(top: 0, leading: 16, bottom: 16, trailing: 16),
            notificationHeightBoost: CGFloat = 4,
            shadowPadding: CGSize = .init(width: 64, height: 48),
            expandedEntranceBlurRadius: CGFloat = 80,
            expandedExitAnimationDuration: Double = 0.27,
            compactHoverOutset: CGFloat = 3.5,
            collapseAnimationDuration: Double = 0.35,
            notificationScale: CGSize = .init(width: 1.03, height: 1.06),
            notificationHoldDuration: Double = 0.2,
            compactHoverAnimation: Animation = .spring(
                response: 0.29,
                dampingFraction: 0.79,
                blendDuration: 0.11
            ),
            notificationIntroAnimation: Animation = .spring(
                response: 0.25,
                dampingFraction: 0.5,
                blendDuration: 0.1
            ),
            notificationResetAnimation: Animation = .spring(
                response: 0.35,
                dampingFraction: 0.6,
                blendDuration: 0.1
            ),
            materialStyle: NotchConfiguration.MaterialStyle = .black,
            liquidGlassHeight: CGFloat = 200,
            liquidGlassTransitionHeight: CGFloat = 86
        ) {
            self.deviceNotchSize = deviceNotchSize
            self.compactNotchSize = compactNotchSize ?? deviceNotchSize
            self.showsFallbackNotchDebugOverlay = showsFallbackNotchDebugOverlay
            self.collapsedSize = collapsedSize
            self.compactSideWidth = compactSideWidth
            self.compactLeadingWidth = compactLeadingWidth ?? compactSideWidth
            self.compactTrailingWidth = compactTrailingWidth ?? compactSideWidth
            self.compactSize = compactSize
            self.expandedSize = expandedSize
            self.backgroundSpacing = backgroundSpacing
            self.topCornerRadiusRatio = topCornerRadiusRatio
            self.collapsedCornerRadius = collapsedCornerRadius
            self.compactCornerRadius = compactCornerRadius
            self.notifyingCornerRadius = notifyingCornerRadius
            self.expandedCornerRadius = expandedCornerRadius
            self.compactContentInsets = compactContentInsets
            self.expandedPadding = expandedPadding
            self.notificationHeightBoost = notificationHeightBoost
            self.shadowPadding = shadowPadding
            self.expandedEntranceBlurRadius = expandedEntranceBlurRadius
            self.expandedExitAnimationDuration = expandedExitAnimationDuration
            self.compactHoverOutset = compactHoverOutset
            self.collapseAnimationDuration = collapseAnimationDuration
            self.notificationScale = notificationScale
            self.notificationHoldDuration = notificationHoldDuration
            self.compactHoverAnimation = compactHoverAnimation
            self.notificationIntroAnimation = notificationIntroAnimation
            self.notificationResetAnimation = notificationResetAnimation
            self.materialStyle = materialStyle
            self.liquidGlassHeight = liquidGlassHeight
            self.liquidGlassTransitionHeight = liquidGlassTransitionHeight
        }
    }

    public var state: State
    public var layout: Layout
    public var animation: Animation
    public var horizontalOffset: CGFloat
    public var isCompactHovered: Bool

    public init(
        state: State,
        layout: Layout,
        animation: Animation = .smooth(duration: 0.42, extraBounce: 0),
        horizontalOffset: CGFloat = 0,
        isCompactHovered: Bool = false
    ) {
        self.state = state
        self.layout = layout
        self.animation = animation
        self.horizontalOffset = horizontalOffset
        self.isCompactHovered = isCompactHovered
    }

    var shellSize: CGSize {
        switch state {
        case .collapsed:
            layout.collapsedSize
        case .active:
            layout.compactSize
        case .notifying:
            .init(
                width: layout.compactSize.width,
                height: layout.compactSize.height + layout.notificationHeightBoost
            )
        case .expanded:
            layout.expandedSize
        }
    }

    var shellCornerRadius: CGFloat {
        switch state {
        case .collapsed:
            layout.collapsedCornerRadius
        case .active:
            layout.compactCornerRadius
        case .notifying:
            layout.notifyingCornerRadius
        case .expanded:
            layout.expandedCornerRadius
        }
    }

    var shellOuterSize: CGSize {
        .init(
            width: shellSize.width + shellShoulderInset * 2,
            height: shellSize.height
        )
    }

    var shellShoulderInset: CGFloat {
        switch state {
        case .collapsed:
            0
        case .active, .notifying, .expanded:
            shellCornerRadius * layout.topCornerRadiusRatio
        }
    }

    var compactContentSize: CGSize {
        .init(
            width: layout.compactSize.width,
            height: layout.compactSize.height
        )
    }

    var showsCompactAccessories: Bool {
        switch state {
        case .active, .notifying:
            true
        case .collapsed, .expanded:
            false
        }
    }

    var showsExpandedContent: Bool {
        state == .expanded
    }

    var showsShadow: Bool {
        switch state {
        case .notifying, .expanded:
            true
        case .collapsed, .active:
            false
        }
    }
}
