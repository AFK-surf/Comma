import SwiftUI

/// The router chat as the layer shows it. The layer's controller zooms and clips it on its rendered layers.
struct RouterLayerContent: View {
    let store: CommaStore
    /// Put back into the environment, which does not cross into the layer's hosting controller.
    let navigation: AppNavigation

    var body: some View {
        NavigationStack { RouterChatRoot(store: store) }
            .background(CommaTheme.bgPrimary)
            .environment(navigation)
            .accessibilityAddTraits(.isModal)
    }
}
