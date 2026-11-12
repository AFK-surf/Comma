import SwiftUI
import CommaCore

/// The dock's transcript: the Task conversation below the header slot.
struct TaskDockContent: View {
    let store: CommaStore
    let pane: ConversationPane
    /// Carries the Home indicator or keyboard inset, animated with the keyboard by the UIKit panel, and the
    /// landscape side insets.
    let state: TaskDockState
    var actions = TaskDockActions()
    /// The dock's conversation as it shows: from below the header to the bottom of the sheet.
    private static let viewport = "comma.taskDockConversation"

    var body: some View {
        VStack(spacing: 0) {
            // The header lives in the chrome layer above; this slot keeps the transcript below it.
            Color.clear.frame(height: TaskDockViewController.barHeight)
            PhoneConversationView(store: store, pane: pane, taskActions: state.actionsByComposer ? actions : nil)
                // A dock taken over by another Task starts its conversation afresh, scroll and all.
                .id(ObjectIdentifier(pane))
                .safeAreaPadding(.bottom, state.bottomInset)
                .safeAreaPadding(.horizontal, state.sideInset)
                // An iPhone in landscape with the keyboard up leaves less room than an empty conversation's message
                // needs. Its frame then keeps to the room there is (both bounds, so it never grows to the
                // conversation's height) and the conversation gives way upward, under the header, rather than
                // overflowing both ways and pushing the composer under the keyboard. The composer's menu measures
                // its room from this frame, the part that shows, so it never rises under the header either.
                .environment(\.conversationViewport, Self.viewport)
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .bottom)
                .coordinateSpace(.named(Self.viewport))
                .environment(\.ambientMotionPaused, state.covered)
        }
        .padding(.top, state.topInset)
        .onChange(of: pane.boundWorker?.participantID ?? pane.state.participant?.participantID, initial: true) { _, participant in
            state.browser?.setParticipant(participant ?? "")
        }
        .sheet(isPresented: Binding(get: { state.browser != nil && !state.browserInline }, set: { presented in
            if !presented && !state.browserInline { state.browser = nil }
        })) {
            if let model = state.browser {
                TaskDockBrowserPage(model: model, close: { state.browser = nil }).commaSheet([.large])
            }
        }
    }
}

/// The wide dock's browser uses the same viewer as the portrait sheet.
struct TaskDockBrowser: View {
    let state: TaskDockState

    var body: some View {
        if state.browserInline, !state.covered, let model = state.browser {
            TaskDockBrowserPage(model: model, close: { state.browser = nil })
                .safeAreaPadding(.top, state.topInset)
                .safeAreaPadding(.bottom, state.bottomInset)
                .safeAreaPadding(.trailing, state.browserTrailingInset)
                .accessibilityIdentifier("taskBrowserPanel")
        }
    }
}

private struct TaskDockBrowserPage: View {
    let model: PhoneBrowserModel
    let close: () -> Void

    var body: some View {
        NavigationStack {
            PhoneBrowserView(model: model)
                .id(model.viewer)
                .sheetCloseButton(id: "closeTaskBrowser", close)
        }
    }
}

/// The header, which grows in place into the Task details. It is hosted above the panel's cover.
struct TaskDockChrome: View {
    let store: CommaStore
    let pane: ConversationPane
    let state: TaskDockState
    let actions: TaskDockActions

