import SwiftUI
import UIKit
import CommaCore

/// The signed-in app: Home, Inbox and Settings tabs under the system tab bar, the router chat ("Comma") as a
/// layer that zooms out of its circle beside the tabs, and an open Task in a bottom dock that behaves like a
/// Telegram mini app: minimized, a bar with close, title and status sits at the bottom edge and the app
/// ends above it as a card over a black gap; dragging the bar follows the finger up into a full sheet.
/// The router chat and the Task keep their own panes, so neither reloads.
struct AppShellView: View {
    let store: CommaStore
    /// Handed down, not observed: only the Settings views that show it re-render when it publishes, not the
    /// whole shell on every task-list refresh.
    let activity: TaskActivityCoordinator
    @State private var navigation: AppNavigation
    @State private var query = HomeTaskQuery()
    /// The Task sheet has finished rising. Until then the card keeps its full height under the rising
    /// sheet, so making room for the bar never shows as a jump while the sheet opens.
    @State private var dockSettled = false
    @Environment(CallController.self) private var call: CallController?

    static let barHeight: CGFloat = TaskDockViewController.barHeight
    static let gap: CGFloat = 6

    init(store: CommaStore, activity: TaskActivityCoordinator, navigation: AppNavigation = AppNavigation()) {
        self.store = store
        self.activity = activity
        _navigation = State(initialValue: navigation)
    }

    var body: some View {
        let taskPane = store.task
        let docked = taskPane != nil
        let reservesBar = docked && dockSettled
        ZStack(alignment: .bottom) {
            // Black belongs to the Task gap.
            (reservesBar ? Color.black : CommaTheme.bgPrimary).ignoresSafeArea()
            AppCardHost(bottomInset: reservesBar ? Self.barHeight + Self.gap : 0, rounded: reservesBar) {
                ShellCard(store: store, activity: activity, navigation: navigation, query: query)
            }
                // Reach the screen edges so the navigation bars can merge into a system vertical bar. The keyboard
                // too: the card and the router chat's zoom keep their frames while it rises, and each page inside
                // avoids it on the keyboard's own curve. A card that shrank with it moved the open chat for ~10
                // frames and hid its composer behind the rising keyboard.
                .ignoresSafeArea()
            ZStack {
                if let pane = taskPane {
                    TaskDockHost(store: store, pane: pane, revealRequest: store.taskRevealRequest,
                                 onExpand: { navigation.dismissKeyboard() },
                                 onSettled: { dockSettled = true },
                                 onDismissing: { dockSettled = false },
                                 onCovered: { covered in navigation.taskRaised = !covered })
                        // Another Task opened while one is docked takes over the same dock, which raises it, so
                        // the bar grows into the new Task's sheet rather than fading out under a second one.
                        // The close button slides the sheet away itself; any other close (sign-out, a route) fades.
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                }
            }
            .ignoresSafeArea()
            .animation(CommaMotion.railFold, value: docked)
        }
        // The scene window keeps the call above app sheets without blocking the rest of the screen.
        .background { if let call { CallWindowHost(call: call).frame(width: 0, height: 0) } }
        // So does the toast's, under the call.
        .background { ToastWindowHost(center: store.toasts).frame(width: 0, height: 0) }
        .onChange(of: store.error, initial: true) { _, error in report(error) }
        .onChange(of: docked) { _, docked in
            if !docked { dockSettled = false }
            // A Task opens raised; its sheet says when it settles minimized.
            navigation.taskRaised = docked
            store.router.setObscured("task", docked)
        }
        .onAppear {
            store.router.setSurfaceVisible(navigation.routerOpen)
            store.router.setObscured("task", docked)
        }
        .onDisappear { store.router.setSurfaceVisible(false) }
        .onChange(of: navigation.routerOpen) { _, open in store.router.setSurfaceVisible(open) }
        .onChange(of: store.router.revealRequest) { _, _ in navigation.openRouter() }
        .onChange(of: store.workspace?.id) { _, _ in query.reset() }
    }

    private static let failureToast = "app.failure"

    /// A failure the whole app shares (reading the task list, a Task action, switching workspace) as the toast,
    /// whichever page is showing; the failure clears when the toast leaves, so the same failure reports again.
    private func report(_ error: String?) {
        guard let error else { return store.toasts.withdraw(Self.failureToast) }
        store.toasts.show(Toast(id: Self.failureToast, intent: .error, message: error,
                                dismissed: { store.dismissError() }))
    }
}
