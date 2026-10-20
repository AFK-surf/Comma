import SwiftUI
import CommaCore

/// What the Task's Worker read, said and ran, from its session ledger: the core's `history` topic, which reads the
/// newest page when the sheet opens, older pages on request (`history.load`), and follows what the Worker does now.
struct WorkerHistoryView: View {
    let store: CommaStore
    let target: ConversationTarget
    let worker: BoundWorker
    /// The maker of the model the Task runs, whose logo stands for the Worker.
    let vendor: String?
    @Environment(\.dismiss) private var dismiss
    @State private var records: [WorkerHistoryRecord] = []
    /// The readable steps, projected once per load, off the main thread.
    @State private var items: [WorkerHistoryItem] = []
    @State private var hasMore = false
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    /// Which read failed, so Retry repeats it.
    @State private var retryOlder = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                // Steps sit on one timeline on the sheet's own surface; each step's tool calls are grouped under it.
                List {
                    if hasMore {
                        Button {
                            Task { await load(older: true) }
                        } label: {
                            // A control in the brand colour, so it never reads as one more step.
                            ZStack {
                                Text("Show earlier steps").font(.subheadline.weight(.semibold)).opacity(loading ? 0 : 1)
                                if loading { ProgressView() }
                            }
                            .foregroundStyle(CommaTheme.brandSolid)
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(loading)
                        .historyRow()
                    }
                    ForEach(items) { item in
                        WorkerHistoryRow(item: item, last: item.id == items.last?.id).id(item.id).historyRow()
                    }
                    if let error {
                        InlineError(message: error, retry: { Task { await load(older: retryOlder) } })
                            .historyRow()
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)
                .scrollContentBackground(.hidden)
                // The first load's spinner and the empty state sit in the middle of the sheet.
                .overlay {
                    if !loaded {
                        ProgressView()
                    } else if items.isEmpty, error == nil {
                        EmptyState(Text("No steps yet"), icon: "central-history")
                    }
                }
                .refreshable { await load(older: false) }
                .task {
                    // Following keeps the live stream open; the first page is read once, as the sheet opens.
                    async let followed: Void = follow()
                    await load(older: false)
                    await followed
                }
                .onChange(of: loaded) { _, loaded in
                    if loaded, let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .pageTitle(verbatim: name) { WorkerAvatar(vendor: vendor, size: 20) }
            .sheetCloseButton { dismiss() }
        }
        .tint(CommaTheme.brandSolid)
    }

    private var name: String { worker.name.isEmpty ? String(localized: "Worker") : worker.name }

    private var topic: [String: Any] {
        ["group": target.groupID, "conversation": target.conversationID, "participant": worker.participantID]
    }

    /// Follows the Worker's history while the sheet shows it.
    private func follow() async {
        var params = topic
        params["topic"] = "history"
        for await value in store.core.subscribe(params, read: { CoreJSON(value: $0) }) {
            guard case .value(let next) = value, let json = next.object else { continue }
            let all = (json.array("records") as? [Any] ?? []) + (json.array("liveRecords") as? [Any] ?? [])
            let read = CoreJSON(value: all as NSArray).decode([WorkerHistoryRecord].self) ?? []
            if read != records {
                records = read
                // Projecting decodes tool payloads and parses dates: keep it off the main thread.
                items = await Task.detached(priority: .userInitiated) { WorkerHistory.items(read) }.value
            }
            hasMore = json.bool("hasMore")
            loading = json.string("status") == "loading"
            loaded = json.string("status") == "ready" || json.string("status") == "error" || !read.isEmpty
            error = switch json.string("error") {
            case "forbidden": String(localized: "You can’t view this Worker’s steps.")
            case "unavailable": String(localized: "Comma could not load the Worker’s steps.")
            default: nil
            }
        }
    }

    private func load(older: Bool) async {
        retryOlder = older
        var params = topic
        params["mode"] = older ? "older" : "latest"
        _ = try? await store.core.call("history.load", params)
    }
}

private extension View {
    /// A history row on the sheet's surface: no separator, no fill of its own, and no gap to the next, so the
    /// timeline's line runs on unbroken.
    func historyRow() -> some View {
        listRowSeparator(.hidden).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
}

/// One step on the Worker's timeline: its glyph beside its kind, on a line that joins it to the next step, what it
/// said, and the tool calls it started, grouped under it.
private struct WorkerHistoryRow: View {
    let item: WorkerHistoryItem
    /// The last step ends the line.
    let last: Bool
    /// The kind line's height, which grows with its text; the glyph sits level with it.
    @ScaledMetric(relativeTo: .footnote) private var line: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 4) {
                CentralIcon(icon, size: 16, relativeTo: .footnote).foregroundStyle(CommaTheme.textTertiary)
                    .frame(height: line)
                Rectangle().fill(CommaTheme.borderPrimary).frame(width: 1).frame(maxHeight: .infinity).opacity(last ? 0 : 1)
            }
            // Type and spacing follow the chat's: a footnote kind line like a sender's name, body text with the
            // chat's line spacing, 6pt within a step and 20pt between steps, as between speakers.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                    Spacer(minLength: 0)
                    if let time = item.startedAt {
                        Text(time, style: .time).font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                    }
                }
                .frame(minHeight: line)
                if !item.summary.isEmpty {
                    Text(item.summary).font(CommaTheme.messageFont).lineSpacing(3)
                        .foregroundStyle(item.kind == .thinking ? CommaTheme.textSecondary : CommaTheme.textPrimary)
                        .lineLimit(item.kind == .model || item.kind == .input ? 12 : 4)
                        .textSelection(.enabled)
                }
                if !item.calls.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(item.calls.enumerated()), id: \.element.id) { index, call in
                            if index > 0 { Divider().overlay(CommaTheme.borderSecondary) }
                            WorkerToolCallRow(call: call)
                        }
                    }
                    .background(GroupedSurface.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 2)
                }
            }
            .padding(.bottom, last ? 8 : 20)
        }
        // The line fills the row however tall its text grows.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var title: LocalizedStringKey {
        switch item.kind {
        case .input: "Received"
        case .model: "Replied"
        case .thinking: "Thought"
        default: "Ran tools"
        }
    }

    /// Central Icons: received into the inbox, a reply bubble, a brain, and a hammer for a step that only ran tools.
    private var icon: String {
        switch item.kind {
        case .input: "central-arrow-inbox"
        case .model: "central-chat-bubble-7"
        case .thinking: "central-brain"
        default: "central-hammer"
        }
    }
}

