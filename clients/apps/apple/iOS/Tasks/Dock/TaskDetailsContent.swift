import SwiftUI
import CommaCore

/// The open details card's sections: the Task's properties, its Worker, its labels and, on a Loop Task, its Loop.
struct TaskDetailsContent: View {
    let store: CommaStore
    @Bindable var pane: ConversationPane
    let task: TaskSummary?
    /// The card is open (or still closing): its status glyph turns only while it can be seen.
    let shown: Bool
    @State private var historyOpen = false
    @State private var labelsOpen = false
    /// The pills' glyphs and height grow with their text, so large text never sits beside a tiny glyph.
    @ScaledMetric(relativeTo: .subheadline) private var glyph: CGFloat = 18
    @ScaledMetric(relativeTo: .subheadline) private var pillHeight: CGFloat = 32
    /// The small plus glyph's own side bearing, hung outside the column so a leading plus lines up with the title.
    @ScaledMetric(relativeTo: .subheadline) private var plusInset: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let task {
                section("Properties") {
                    FlowLayout(spacing: 6) {
                        status(task)
                        if let origin = TaskOrigin(rawValue: task.origin ?? "") {
                            pill {
                                origin.icon(size: glyph)
                                Text(origin.label)
                            }
                        }
                        if task.origin == "comma", let platform = task.clientPlatform {
                            pill {
                                // The desktop panel shows its laptop glyph for every device.
                                CentralIcon("icon-macbook", size: 18, relativeTo: .subheadline).foregroundStyle(CommaTheme.textQuaternary)
                                Text(platformLabel(platform))
                            }
                        }
                        // The machine a Task a station hosts runs on, and whether it is reached.
                        if let host = task.host {
                            let machine = host.machine ?? String(localized: "Computer")
                            pill {
                                CentralIcon("icon-macbook", size: 18, relativeTo: .subheadline).foregroundStyle(CommaTheme.textQuaternary)
                                Text(host.online == false ? String(localized: "\(machine) · Offline") : machine)
                            }
                        }
                    }
                }
                if let worker = pane.boundWorker {
                    section("Worker") {
                        Button { historyOpen = true } label: {
                            pill {
                                WorkerAvatar(vendor: pane.workerVendor, size: glyph)
                                Text(worker.name.isEmpty ? String(localized: "Worker") : worker.name)
                                CentralIcon("central-chevron-right-small", size: 16, relativeTo: .subheadline)
                                    .foregroundStyle(CommaTheme.textPlaceholder)
                                    .padding(.trailing, -4)
                            }
                        }
                        .buttonStyle(TactileButtonStyle(scale: 0.96))
                        .accessibilityHint("Shows the Worker’s steps")
                        .sheet(isPresented: $historyOpen) {
                            if let target = pane.target {
                                WorkerHistoryView(store: store, target: target, worker: worker, vendor: pane.workerVendor).commaSheet([.large])
                            }
                        }
                    }
                }
                section("Labels") { labels(task) }
                if let loop = task.loop {
                    // Named by its kind, also once the Loop ended.
                    section(Text(verbatim: loop.kind.label)) { facts(loop) }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("taskLoopSection")
                }
            }
        }
        .sheet(isPresented: $labelsOpen) {
            NavigationStack {
                TaskLabelsView(store: store, background: CommaTheme.cardPrimary)
                    .sheetCloseButton { labelsOpen = false }
            }
            .commaSheet([.large])
        }
    }

    // MARK: Status

    /// The Task's status. A Task a member can end by hand opens a menu, as on the desktop: its status, ticked, then
    /// Done and Cancelled, each with its status glyph. Others are a plain property.
    @ViewBuilder private func status(_ task: TaskSummary) -> some View {
        let label = pill {
            TaskStatusIcon(bucket: task.bucket, size: glyph, spins: shown)
            Text(task.bucket.label)
        }
        if task.canSetStatus {
            Menu {
                Button {} label: { Label(task.bucket.label, image: "icon-check") }
                    .disabled(true)
                Divider()
                ForEach(ManualTaskStatus.allCases, id: \.self) { choice in
                    Button(role: choice == .cancelled ? .destructive : nil) {
                        Task { await pane.setStatus(choice) }
                    } label: {
                        Label(choice.bucket.label, image: choice == .completed ? "status-done" : "status-cancelled")
                    }
                }
            } label: { label }
            .menuOrder(.fixed)
            .accessibilityHint("Changes the task’s status")
            .accessibilityIdentifier("taskStatusMenu")
        } else {
            label
        }
    }

    // MARK: Labels

    @ViewBuilder private func labels(_ task: TaskSummary) -> some View {
        let catalog = pane.labelCatalog ?? []
        let applied = (task.labels ?? []).compactMap { id in catalog.first { $0.id == id } }
        let canPick = pane.labelCatalog != nil
        FlowLayout(spacing: 6) {
            ForEach(applied) { label in
                if canPick {
                    labelMenu(task: task, catalog: catalog) { chip(label) }
                } else {
                    chip(label)
                }
            }
            if pane.labelCatalog == nil {
                ProgressView().controlSize(.small).frame(height: pillHeight)
            }
            if canPick, applied.isEmpty {
                labelMenu(task: task, catalog: catalog) {
                    // With no label on the Task the add button says what it does, as the desktop's does; its plus
                    // lines up with the section title. Dimmed while a change saves.
                    HStack(spacing: 2) {
                        CentralIcon("central-plus-small", relativeTo: .subheadline)
                        Text("Add label")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CommaTheme.textQuaternary)
                    .padding(.leading, -plusInset)
                    .frame(minHeight: pillHeight)
                    .contentShape(Rectangle())
                    .opacity(pane.labelsBusy ? 0.4 : 1)
                }
            } else if canPick {
                labelMenu(task: task, catalog: catalog) {
                    // The desktop's add button: a bare glyph on a pill-high circle, dimmed while a change saves.
                    CentralIcon("central-plus-small", relativeTo: .subheadline)
                        .foregroundStyle(CommaTheme.textQuaternary)
                        .frame(width: pillHeight, height: pillHeight)
                        .contentShape(Circle())
                        .opacity(pane.labelsBusy ? 0.4 : 1)
                }
                .accessibilityLabel("Add label")
            }
        }
        .animation(CommaMotion.spatialMove, value: task.labels ?? [])
    }

    private func labelMenu<Label: View>(task: TaskSummary, catalog: [TaskLabel],
                                        @ViewBuilder label: () -> Label) -> some View {
        let applied = Set(task.labels ?? [])
        return Menu {
            // Each label with its colour dot, checked while it is on the Task, like the desktop picker.
            ForEach(catalog) { item in
                Toggle(isOn: Binding(get: { applied.contains(item.id) }, set: { _ in
                    let current = (task.labels ?? []).filter { id in catalog.contains { $0.id == id } }
                    let next = applied.contains(item.id) ? current.filter { $0 != item.id } : current + [item.id]
                    Task { await pane.setLabels(next) }
                })) {
                    SwiftUI.Label { Text(item.name) } icon: { TaskLabelColor.menuDot(item.color) }
                }
            }
            Divider()
            Button { labelsOpen = true } label: {
                SwiftUI.Label { Text("Manage labels…") } icon: { Image(decorative: "icon-tag") }
            }
        } label: { label() }
        .disabled(pane.labelsBusy)
    }

    private func chip(_ label: TaskLabel) -> some View {
        pill(outlined: true) {
            Circle().fill(TaskLabelColor.color(label.color)).frame(width: glyph * 0.45, height: glyph * 0.45)
            Text(label.name)
        }
    }

    // MARK: Loops

    /// The Loop's details, the same rows as desktop Properties (`TaskLoop.details`), as capsules under a heading that
    /// names the trigger's kind: the trigger rule, then a pending, paused or ended state. An active Loop shows only
    /// its rule, or Running when this client cannot read the rule.
    private func facts(_ loop: TaskLoop) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(loop.details(), id: \.self) { detail in
                switch detail {
                case .rule(let rule, let zone):
                    pill {
                        CentralIcon(loop.kind.iconName, size: 18, relativeTo: .subheadline)
                            .foregroundStyle(CommaTheme.textQuaternary)
                        // As desktop writes it: "Every day at 9:00 AM · GMT+8", in full; VoiceOver hears the zone's
                        // name.
                        if let zone {
                            Text(verbatim: "\(rule) · \(zone.offset)").lineLimit(nil)
                                .accessibilityLabel(Text(verbatim: "\(rule) · \(zone.name)"))
                        } else {
                            Text(verbatim: rule).lineLimit(nil)
                        }
                    }
                case .running:
                    pill {
                        CentralIcon("central-infinity", size: 18, relativeTo: .subheadline)
                            .foregroundStyle(CommaTheme.textQuaternary)
                        Text("Running")
                    }
                case .settingUp:
                    pill {
                        CentralIcon("central-circle-dashed", size: 18, relativeTo: .subheadline)
                            .foregroundStyle(CommaTheme.textQuaternary)
                        Text("Setting up")
                    }
                case .paused(let label):
                    pill {
                        CentralIcon("central-pause", size: 14, relativeTo: .subheadline)
                            .frame(width: glyph, height: glyph)
                            .foregroundStyle(CommaTheme.attention)
                        Text(verbatim: label).lineLimit(nil)
                    }
                case .ended:
                    pill {
                        CentralIcon(Self.endedMark(loop.reason), size: 18, relativeTo: .subheadline)
                            .foregroundStyle(CommaTheme.textQuaternary)
                        Text("Ended").foregroundStyle(CommaTheme.textTertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("taskLoopFacts")
    }

    /// The ended capsule's glyph, as the desktop draws it: an x for a Loop cancelled or failed, a check for any other
    /// end.
    private static func endedMark(_ reason: TaskLoop.Reason?) -> String {
        reason == .cancelled || reason == .failed ? "central-circle-x" : "central-circle-check"
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        section(Text(title), content: content)
    }

    private func section<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title.font(.subheadline.weight(.semibold)).foregroundStyle(CommaTheme.textQuaternary)
            content()
        }
    }

    /// The desktop `comma-task-panel-pill`: an icon and a label on the quiet fill the desktop shows on hover, since
    /// a touch screen has no hover. A label chip keeps the desktop's hairline outline instead. A label that wraps
    /// keeps the one-line corner radius.
    private func pill<Content: View>(outlined: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: pillHeight / 2)
        return HStack(spacing: 6) { content() }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(CommaTheme.textPrimary)
            .lineLimit(1)
            .padding(.leading, 10).padding(.trailing, 12)
            .padding(.vertical, 4)
            .frame(minHeight: pillHeight)
            .background { if !outlined { shape.fill(CommaTheme.bgQuaternary) } }
            .overlay { if outlined { shape.strokeBorder(CommaTheme.borderPrimary, lineWidth: 1) } }
            .contentShape(shape)
    }
}
