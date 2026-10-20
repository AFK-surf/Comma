import SwiftUI
import PhotosUI
import QuickLook
import CommaCore

/// One conversation: the transcript, the composer floating over its bottom edge, and the attachment card.
/// The composer and the + button's touch are views and a model of their own, so typing or a finger moving on
/// the + never re-renders this view or the transcript; this view updates when the conversation does, and when the
/// composer takes or gives up the keyboard.
struct PhoneConversationView: View {
    let store: CommaStore
    let pane: ConversationPane
    var composerFocus: FocusState<Bool>.Binding? = nil
    @State var previewURL: URL?
    @State var previewDirectory: URL?
    @State var downloading = false
    @State var photos: [PhotosPickerItem] = []
    @State var filePickerOpen = false
    @State var allPhotosOpen = false
    /// Picked photos or files are still being read, from iCloud or the library.
    @State var preparing = false
    @State private var attachments = AttachmentModel()
    @State private var flight = OutgoingFlightController()
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The router chat's, which says whether it is open; a Task's conversation has none.
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    /// A Task's conversation under its minimized bar.
    @Environment(\.ambientMotionPaused) private var covered

    private var focus: FocusState<Bool>.Binding { composerFocus ?? $composerFocused }

    var body: some View {
        // Derived once per pass.
        let rows = ChatTranscriptModel.rows(for: pane)
        VStack(spacing: 0) {
            if pane.loading && pane.messages.isEmpty {
                Spacer()
                ProgressView().controlSize(.regular)
                Spacer()
            } else if pane.conversation == nil, pane.error != nil || pane.state.problem != nil {
                failedState
            } else if rows.isEmpty {
                emptyState
            } else {
                ChatTranscriptView(
                    rows: rows, pane: pane, store: store, isTask: pane.conversation?.isTask == true,
                    hasOlderMessages: pane.hasOlderMessages, loadingMore: pane.loadingMore,
                    flight: reduceMotion ? nil : flight, composerFocused: focus.wrappedValue,
                    onUserScroll: { focus.wrappedValue = false },
                    openAttachment: { message, attachment in
                        guard let index = attachment.index else { return }
                        Task { await download(messageID: message.id, index: index, name: attachment.name) }
                    },
                    replyThread: pane.replyThread,
                    onReplyOpened: { focus.wrappedValue = true })
                .equatable()
                .id(pane.target)
            }
        }
        // The full width, so the page's colour is under the loading spinner too and not a column the spinner's width.
        .frame(maxWidth: .infinity)
        .background(CommaTheme.bgPrimary)
        // The conversation's failures are the app's toast while the conversation is on screen.
        .onChange(of: failure, initial: true) { old, failure in
            report(failure, fresh: old.revision != failure.revision)
        }
        .onDisappear { store.toasts.withdraw(toastID) }
        .overlay(alignment: .top) {
            if downloading { downloadingPill.padding(.top, 8).transition(.opacity) }
        }
        .animation(CommaMotion.stateChange, value: downloading)
        .floatingBottomBar {
            ConversationComposer(store: store, pane: pane, focus: focus, flight: flight, preparing: preparing,
                                 button: attachments)
        }
        .coordinateSpace(.chat)
        .overlay { OutgoingFlightOverlay(controller: flight) }
        .overlay { AttachmentOverlay(button: attachments, actions: attachmentActions) }
        .photosPicker(isPresented: $allPhotosOpen, selection: $photos, maxSelectionCount: max(1, pane.attachmentRoom),
                      matching: .images, preferredItemEncoding: .compatible)
        .fileImporter(isPresented: $filePickerOpen, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await uploadFiles(result) }
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, value in
            if value == nil, let directory = previewDirectory {
                previewDirectory = nil
                Task { await AttachmentFile.remove(directory) }
            }
        }
        .onChange(of: pane.target) { _, _ in previewURL = nil }
        .onChange(of: photos) { _, values in
            Task { await uploadPhotos(values) }
        }
    }

    /// The failure the toast reports, and whether the conversation is on screen to report it.
    private struct Failure: Equatable {
        let message: String?
        let origin: ConversationPane.ErrorOrigin?
        /// Advances with each failure, so the same one again still reaches the toast.
        let revision: Int
        let onScreen: Bool
        /// The conversation never loaded, so the page says so itself, with its own Try Again (`failedState`).
        let inPlace: Bool
    }

    private var failure: Failure {
        // The router chat is off screen under a raised Task as much as behind the tabs.
        let onScreen = pane.isTask ? !covered : navigation.map { $0.routerOpen && !$0.taskRaised } == true
        return Failure(message: pane.error, origin: pane.errorOrigin, revision: pane.errorRevision, onScreen: onScreen,
                       inPlace: pane.conversation == nil)
    }

    private static let toastPrefix = "conversation."
    private var toastID: String { Self.toastPrefix + (pane.taskID ?? "router") }

    /// Shows the conversation's failure as the toast, or takes the toast away once the failure clears or the
    /// conversation leaves the screen, which keeps the failure for when it comes back. A send that did not go says
    /// so on its own row, with its own Retry, and needs no toast. Retry reads the conversation again, so it is offered
    /// only for a failed read, and not when the page already offers it; a refused change is made again, a file
    /// chosen again, and both answer the member's own action with the error haptic when they happen (`fresh`), not
    /// each time the conversation comes back on screen to them.
    private func report(_ failure: Failure, fresh: Bool) {
        guard let message = failure.message, failure.onScreen, !failure.origin.isSend else {
            return store.toasts.withdraw(toastID)
        }
        // Only one conversation is on screen at a time, so another's toast belongs to one leaving it: it goes without
        // counting as dismissed, which keeps that conversation's failure for when it comes back.
        if let shown = store.toasts.current?.id, shown != toastID, shown.hasPrefix(Self.toastPrefix) {
            store.toasts.withdraw(shown)
        }
        let retry = failure.origin == .server && !failure.inPlace ? Toast.Action(title: String(localized: "Retry")) {
            Task { await pane.retryRead() }
        } : nil
        store.toasts.show(Toast(id: toastID, intent: .error, message: message, action: retry,
                                answersMember: fresh && (failure.origin == .local || failure.origin == .request),
                                // The page's own failed state stays after its toast while the read problem lasts.
                                dismissed: { pane.dismissError() }))
    }

    /// A glass status pill while an attachment downloads for Quick Look.
    private var downloadingPill: some View {
        HStack(spacing: 6) {
            CentralIcon("central-arrow-inbox", size: 16, relativeTo: .subheadline)
            Text("Opening attachment…").font(.subheadline.weight(.medium))
        }
        .foregroundStyle(CommaTheme.textSecondary)
        .padding(.horizontal, 14).frame(minHeight: 36)
        .commaGlass(in: Capsule())
        .accessibilityElement(children: .combine)
    }

    /// A conversation that could not be read at all: the toast says why, the page what to do.
    private var failedState: some View {
        ConversationFailedState(title: Text(pane.isTask ? "Couldn’t load this task" : "Couldn’t load the conversation")) {
            Task { await pane.retryRead() }
        }
    }

    private var emptyState: some View {
        // The pane knows it is a Task before its conversation loads, and even if loading fails.
        let isTask = pane.isTask
        // Where the message does not fit (an iPhone in landscape with the keyboard up), it gives way rather than
        // overflow the conversation under its header.
        return ViewThatFits(in: .vertical) {
            EmptyState(Text(isTask ? "No updates yet" : "What would you like to do?"),
                       description: Text(isTask ? "Comma posts its progress here as it works. Reply to add details or change the plan."
                                                : "Ask a question or give Comma a task. You can follow each task on Home.")) {
                CommaMark(size: CommaTheme.emptyStateIcon)
            }
            Color.clear
        }
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = false }
    }
}

/// A conversation, or the chat the app opens on, that could not be read: what failed and Try Again, which stays where
/// the explanation does not fit (large text, landscape with the keyboard up). The toast says why.
struct ConversationFailedState: View {
    let title: Text
    let retry: () -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            EmptyState(title, icon: "central-exclamation-triangle",
                       description: Text("Check your connection, then try again.")) {
                Button("Try Again", action: retry)
            }
            Button("Try Again", action: retry)
                .buttonStyle(CommaButtonStyle(hierarchy: .secondary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("conversationFailed")
    }
}

private extension Optional where Wrapped == ConversationPane.ErrorOrigin {
    var isSend: Bool { if case .send = self { true } else { false } }
}