/// A tool call under the step that started it: how it ended, what it set out to do, its command and its result.
private struct WorkerToolCallRow: View {
    let call: WorkerHistoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // As tall as the summary's first line, level with it.
            CentralIcon(icon, size: 18, relativeTo: .subheadline).foregroundStyle(tint)
                .accessibilityLabel(Text(status))
            VStack(alignment: .leading, spacing: 3) {
                Text(call.summary.isEmpty ? (call.tool ?? "") : call.summary).font(.subheadline.weight(.medium))
                    .foregroundStyle(CommaTheme.textPrimary).lineLimit(2)
                if let command = call.command ?? (call.summary.isEmpty ? nil : call.tool) {
                    Text(command).font(.footnote.monospaced()).foregroundStyle(CommaTheme.textTertiary).lineLimit(2)
                }
                if let outcome = call.outcome {
                    Text(outcome).font(.footnote)
                        .foregroundStyle(call.kind == .failure ? CommaTheme.errorPrimary : CommaTheme.textSecondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(CommaTheme.bubblePadding)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    private var status: LocalizedStringKey {
        switch call.kind {
        case .running: "Running"
        case .success: "Tool finished"
        case .failure: "Tool failed"
        case .cancelled: "Cancelled"
        case .result: "Tool result"
        default: "Called a tool"
        }
    }

    /// Central Icons: a circled check, a warning triangle and a cross for how a call ended, the desktop's more glyph
    /// while it runs.
    private var icon: String {
        switch call.kind {
        case .running, .call: "icon-more"
        case .success, .result: "central-circle-check"
        case .failure: "central-exclamation-triangle"
        default: "icon-cross-small"
        }
    }

    private var tint: Color {
        switch call.kind {
        case .failure: CommaTheme.errorPrimary
        case .success, .result: CommaTheme.successPrimary
        default: CommaTheme.textQuaternary
        }
    }
}
