import SwiftUI

/// The app's one empty state: a 24pt glyph, a 15pt title, an optional 13pt line of explanation and the way out, as
/// the desktop's text-sm, centred in the space it is given. Home, Inbox, Search, the Archive, conversations, sheets
/// and the start-up failure all use it, so an empty surface reads the same everywhere. Actions are bordered buttons.
/// Give it the room to centre in: an overlay over a list, or a row whose height is the list's room.
struct EmptyState<Icon: View, Actions: View>: View {
    private let title: Text
    private let description: Text?
    private let icon: Icon
    private let actions: Actions

    init(_ title: Text, description: Text? = nil, @ViewBuilder icon: () -> Icon, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.description = description
        self.icon = icon()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                icon.foregroundStyle(CommaTheme.textTertiary).accessibilityHidden(true)
                VStack(spacing: 4) {
                    title.font(.subheadline.weight(.semibold)).foregroundStyle(CommaTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if let description {
                        description.font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            actions
                .buttonStyle(CommaButtonStyle(hierarchy: .secondary, compact: true))
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, 24).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: Text, description: Text? = nil, @ViewBuilder icon: () -> Icon) {
        self.init(title, description: description, icon: icon) { EmptyView() }
    }
}

extension EmptyState where Icon == CentralIcon {
    /// `icon` names a Central icon asset, drawn at `CommaTheme.emptyStateIcon`.
    init(_ title: Text, icon: String, description: Text? = nil, @ViewBuilder actions: () -> Actions) {
        self.init(title, description: description, icon: { CentralIcon(icon, size: CommaTheme.emptyStateIcon) },
                  actions: actions)
    }
}

extension EmptyState where Icon == CentralIcon, Actions == EmptyView {
    init(_ title: Text, icon: String, description: Text? = nil) {
        self.init(title, icon: icon, description: description) { EmptyView() }
    }
}

extension CommaTheme {
    /// The side of an empty state's glyph. A custom glyph (the Comma mark, a provider logo) uses it too.
    static let emptyStateIcon: CGFloat = 24
}
