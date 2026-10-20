import SwiftUI

/// A Settings page: its sections down a scrolling page with the app's 16pt margins. Under the tabs, the shell's
/// safe area keeps its last rows clear of the bar. Sheets pass their own `background`.
struct SettingsPage<Content: View>: View {
    var background = GroupedSurface.page
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .padding(.horizontal, GroupedSurface.margin).padding(.top, 8).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(background)
        .tint(CommaTheme.brandSolid)
    }
}

/// A titled group of rows on one rounded surface (`SurfaceGroup`), with a footnote under it. Rows that resolve
/// to nothing leave no empty section behind.
struct SettingsSection<Content: View, Footer: View>: View {
    private let title: Text?
    private let content: Content
    private let footer: Footer

    init(_ title: Text? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        Group(subviews: content) { rows in
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let title { SurfaceCaption(title) }
                    SurfaceGroup { rows }
                    if Footer.self != EmptyView.self {
                        footer
                            .font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                }
            }
        }
    }
}

extension SettingsSection where Footer == EmptyView {
    init(_ title: Text? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, content: content) { EmptyView() }
    }
}

extension SettingsSection where Footer == Text {
    init(_ title: Text? = nil, footer: Text, @ViewBuilder content: () -> Content) {
        self.init(title, content: content) { footer }
    }
}
