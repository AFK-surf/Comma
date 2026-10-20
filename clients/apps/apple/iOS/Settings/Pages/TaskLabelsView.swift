import SwiftUI
import CommaCore

/// The Group's Task label catalog (the core's `taskLabels`): add, edit and delete labels, decide agent proposals, and
/// choose whether agent proposals need approval. The core reads the catalog again after each change.
struct TaskLabelsView: View {
    let store: CommaStore
    /// The page colour; a sheet passes its own surface so the page matches it.
    var background = GroupedSurface.page
    @State private var catalog: TaskLabelCatalog?
    @State private var action = PageAction()
    @State private var editing: LabelDraft?

    var body: some View {
        SettingsPage(background: background) {
            if let error = action.error { InlineError(message: error, dismiss: { action.error = nil }) }
            if let catalog {
                SettingsSection(Text("Suggested by Comma")) {
                    ForEach(catalog.pendingProposals) { proposal in
                        ProposalRow(proposal: proposal) { approve in
                            run("taskLabels.resolve", ["proposal": proposal.id, "decision": approve ? "approve" : "reject"])
                        }
                    }
                }
                labels(catalog)
                SettingsSection(Text("Comma’s label suggestions"), footer: Text("Comma can suggest new labels and label tasks while it works.")) {
                    policy("ask", Text("Ask me first"), in: catalog)
                    policy("auto", Text("Apply automatically"), in: catalog)
                }
            } else if action.error == nil {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
            }
        }
        .disabled(action.busy)
        .pageTitle("Task labels")
        .refreshable { _ = try? await store.core.call("taskLabels.refresh", ["group": groupID]) }
        .task(id: groupID) { await follow() }
        .sheet(item: $editing) { draft in
            LabelEditor(draft: draft, colors: catalog?.colors ?? []) { result in
                editing = nil
                var fields: [String: Any] = ["name": result.name, "color": result.color]
                if let description = result.description { fields["description"] = description }
                if let id = result.id {
                    fields["label"] = id
                    run("taskLabels.update", fields)
                } else {
                    run("taskLabels.create", fields)
                }
            }
        }
    }

    private func labels(_ catalog: TaskLabelCatalog) -> some View {
        SettingsSection(Text("Labels"), footer: Text("Deleting a label removes it from every task.")) {
            if catalog.labels.isEmpty {
                Text("No labels").font(.body).foregroundStyle(CommaTheme.textTertiary).surfaceRowFrame()
            }
            ForEach(catalog.labels) { label in
                LabelRow(label: label, edit: { editing = LabelDraft(label: label) }) {
                    run("taskLabels.delete", ["label": label.id])
                }
            }
            Button { editing = LabelDraft(color: catalog.colors.first ?? "blue") } label: {
                SettingsRow(Text("Add label"), icon: "icon-plus", role: .action)
            }
            .buttonStyle(SurfaceRowButtonStyle())
        }
    }

    /// One answer to whether Comma's suggestions wait for the member, checked when it is the current one.
    private func policy(_ value: String, _ title: Text, in catalog: TaskLabelCatalog) -> some View {
        let chosen = catalog.approvalPolicy == value
        return Button {
            guard !chosen else { return }
            run("taskLabels.setPolicy", ["policy": value])
        } label: {
            SettingsRow(title) { SettingsCheckmark(shown: chosen) }
        }
        .buttonStyle(SurfaceRowButtonStyle())
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var groupID: String { store.workspace?.groupID ?? "" }

    /// Follows the catalog while the page shows it.
    private func follow() async {
        guard !groupID.isEmpty else { return }
        let updates = store.core.subscribe(["topic": "taskLabels", "group": groupID]) { value in CoreJSON(value: value) }
        for await value in updates {
            guard case .value(let next) = value, let json = next.object else { continue }
            if let read = CoreJSON(value: json.object("catalog")).decode(TaskLabelCatalog.self) { catalog = read }
            if json.bool("error"), catalog == nil { action.error = String(localized: "Comma could not load the labels.") }
        }
    }

    /// One of the core's label changes for the Group.
    private func run(_ name: String, _ params: [String: Any]) {
        guard !groupID.isEmpty else { return }
        var all = params
        all["group"] = groupID
        let core = store.core
        let box = SendableParams(all)
        action.run { _ = try await core.call(name, box.value) }
    }
}

/// Params built on the main actor for a call made from a task.
struct SendableParams: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// A label: its colour, name and description. Tapping it edits it; its menu, or a long press, edits or
/// deletes it, as the desktop's label menu does.
private struct LabelRow: View {
    let label: TaskLabel
    let edit: () -> Void
    let delete: () -> Void
    @ScaledMetric(relativeTo: .body) private var slot: CGFloat = 20

    var body: some View {
        Button(action: edit) {
            HStack(spacing: 8) {
                Circle().fill(TaskLabelColor.color(label.color)).frame(width: 10, height: 10)
                    .frame(width: slot, height: slot)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.name).font(.body).foregroundStyle(CommaTheme.textPrimary)
                    if let description = label.description, !description.isEmpty {
                        Text(description).font(.footnote).foregroundStyle(CommaTheme.textTertiary).lineLimit(2)
                    }
                }
                .multilineTextAlignment(.leading)
            }
            .padding(.trailing, 32)
            .surfaceRowFrame()
        }
        .buttonStyle(SurfaceRowButtonStyle())
        // VoiceOver reaches the label before its menu, as the eye does.
        .accessibilitySortPriority(1)
        .overlay(alignment: .trailing) {
            Menu { items } label: {
                CentralIcon("inbox-actions", size: 20).foregroundStyle(CommaTheme.textSecondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .padding(.trailing, GroupedSurface.inset - 12)
            .accessibilityLabel(Text("Actions for \(label.name)"))
        }
        .contextMenu { items }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var items: some View {
        Button(action: edit) { Label("Edit label", image: "central-edit-big") }
        Button(role: .destructive, action: delete) {
            Label { Text("Delete") } icon: { MenuIcon.destructive("central-trash-can") }
        }
    }
}

/// A label change Comma suggested: what it does, the labels it names, why, and the member's answer.
private struct ProposalRow: View {
    let proposal: TaskLabelProposal
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline).font(.body).foregroundStyle(CommaTheme.textPrimary)
            if let labels = proposal.payload?.labels, !labels.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(labels.prefix(4).enumerated()), id: \.offset) { _, label in
                        HStack(spacing: 5) {
                            Circle().fill(TaskLabelColor.color(label.color)).frame(width: 8, height: 8)
                            Text(label.name)
                        }
                        .font(.subheadline.weight(.medium)).foregroundStyle(CommaTheme.textPrimary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(GroupedSurface.ink, in: Capsule())
                    }
                }
            }
            if let summary = proposal.summary, !summary.isEmpty {
                Text(summary).font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
            }
            HStack(spacing: 8) {
                answer("Approve", fill: CommaTheme.brandSolid, ink: .white) { decide(true) }
                answer("Dismiss", fill: GroupedSurface.ink, ink: CommaTheme.textPrimary) { decide(false) }
            }
            .padding(.top, 4)
        }
        .surfaceRowFrame(vertical: 12)
    }

    /// A pill that answers the proposal, finger-sized though it draws 32pt tall.
    private func answer(_ title: LocalizedStringKey, fill: Color, ink: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(ink)
                .padding(.horizontal, 14).frame(minHeight: 32)
                .background(fill, in: Capsule())
                .contentShape(Capsule().inset(by: -6))
        }
        .buttonStyle(TactileButtonStyle())
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
