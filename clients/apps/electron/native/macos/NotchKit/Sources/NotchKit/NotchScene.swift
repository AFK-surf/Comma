import SwiftUI

public struct NotchScene {
    public var hasActivity: Bool
    public var notificationToken: AnyHashable?
    public var compactSideWidth: CGFloat
    public var compactLeadingWidth: CGFloat?
    public var compactTrailingWidth: CGFloat?
    public var collapsesVirtualCompactNotchWidth: Bool
    public var compactLeadingSlot: AnyView
    public var compactTrailingSlot: AnyView
    public var expandedLeadingSlot: AnyView
    public var expandedTrailingSlot: AnyView
    public var expandedContent: AnyView
    public var expandedSizing: NotchExpandedSizing

    public init(
        hasActivity: Bool,
        notificationToken: AnyHashable? = nil,
        compactSideWidth: CGFloat = 0,
        compactLeadingWidth: CGFloat? = nil,
        compactTrailingWidth: CGFloat? = nil,
        collapsesVirtualCompactNotchWidth: Bool = false,
        compactLeadingSlot: AnyView = AnyView(EmptyView()),
        compactTrailingSlot: AnyView = AnyView(EmptyView()),
        expandedLeadingSlot: AnyView = AnyView(EmptyView()),
        expandedTrailingSlot: AnyView = AnyView(EmptyView()),
        expandedContent: AnyView = AnyView(EmptyView()),
        expandedSizing: NotchExpandedSizing = .intrinsic
    ) {
        self.hasActivity = hasActivity
        self.notificationToken = notificationToken
        self.compactSideWidth = compactSideWidth
        self.compactLeadingWidth = compactLeadingWidth
        self.compactTrailingWidth = compactTrailingWidth
        self.collapsesVirtualCompactNotchWidth = collapsesVirtualCompactNotchWidth
        self.compactLeadingSlot = compactLeadingSlot
        self.compactTrailingSlot = compactTrailingSlot
        self.expandedLeadingSlot = expandedLeadingSlot
        self.expandedTrailingSlot = expandedTrailingSlot
        self.expandedContent = expandedContent
        self.expandedSizing = expandedSizing
    }

    public static var hidden: NotchScene {
        .init(hasActivity: false)
    }

    /// NotchKit stores scene content as `AnyView` so the controller can keep a
    /// single type-stable snapshot while the host swaps arbitrary SwiftUI views.
    public static func erased(@ViewBuilder _ builder: () -> some View) -> AnyView {
        AnyView(builder())
    }
}
