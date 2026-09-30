import AppKit
import SwiftUI

public struct NotchConfiguration {
    public struct SmoothAnimationConfiguration: Equatable {
        public var duration: Double
        public var extraBounce: Double

        public init(duration: Double, extraBounce: Double) {
            self.duration = duration
            self.extraBounce = extraBounce
        }

        var animation: Animation {
            .smooth(duration: duration, extraBounce: extraBounce)
        }
    }

    public struct SpringAnimationConfiguration: Equatable {
        public var response: Double
        public var dampingFraction: Double
        public var blendDuration: Double

        public init(response: Double, dampingFraction: Double, blendDuration: Double) {
            self.response = response
            self.dampingFraction = dampingFraction
            self.blendDuration = blendDuration
        }

        var animation: Animation {
            .spring(
                response: response,
                dampingFraction: dampingFraction,
                blendDuration: blendDuration
            )
        }
    }

    public enum ScreenSelectionPolicy: Equatable, Hashable {
        case builtInFirst
        case screenUnderPointer
        case mainScreen
    }

    public enum MaterialStyle: String, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
        case black
        case liquidGlass

        public var id: String { rawValue }
    }

    public var screenSelectionPolicy: ScreenSelectionPolicy
    public var fallbackNotchSize: CGSize
    public var showsFallbackNotchDebugOverlay: Bool
    public var compactContentInsets: EdgeInsets
    public var expandedPadding: EdgeInsets
    public var backgroundSpacing: CGFloat
    public var topCornerRadiusRatio: CGFloat
    public var compactCornerRadius: CGFloat
    public var notifyingCornerRadius: CGFloat
    public var expandedCornerRadius: CGFloat
    public var notificationHeightBoost: CGFloat
    public var shadowPadding: CGSize
    public var expandedEntranceBlurRadius: CGFloat
    public var expandedExitAnimationDuration: Double
    public var compactHoverOutset: CGFloat
    public var notificationScale: CGSize
    public var notificationHoldDuration: Double
    public var collapseAnimationDuration: Double
    public var animationConfiguration: SmoothAnimationConfiguration
    public var compactHoverAnimationConfiguration: SpringAnimationConfiguration
    public var notificationIntroAnimationConfiguration: SpringAnimationConfiguration
    public var notificationResetAnimationConfiguration: SpringAnimationConfiguration
    public var maximumExpandedSize: CGSize
    public var minimumExpandedSize: CGSize
    public var materialStyle: MaterialStyle
    public var liquidGlassHeight: CGFloat
    public var liquidGlassTransitionHeight: CGFloat
    public var hapticFeedbackEnabled: Bool
    public var interactionOutset: CGFloat

    public var animation: Animation {
        animationConfiguration.animation
    }

    public var compactHoverAnimation: Animation {
        compactHoverAnimationConfiguration.animation
    }

    public var notificationIntroAnimation: Animation {
        notificationIntroAnimationConfiguration.animation
    }

    public var notificationResetAnimation: Animation {
        notificationResetAnimationConfiguration.animation
    }

    public init(
        screenSelectionPolicy: ScreenSelectionPolicy = .builtInFirst,
        fallbackNotchSize: CGSize = .init(width: 85, height: 31),
        showsFallbackNotchDebugOverlay: Bool = false,
        compactContentInsets: EdgeInsets = .init(top: 0, leading: 8, bottom: 0, trailing: 8),
        expandedPadding: EdgeInsets = .init(top: 0, leading: 16, bottom: 16, trailing: 16),
        backgroundSpacing: CGFloat = 15,
        topCornerRadiusRatio: CGFloat = 0.5,
        compactCornerRadius: CGFloat = 12,
        notifyingCornerRadius: CGFloat = 14,
        expandedCornerRadius: CGFloat = 32,
        notificationHeightBoost: CGFloat = 4,
        shadowPadding: CGSize = .init(width: 64, height: 48),
        expandedEntranceBlurRadius: CGFloat = 80,
        expandedExitAnimationDuration: Double = 0.27,
        compactHoverOutset: CGFloat = 3.5,
        notificationScale: CGSize = .init(width: 1.03, height: 1.06),
        notificationHoldDuration: Double = 0.2,
        collapseAnimationDuration: Double = 0.35,
        animationConfiguration: SmoothAnimationConfiguration = .init(
            duration: 0.42,
            extraBounce: 0
        ),
        compactHoverAnimationConfiguration: SpringAnimationConfiguration = .init(
            response: 0.29,
            dampingFraction: 0.79,
            blendDuration: 0.11
        ),
        notificationIntroAnimationConfiguration: SpringAnimationConfiguration = .init(
            response: 0.25,
            dampingFraction: 0.5,
            blendDuration: 0.1
        ),
        notificationResetAnimationConfiguration: SpringAnimationConfiguration = .init(
            response: 0.35,
            dampingFraction: 0.6,
            blendDuration: 0.1
        ),
        maximumExpandedSize: CGSize = .init(width: 720, height: 320),
        minimumExpandedSize: CGSize = .init(width: 360, height: 140),
        materialStyle: MaterialStyle = .black,
        liquidGlassHeight: CGFloat = 200,
        liquidGlassTransitionHeight: CGFloat = 86,
        hapticFeedbackEnabled: Bool = true,
        interactionOutset: CGFloat = 4
    ) {
        self.screenSelectionPolicy = screenSelectionPolicy
        self.fallbackNotchSize = fallbackNotchSize
        self.showsFallbackNotchDebugOverlay = showsFallbackNotchDebugOverlay
        self.compactContentInsets = compactContentInsets
        self.expandedPadding = expandedPadding
        self.backgroundSpacing = backgroundSpacing
        self.topCornerRadiusRatio = topCornerRadiusRatio
        self.compactCornerRadius = compactCornerRadius
        self.notifyingCornerRadius = notifyingCornerRadius
        self.expandedCornerRadius = expandedCornerRadius
        self.notificationHeightBoost = notificationHeightBoost
        self.shadowPadding = shadowPadding
        self.expandedEntranceBlurRadius = expandedEntranceBlurRadius
        self.expandedExitAnimationDuration = expandedExitAnimationDuration
        self.compactHoverOutset = compactHoverOutset
        self.notificationScale = notificationScale
        self.notificationHoldDuration = notificationHoldDuration
        self.collapseAnimationDuration = collapseAnimationDuration
        self.animationConfiguration = animationConfiguration
        self.compactHoverAnimationConfiguration = compactHoverAnimationConfiguration
        self.notificationIntroAnimationConfiguration = notificationIntroAnimationConfiguration
        self.notificationResetAnimationConfiguration = notificationResetAnimationConfiguration
        self.maximumExpandedSize = maximumExpandedSize
        self.minimumExpandedSize = minimumExpandedSize
        self.materialStyle = materialStyle
        self.liquidGlassHeight = liquidGlassHeight
        self.liquidGlassTransitionHeight = liquidGlassTransitionHeight
        self.hapticFeedbackEnabled = hapticFeedbackEnabled
        self.interactionOutset = interactionOutset
    }
}
