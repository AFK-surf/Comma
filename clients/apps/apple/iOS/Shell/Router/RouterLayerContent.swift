import SwiftUI

/// The router chat as the layer shows it. The layer's controller zooms and clips it on its rendered layers.
struct RouterLayerContent: View {
    let store: CommaStore
    /// Put back into the environment, which does not cross into the layer's hosting controller.
    let navigation: AppNavigation
    var call: CallController? = nil
    var sharesRoutineColumn = false
    @State private var folded = false

    var body: some View {
        GeometryReader { geometry in
            let layout = ShellColumnLayout(width: geometry.size.width, folded: folded, division: geometry.shellFoldDivision)
            // The whole stack, its navigation bar included, keeps to the trailing column: the Routines column
            // covers the leading one, and a bar laid out across both would put its close button and mark under it.
            NavigationStack { RouterChatRoot(store: store) }
                .padding(.leading, layout.contentLeadingInset)
        }
        .background(CommaTheme.bgPrimary)
        .environment(navigation)
        .environment(call)
        .accessibilityAddTraits(sharesRoutineColumn ? [] : .isModal)
        .modifier(HomeHingeObserver(folded: $folded))
    }
}
