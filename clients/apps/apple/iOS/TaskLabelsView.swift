import SwiftUI
import CommaCore

/// The Group's Task label catalog: add, edit and delete labels, decide agent proposals, and choose whether
/// agent proposals need approval. Every change returns the whole catalog, which replaces the local copy.
struct TaskLabelsView: View {
    let store: CommaStore
    @State private var catalog: TaskLabelCatalog?
    @State private var busy = false
    @State private var error: String?
    @State private var editing: LabelDraft?

    var body: some View {
        Form {
            if let catalog {
                let pending = catalog.pendingProposals
                if !pending.isEmpty {
                    Section {
                        ForEach(pending) { proposal in
                            ProposalRow(proposal: proposal, catalog: catalog) { approve in
                                run { try await store.client.resolveTaskLabelProposal(groupID: groupID, proposalID: proposal.id, approve: approve) }
                            }
                        }
                    } header: {
                        Text("Suggested by Comma")
                    }
                }
                Section {
                    if catalog.labels.isEmpty {
                        Text("No labels").foregroundStyle(CommaTheme.textQuaternary)
                    }
                    ForEach(catalog.labels) { label in
                        Button {
                            editing = LabelDraft(label: label)
                        } label: {
                            HStack(spacing: 10) {
                                Circle().fill(TaskLabelColor.color(label.color)).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(label.name).foregroundStyle(CommaTheme.textPrimary)
                                    if let description = label.description, !description.isEmpty {
                                        Text(description).font(.footnote).foregroundStyle(CommaTheme.textQuaternary).lineLimit(2)
                                    }
                                }
                            }
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                run { try await store.client.deleteTaskLabel(groupID: groupID, labelID: label.id) }
                            }
                        }
                    }
                    Button("Add label", systemImage: "plus") {
                        editing = LabelDraft(color: catalog.colors.first ?? "blue")
                    }
                } header: {
                    Text("Labels")
                } footer: {
                    Text("Deleting a label removes it from every task.")
                }
                Section {
                    Picker("Comma’s label suggestions", selection: Binding(get: { catalog.approvalPolicy }, set: { policy in
                        run { try await store.client.setTaskLabelApprovalPolicy(groupID: groupID, policy: policy) }
                    })) {
                        Text("Ask me first").tag("ask")
                        Text("Apply automatically").tag("auto")
                    }
                } footer: {
                    Text("Comma can suggest new labels and label tasks while it works.")
                }
            } else if error == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            if let error {
                Section { Text(error).foregroundStyle(CommaTheme.errorPrimary) }
            }
        }
        .disabled(busy)
        .tint(CommaTheme.brandSolid)
        .navigationTitle("Task labels")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $editing) { draft in
            LabelEditor(draft: draft, colors: catalog?.colors ?? []) { result in
                editing = nil
                run {
                    if let id = result.id {
                        try await store.client.updateTaskLabel(groupID: groupID, labelID: id, name: result.name,
                                                              color: result.color, description: result.description)
                    } else {
                        try await store.client.createTaskLabel(groupID: groupID, name: result.name,
                                                              color: result.color, description: result.description)
                    }
                }
            }
        }
    }

    private var groupID: String { store.workspace?.groupID ?? "" }

    private func load() async {
        guard !groupID.isEmpty else { return }
        do { install(try await store.client.taskLabels(groupID: groupID)) } catch { self.error = error.localizedDescription }
    }

    private func run(_ operation: @escaping () async throws -> TaskLabelCatalog) {
        guard !busy, !groupID.isEmpty else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                install(try await operation())
                // Proposals that apply labels and deletions change Tasks too.
                store.scheduleTaskListRefresh()
                await store.task?.refresh()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func install(_ value: TaskLabelCatalog) {
        catalog = value
        error = nil
        store.task?.installLabelCatalog(value.labels)
    }
}

struct LabelDraft: Identifiable {
    let id = UUID()
    var labelID: String?
    var name = ""
    var color: String
    var description = ""
    init(label: TaskLabel) { labelID = label.id; name = label.name; color = label.color; description = label.description ?? "" }
    init(color: String) { self.color = color }
}

private struct LabelEditor: View {
    struct Result { let id: String?; let name: String; let color: String; let description: String? }
    @State var draft: LabelDraft
    let colors: [String]
    let save: (Result) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    TextField("Description (optional)", text: $draft.description, axis: .vertical).lineLimit(1...4)
                }
                Section("Colour") {
                    let options = colors.isEmpty ? ["blue", "indigo", "purple", "pink", "orange", "warning", "success", "error", "brand"] : colors
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                        ForEach(options.contains(draft.color) ? options : options + [draft.color], id: \.self) { color in
                            Button {
                                draft.color = color
                            } label: {
                                Circle().fill(TaskLabelColor.color(color)).frame(width: 30, height: 30)
                                    .overlay {
                                        if color == draft.color {
                                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(color))
                            .accessibilityAddTraits(color == draft.color ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(draft.labelID == nil ? "New label" : "Edit label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
                        save(Result(id: draft.labelID, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    color: draft.color, description: draft.labelID == nil && description.isEmpty ? nil : description))
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(CommaTheme.brandSolid)
        .presentationDetents([.medium, .large])
    }
}

private struct ProposalRow: View {
    let proposal: TaskLabelProposal
    let catalog: TaskLabelCatalog
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline).font(.subheadline.weight(.medium))
            if let labels = proposal.payload?.labels, !labels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(labels.prefix(4).enumerated()), id: \.offset) { _, label in
                        HStack(spacing: 4) {
                            Circle().fill(TaskLabelColor.color(label.color)).frame(width: 8, height: 8)
                            Text(label.name).font(.footnote)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(CommaTheme.borderPrimary))
                    }
                }
            }
            if let summary = proposal.summary, !summary.isEmpty {
                Text(summary).font(.footnote).foregroundStyle(CommaTheme.textQuaternary)
            }
            HStack {
                Button("Approve") { decide(true) }.buttonStyle(.borderedProminent)
                Button("Dismiss") { decide(false) }.buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var headline: String {
        let title = proposal.payload?.conversationTitle
        switch proposal.op {
        case "create": return String(localized: "Add new labels")
        case "update": return String(localized: "Change labels")
        case "delete": return String(localized: "Delete labels")
        case "apply":
            return title.map { String(localized: "Label “\($0)”") } ?? String(localized: "Label a task")
        default: return String(localized: "Label change")
        }
    }
}
