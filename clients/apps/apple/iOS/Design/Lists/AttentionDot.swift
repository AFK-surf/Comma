import SwiftUI

/// The brand dot that marks something new: an unread Inbox or Home row, and in the tab bar the Inbox tab, and the
/// avatar when Settings has something to fix (`ShellTabBarController` draws those at this size).
struct AttentionDot: View {
    static let size: CGFloat = 8

    var body: some View {
        Circle().fill(CommaTheme.brandSolid).frame(width: Self.size, height: Self.size)
            .accessibilityHidden(true)
    }
}
