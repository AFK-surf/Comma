import SwiftUI
import CommaCore

/// What the Task's Worker read, said and ran, from its session ledger. Reads are explicit: the first page on
/// open, older pages on request, and pull to refresh. It opens no event stream, so the open Task keeps the
/// phone's two foreground streams (Home and the Task feed).
struct WorkerHistoryView: View {
    let store: CommaStore
    let target: ConversationTarget
    let worker: BoundWorker
    @Environment(\.dismiss) private var dismiss
    @State private var records: [WorkerHistoryRecord] = []
    @State private var nextBefore: String?
    @State private var hasMore = false
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if hasMore {
                        Button {
                            Task { await load(older: true) }
                        } label: {
                            Text("Show earlier steps").frame(maxWidth: .infinity)
                        }
                        .disabled(loading)
                    }
                    let items = WorkerHistory.items(records)
                    if loaded, items.isEmpty, error == nil {
                        Text("No steps yet").foregroundStyle(CommaTheme.textQuaternary)
                            .frame(maxWidth: .infinity).listRowBackground(Color.clear)
                    }
                    ForEach(items) { item in
                        WorkerHistoryRow(item: item).id(item.id)
                    }
                    if let error {
                        Text(error).foregroundStyle(CommaTheme.errorPrimary)
                    }
                    if loading, !loaded { ProgressView().frame(maxWidth: .infinity) }
                }
                .listStyle(.plain)
                .refreshable { await load(older: false) }
                .task {
                    await load(older: false)
                    if let last = WorkerHistory.items(records).last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .navigationTitle(worker.name.isEmpty ? String(localized: "Worker") : worker.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { WorkerAvatar(identity: worker.actorID ?? worker.participantID, size: 24) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(CommaTheme.brandSolid)
    }

    private func load(older: Bool) async {
        guard !loading, !older || nextBefore != nil else { return }
        loading = true
        defer { loading = false; loaded = true }
        do {
            let page = try await store.client.workerHistory(target: target, participantID: worker.participantID,
                                                            before: older ? nextBefore : nil)
            records = WorkerHistory.merge(records, page.records)
            // A refresh of the newest page keeps the older cursor already reached.
            if older || nextBefore == nil || records.count == page.records.count {
                nextBefore = page.nextBefore
                hasMore = page.hasMore
            }
            error = nil
        } catch {
            self.error = (error as? CommaError).flatMap { if case .http(403, _, _) = $0 { String(localized: "You can’t view this Worker’s steps.") } else { nil } }
                ?? error.localizedDescription
        }
    }
}

private struct WorkerHistoryRow: View {
    let item: WorkerHistoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(CommaTheme.textSecondary)
                    if let tool = item.tool, !tool.isEmpty {
                        Text(tool).font(.system(size: 12).monospaced()).foregroundStyle(CommaTheme.textQuaternary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let time = item.startedAt {
                        Text(time, style: .time).font(.system(size: 11)).foregroundStyle(CommaTheme.textPlaceholder)
                    }
                }
                if !item.summary.isEmpty {
                    Text(item.summary).font(.system(size: 14))
                        .foregroundStyle(item.kind == .thinking ? CommaTheme.textQuaternary : CommaTheme.textPrimary)
                        .lineLimit(item.kind == .model || item.kind == .input ? 12 : 4)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringKey {
        switch item.kind {
        case .input: "Received"
        case .model: "Replied"
        case .thinking: "Thought"
        case .call: "Called a tool"
        case .running: "Running"
        case .success: "Tool finished"
        case .failure: "Tool failed"
        case .cancelled: "Cancelled"
        case .result: "Tool result"
        }
    }

    private var symbol: String {
        switch item.kind {
        case .input: "tray.and.arrow.down"
        case .model: "text.bubble"
        case .thinking: "brain"
        case .call, .result: "wrench.and.screwdriver"
        case .running: "ellipsis"
        case .success: "checkmark"
        case .failure: "exclamationmark"
        case .cancelled: "xmark"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .failure: CommaTheme.errorPrimary
        case .success: CommaTheme.successPrimary
        case .model, .input: CommaTheme.brandSolid
        default: CommaTheme.textQuaternary
        }
    }
}