    var body: some View {
        TaskDetailsCard(store: store, pane: pane, state: state, openBrowser: actions.openBrowser) {
            TaskDockHeader(store: store, pane: pane, state: state, actions: actions)
        }
        .id(ObjectIdentifier(pane))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Close, title and status. Tapping the title opens or closes the Task details; minimized, it raises the sheet.
private struct TaskDockHeader: View {
    let store: CommaStore
    let pane: ConversationPane
    let state: TaskDockState
    let actions: TaskDockActions

    var body: some View {
        let task = store.taskSummary(id: pane.taskID ?? "")
        let pressed = state.titlePressed
        HStack(spacing: 12) {
            Button(action: actions.close) {
                CentralIcon("icon-close")
                    .foregroundStyle(CommaTheme.textPrimary)
                    .frame(width: 44, height: 44)
                    .headerGlass(onCard: state.detailsOpen)
            }
            .buttonStyle(HeaderButtonStyle(onCard: state.detailsOpen))
            .accessibilityLabel("Close task")
            // The title is a button: held, it grows a little and its surface fills in.
            Button(action: actions.titleTapped) {
                // A title over a status line, like a navigation bar's title and subtitle.
                VStack(spacing: 1) {
                    // The Task sheet's title, at the size every sheet's title takes.
                    Text(task?.title ?? String(localized: "Task"))
                        .font(.body.weight(.medium)).foregroundStyle(CommaTheme.textPrimary).lineLimit(1)
                    if let task {
                        HStack(spacing: 4) {
                            TaskStatusIcon(bucket: task.bucket, size: 11)
                            // Running work shimmers, as its status does on the desktop's Task cards.
                            if task.bucket == .inProgress {
                                ShimmerText(text: String(localized: task.bucket.label), font: .footnote.weight(.medium))
                            } else {
                                Text(task.bucket.label).font(.footnote.weight(.medium))
                                    .foregroundStyle(CommaTheme.textQuaternary)
                            }
                            CentralIcon("central-chevron-down-small", size: 14)
                                .foregroundStyle(CommaTheme.textPlaceholder)
                                .rotationEffect(.degrees(state.detailsOpen ? 180 : 0))
                                .animation(CommaMotion.release, value: state.detailsOpen)
                        }
                    }
                }
                .scaleEffect(pressed ? TaskTitlePress.scale : 1)
                .animation(TaskTitlePress.animation(pressed), value: pressed)
                // The details card grows out of the title's resting bounds, measured outside the press scale.
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: TaskTitleFrameKey.self,
                                               value: proxy.frame(in: .named(taskDetailsCardSpace)))
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressReportingButtonStyle { state.titlePressed = $0 })
            .accessibilityLabel(Text(task?.title ?? String(localized: "Task")))
            .accessibilityValue(task.map { Text($0.bucket.label) } ?? Text(""))
            .accessibilityAction(named: Text("Show or minimize task"), actions.toggle)
            // The same width as the close button, so the title stays centred.
            if let task, !state.actionsByComposer {
                TaskDockMenu(store: store, task: task, actions: actions, onCard: state.detailsOpen)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 16)
        // The bar keeps a fixed 60pt height; past this size the title and status would not fit.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

/// The side dock's minimized bar: close, the Task title/status, and actions.
struct TaskDockRail: View {
    let store: CommaStore
    let pane: ConversationPane
    let state: TaskDockState
    let actions: TaskDockActions

    var body: some View {
        let task = store.taskSummary(id: pane.taskID ?? "")
        GeometryReader { geometry in
            let titleHeight = max(44, geometry.size.height - 2 * (44 + 8))
            VStack(spacing: 8) {
                Button(action: actions.close) {
                    CentralIcon("icon-close")
                        .foregroundStyle(CommaTheme.textPrimary)
                        .frame(width: 44, height: 44)
                        .headerGlass(onCard: false)
                }
                .buttonStyle(HeaderButtonStyle(onCard: false))
                .accessibilityLabel("Close task")
                Button(action: actions.toggle) {
                    VStack(spacing: 2) {
                        Text(task?.title ?? String(localized: "Task"))
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                            .foregroundStyle(CommaTheme.textPrimary)
                        if let task {
                            HStack(spacing: 4) {
                                TaskStatusIcon(bucket: task.bucket, size: 11)
                                Text(task.bucket.label).font(.footnote)
                                    .foregroundStyle(CommaTheme.textQuaternary)
                            }
                        }
                    }
                    .frame(width: titleHeight, height: TaskDockViewController.barHeight)
                    .rotationEffect(.degrees(-90))
                    .frame(width: TaskDockViewController.barHeight, height: titleHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(task?.title ?? String(localized: "Task")))
                .accessibilityIdentifier("expandTask")
                if let task { TaskDockMenu(store: store, task: task, actions: actions) }
                else { Color.clear.frame(width: 44, height: 44) }
            }
            .frame(width: TaskDockViewController.barHeight, height: geometry.size.height)
        }
        .padding(.leading, state.sideInset)
        .padding(.top, max(state.topInset, CommaTheme.cardRadius))
        .padding(.bottom, max(state.bottomInset, CommaTheme.cardRadius))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

/// One menu shared by the header and Duo's composer accessory.
struct TaskDockMenu: View {
    let store: CommaStore
    let task: TaskSummary
    let actions: TaskDockActions
    var onCard = false
    @State private var renaming: TaskSummary?
    @State private var sharing: TaskSummary?

    var body: some View {
        Menu {
            Button(action: actions.openBrowser) { Label("Remote browser", image: "icon-globe") }
                .accessibilityIdentifier("openTaskBrowser")
            Divider()
            TaskActionMenuItems(store: store, task: task, rename: { renaming = task }, share: { sharing = task },
                                archive: { actions.archive(task) })
        } label: {
            CentralIcon("icon-more")
                .foregroundStyle(CommaTheme.textPrimary)
                .frame(width: 44, height: 44)
                .headerGlass(onCard: onCard)
        }
        .accessibilityLabel("Task actions")
        .accessibilityIdentifier("taskActions")
        .taskActionSheets(store: store, renaming: $renaming, sharing: $sharing)
    }
}

private extension View {
    /// A header button's glass circle over the transcript. On the open details card, which is glass already, the
    /// button gives its own up and sits on the card as a glyph: no glass on glass.
    @ViewBuilder func headerGlass(onCard: Bool) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(onCard ? .identity : .regular.interactive(), in: Circle())
                .animation(.easeOut(duration: 0.2), value: onCard)
        } else if onCard {
            self
        } else {
            commaGlass(in: Circle())
        }
    }
}

/// The interactive glass answers a press over the transcript; on the card, where the button has no glass, the
/// circle fills the moment a finger lands instead.
private struct HeaderButtonStyle: ButtonStyle {
    let onCard: Bool

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonStyle(scale: 0.9).makeBody(configuration: configuration)
            .background(CommaTheme.bgTertiary.opacity(onCard && configuration.isPressed ? 1 : 0), in: Circle())
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.2), value: configuration.isPressed)
    }
}
