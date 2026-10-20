import SwiftUI

/// The router chat's navigation root. It reads the router pane itself, so it updates when the pane
/// finishes loading even though a NavigationStack keeps the root view it was first given.
struct RouterChatRoot: View {
    let store: CommaStore
    @Environment(AppNavigation.self) private var navigation
    @FocusState private var composerFocused: Bool
    @Environment(CallController.self) private var call: CallController?

    var body: some View {
        Group {
            if let pane = store.router.pane {
                PhoneConversationView(store: store, pane: pane, composerFocus: $composerFocused)
            } else if store.productFailed {
                // No Workspace, so no chat to wait for. The toast says why; this stays until a read works.
                ConversationFailedState(title: Text("Couldn’t load the conversation")) {
                    store.dismissError()
                    Task { await store.refresh() }
                }
                .background(CommaTheme.bgPrimary)
            } else {
                // The desktop shows the animated mark while a conversation loads.
                CommaLogoAnimation(ink: CommaTheme.textPlaceholder, aperture: CommaTheme.bgPrimary)
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(CommaTheme.bgPrimary)
            }
        }
        .onChange(of: store.taskRevealRequest) { _, _ in composerFocused = false }
        .onChange(of: navigation.keyboardDismissal) { _, _ in composerFocused = false }
        .onChange(of: navigation.routerOpen) { _, open in if !open { composerFocused = false } }
        .onChange(of: navigation.routerFocusRequest) { _, _ in composerFocused = true }
        // Read when the chat shows, never on a background launch; once per account and Workspace in a process.
        .task(id: (store.session?.id ?? "") + ":" + (store.workspace?.id ?? "")) { await call?.refreshAvailability() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { navigation.closeRouter() } label: {
                    CentralIcon("icon-chevron-down").foregroundStyle(CommaTheme.textPrimary)
                }
                .accessibilityLabel("Close chat")
                .accessibilityIdentifier("closeRouterChat")
            }
            .horizontalBarOnly()
            ToolbarItem(placement: .principal) {
                let replying = store.router.pane?.isReplying ?? false
                // The mark alone; the name stays as the accessibility label.
                RouterMark(replying: replying, size: 26)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Comma"))
                    .accessibilityValue(replying ? Text("Thinking") : Text(verbatim: ""))
                    .accessibilityAddTraits(.isHeader)
            }
            // A call in progress keeps its way back even if calls became unavailable since.
            if let call, call.available || call.busy {
                ToolbarItem(placement: .topBarTrailing) { CallToolbarButton(call: call) }
                    .horizontalBarOnly()
            }
        }
    }
}
