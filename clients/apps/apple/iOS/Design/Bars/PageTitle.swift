import SwiftUI

extension View {
    /// A page's title at the app's one title size, in an inline navigation bar. `navigationTitle` still
    /// names the page for the back button, the back menu and VoiceOver. Like the system bar title, it stops
    /// growing at the largest standard text size and offers the Large Content Viewer beyond it.
    /// Rows scrolling under the bar blur progressively, as under every bar.
    func pageTitle(_ title: LocalizedStringKey) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .progressiveTopEdge(overlaysMaterial: false)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    PageTitleText(text: Text(title))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityShowsLargeContentViewer()
                }
            }
    }

    /// `pageTitle` for a name known only at run time, such as a Worker's or a platform's, led by its mark.
    /// The mark and the name read as one heading.
    func pageTitle<Mark: View>(verbatim title: String, @ViewBuilder mark: () -> Mark) -> some View {
        let mark = mark()
        return navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .progressiveTopEdge(overlaysMaterial: false)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        mark
                        PageTitleText(text: Text(verbatim: title))
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityShowsLargeContentViewer()
                }
            }
    }
}

/// A page's title at the app's title size. In a sheet it is a step quieter, as the system's sheet titles are:
/// body size, medium, so it doesn't outweigh the sheet's own content.
private struct PageTitleText: View {
    let text: Text
    @Environment(\.inSheet) private var inSheet

    var body: some View {
        text.font(inSheet ? .body.weight(.medium) : .title3.weight(.semibold))
            .foregroundStyle(CommaTheme.textPrimary).lineLimit(1)
    }
}
