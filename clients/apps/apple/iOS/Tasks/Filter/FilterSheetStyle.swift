import SwiftUI

extension View {
    /// A filter sheet over the page or over another filter sheet: medium or large with the grabber, on the
    /// opaque sheet surface; the keyboard leaves as soon as the content scrolls.
    func filterSheet(detent: Binding<PresentationDetent>) -> some View {
        scrollDismissesKeyboard(.immediately)
            .commaSheet(selection: detent)
    }
}

/// The caption over a filter group, with an optional action at its end, spaced from the group above it.
struct FilterCaption<Trailing: View>: View {
    let title: Text
    @ViewBuilder let trailing: Trailing

    var body: some View {
        SurfaceCaption(title: title) { trailing }
            .padding(.top, 22).padding(.bottom, 10)
    }
}

extension FilterCaption where Trailing == EmptyView {
    init(_ title: Text) {
        self.init(title: title) { EmptyView() }
    }
}

/// What a search with no matching filter shows, in the desktop's words and the app's one empty state, as Task
/// search shows its own.
struct FilterNoResults: View {
    var body: some View {
        EmptyState(Text("No filters found"), icon: "icon-search")
    }
}
