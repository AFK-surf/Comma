import SwiftUI
import CommaCore

// The watch transcript for the router chat or a task, with its compact composer.
struct WatchConversationView: View {
    @Bindable var pane: ConversationPane
    @State private var confirmingCancel = false

    var body: some View {
        // Built once per update; every use below reads this one projection.
        let rows = ChatTranscriptModel.rows(for: pane)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let task = pane.conversation, task.isTask {
                        TaskStatusLabel(status: task.status).padding(.bottom, 8)
                    }
                    if pane.loading && rows.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                    if let error = pane.error {
                        Text(error).font(.footnote).foregroundStyle(CommaTheme.errorPrimary).padding(.bottom, 6)
                    }
                    if pane.hasOlderMessages {
                        Button("Earlier messages") { Task { await pane.loadEarlierMessages() } }
                            .disabled(pane.loadingMore).padding(.bottom, 8)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row)
                            .padding(.top, index == 0 ? 0 : (row.isUser == rows[index - 1].isUser ? 4 : 12))
                            .id(row.id)
                    }
                    composer.padding(.top, 14).id(composerID)
                    if let task = pane.conversation, task.canSetStatus {
                        Button { Task { await pane.setStatus(.completed) } } label: {
                            Label { Text("Mark done") } icon: { CentralIcon("central-circle-check", relativeTo: .body) }
                        }
                        .tint(CommaTheme.successPrimary).padding(.top, 6)
                        Button { confirmingCancel = true } label: {
                            Label { Text("Cancel task") } icon: { CentralIcon("central-circle-x", relativeTo: .body) }
                        }
                        .confirmationDialog("Cancel this task?", isPresented: $confirmingCancel) {
                            Button("Cancel task", role: .destructive) { Task { await pane.setStatus(.cancelled) } }
                        }
                    }
                }
                .padding(.horizontal, 2).padding(.bottom, 8)
                .animation(CommaMotion.sendPosition, value: rows.map(\.id))
            }
            // The last row's content, not only its row: a streamed reply commits into its draft's row, and the
            // end of the committed reply comes into view then.
            .onChange(of: rows.last?.relationshipID) { _, _ in
                if let id = rows.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
            // Opening a conversation lands on its latest message with the composer in view, including once the
            // first page arrives.
            .onAppear { proxy.scrollTo(composerID, anchor: .bottom) }
            .onChange(of: rows.isEmpty) { _, empty in
                if !empty { proxy.scrollTo(composerID, anchor: .bottom) }
            }
        }
        .navigationTitle(pane.conversation?.isTask == true ? "Task" : "Comma")
    }


    @ViewBuilder private func rowView(_ row: ChatRow) -> some View {
        HStack(spacing: 0) {
            if row.isUser { Spacer(minLength: 16) }
            VStack(alignment: row.isUser ? .trailing : .leading, spacing: 4) {
                if row.isDraft && row.text.isEmpty {
                    ThinkingBubble(label: row.activityLabel ?? String(localized: "Thinking…"), compact: true)
                } else if !row.text.isEmpty {
                    MessageBubbles(text: row.text, isUser: row.isUser, tail: row.bubbleTail, compact: true)
                }
                if let message = row.message { MessageExtras(message: message) }
                if case .pending(_, _, let failed, let attemptID) = row.content, failed {
                    Button("Retry") {
                        if let attempt = pane.pendingSends.first(where: { $0.id == attemptID }) {
                            Task { await pane.retry(attempt) }
                        }
                    }
                    .font(.footnote).foregroundStyle(CommaTheme.errorPrimary)
                }
            }
            if !row.isUser { Spacer(minLength: 16) }
        }
        .transition(row.isUser ? .move(edge: .bottom).combined(with: .opacity) : .opacity)
    }

    private let composerID = "composer"

    /// A link straight into the system text entry, which carries Cancel at its top left and, through the
    /// submit label, Send at its top right. A TextField would draw its own rounded field inside the glass.
    private var composer: some View {
        TextFieldLink(prompt: Text("Message")) {
            Text(pane.draftText.isEmpty ? String(localized: "Message") : pane.draftText)
                .font(.system(size: 15))
                .foregroundStyle(pane.draftText.isEmpty ? CommaTheme.textTertiary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, 14)
                .contentShape(Capsule())
                .modifier(WatchComposerGlass())
        } onSubmit: { text in
            pane.draftText = text
            if canSend { Task { await pane.send() } }
        }
        .submitLabel(.send)
        .buttonStyle(.plain)
        .disabled(!pane.canSend)
    }

    private var canSend: Bool {
        pane.canSend && !pane.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Liquid Glass from watchOS 26; a translucent capsule before it.
private struct WatchComposerGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.white.opacity(0.14), in: Capsule())
        }
    }
}
