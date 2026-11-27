import SwiftUI
import CommaCore

/// One person: who they are, the two ways to work with them (a Collaborative Task with them, or a request to their
/// Comma when they take requests), and everything the two of you have to do with each other, the latest first.
/// The more menu sets how their requests to the member's workspace are taken, or stops them.
struct PersonView: View {
    let store: CommaStore
    let model: PeopleModel
    let personID: String
    @Environment(\.dismiss) private var dismiss
    @State private var collaborating = false
    @State private var requesting: NSDictionary?
    @State private var invitation: PeopleCollaboration?
    @State private var stopping = false
    @State private var deletingRequest: String?

    var body: some View {
        Group {
            if let person = model.person(personID) { page(person) }
            // Someone who left People (their access revoked) leaves the page with them.
            else { Color.clear.onAppear { dismiss() } }
        }
        .background(CommaTheme.bgPrimary)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func page(_ person: PeoplePerson) -> some View {
        let rows = rows(person)
        return ScrollView {
            VStack(spacing: 28) {
                header(person)
                if rows.isEmpty {
                    Text("Tasks you share with \(person.name) show here.")
                        .font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else {
                    SettingsSection(Text("Tasks")) { ForEach(rows) { $0.view } }
                }
            }
            .padding(.horizontal, GroupedSurface.margin).padding(.top, 8).padding(.bottom, 24)
            .frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .refreshable { await model.refresh() }
        .toolbar { if person.sends != nil { ToolbarItem(placement: .topBarTrailing) { menu(person) } } }
        .sheet(isPresented: $collaborating) { CollaborateSheet(store: store, model: model, initial: [person.id]) }
        .sheet(item: Binding(get: { requesting.map(RequestTarget.init) }, set: { requesting = $0?.target })) { target in
            PersonRequestSheet(model: model.requests, person: person, target: target.target)
        }
        .sheet(item: $invitation) { item in InvitationSheet(store: store, model: model, item: item) }
        .confirmationDialog("Stop requests from \(person.name)?", isPresented: $stopping, titleVisibility: .visible) {
            Button("Stop requests", role: .destructive) {
                guard let grant = person.sends?.grant else { return }
                Task { _ = await model.scope.perform("taskRequests.revokeGrant", ["grant": grant]) }
            }
        } message: { Text("Requests from them that still wait will be declined.") }
        .confirmationDialog("Delete this request?", isPresented: Binding(get: { deletingRequest != nil }, set: { if !$0 { deletingRequest = nil } }), titleVisibility: .visible) {
            if let requestID = deletingRequest {
                Button("Delete request", role: .destructive) {
                    deletingRequest = nil
                    Task { _ = await model.scope.perform("taskRequests.hide", ["request": requestID], workspaceParameter: false) }
                }
            }
        } message: { Text("It will be removed from your lists across devices. The recipient's task is not affected.") }
        .accessibilityIdentifier("person-" + person.id)
    }

    /// Their face and name, then the two ways to work with them, side by side at one width.
    private func header(_ person: PeoplePerson) -> some View {
        VStack(spacing: 16) {
            PersonAvatar(store: store, name: person.name, source: person.avatar, size: 88)
            VStack(spacing: 4) {
                Text(verbatim: person.name).font(.title2.weight(.semibold)).foregroundStyle(CommaTheme.textPrimary)
                    .multilineTextAlignment(.center)
                if let email = person.email, email != person.name {
                    Text(verbatim: email).font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                }
            }
            HStack(spacing: 12) {
                action("Collaborate", icon: "icon-people", id: "personCollaborate") { collaborating = true }
                if let target = model.target(for: person) {
                    action("Request their Comma", short: "Request", icon: "central-arrow-up-right", id: "personRequest") {
                        requesting = target
                    }
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// One of the two ways: a glyph beside its name on a rounded surface. Both names keep one type size; a name too
    /// long for its half shows its short form instead of shrinking.
    private func action(_ title: LocalizedStringKey, short: LocalizedStringKey? = nil, icon: String, id: String,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 6) {
                CentralIcon(icon, size: 18, relativeTo: .body).foregroundStyle(CommaTheme.textPrimary)
                ViewThatFits(in: .horizontal) {
                    Text(title).fixedSize()
                    Text(short ?? title).lineLimit(1)
                }
                .font(.subheadline.weight(.medium)).foregroundStyle(CommaTheme.textPrimary)
            }
            .padding(.horizontal, 12)
            // The Tasks group's surface, corners and row height, so the two read as sections of one page.
            .frame(maxWidth: .infinity, minHeight: GroupedSurface.rowHeight)
            .background(GroupedSurface.surface, in: RoundedRectangle(cornerRadius: GroupedSurface.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: GroupedSurface.radius, style: .continuous))
        }
        .buttonStyle(TactileButtonStyle())
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(id)
    }

    /// How their requests are taken, and stopping them.
    private func menu(_ person: PeoplePerson) -> some View {
        Menu {
            if let sends = person.sends {
                Section("Their requests") {
                    Picker("Their requests", selection: Binding(get: { sends.mode }, set: { mode in
                        Task { await model.requests.setMode(grant: sends.grant, mode: mode) }
                    })) {
                        Text("task_requests_mode_review").tag("review")
                        Text("task_requests_mode_auto").tag("auto_accept")
                    }
                }
                Button(role: .destructive) { stopping = true } label: {
                    Label { Text("Stop requests from \(person.name)") } icon: { MenuIcon.destructive("icon-close") }
                }
            }
        } label: {
            Label("More for \(person.name)", image: "icon-more")
        }
        .accessibilityIdentifier("personMore")
    }

    // MARK: Rows

    private struct Row: Identifiable {
        let id: String
        let at: Double
        let view: AnyView
    }

    /// The Tasks the member hosts with them, those someone hosts with both of them, and the requests either sent the
    /// other's Comma; the latest first.
    private func rows(_ person: PeoplePerson) -> [Row] {
        var rows: [Row] = []
        for task in model.hostedTasks(with: person.id) {
            let faces = task.together.compactMap { id in model.person(id).map { ($0.name, $0.avatar) } }
            rows.append(Row(id: "host:" + task.id, at: task.updatedAt, view: AnyView(
                Button { Task { await store.openTask(id: task.id) } } label: {
                    TaskRowLabel(task: task, pinned: false) {
                        PersonAvatarStack(store: store, people: [(store.memberName ?? "", nil)] + faces, size: 20, max: 3,
                                          ring: GroupedSurface.surface)
                    }
                    .padding(.horizontal, 4)
                }.buttonStyle(SurfaceRowButtonStyle()).accessibilityIdentifier("person-task-" + task.id))))
        }
        for item in model.joinedTasks(with: person.id) {
            rows.append(Row(id: "member:" + item.id, at: (item.invitedAt?.timeIntervalSince1970 ?? 0) * 1000, view: AnyView(
                // Not joined yet, it has no status of its own for the member: the dashed ring of a Task not started.
                PersonPageRow(status: item.invited ? nil : .inProgress, title: item.title,
                              detail: item.invited ? String(localized: "\(item.hostName) invited you") : String(localized: "Hosted by \(item.hostName)")) {
                    if item.invited { invitation = item } else { Task { await store.openTask(id: item.taskID, group: item.groupID) } }
                })))
        }
        for (request, incoming) in model.requests(with: person.id) {
            let id = request.string("id") ?? UUID().uuidString
            let status = request.string("status")
            let taskStatus = incoming ? nil : request.string("task_status")
            let taskID = request.object("task")?.string("id")
            let bucket = taskID.flatMap { id in store.tasks.first { $0.id == id }?.listBucket }
                ?? taskStatus.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : TaskBucket(status: $0) }
            let at = Double((incoming ? request.int("created_at")
                             : (request.int("task_updated_at") ?? request.int("decided_at") ?? request.int("created_at"))) ?? 0) * 1000
            let link = NavigationLink {
                PhoneRequestDetail(model: model.requests, request: request, incoming: incoming)
            } label: {
                PersonPageRow(status: requestBucket(status, task: bucket), quiet: !["pending", "accepted"].contains(status ?? ""), title: request.string("title") ?? String(localized: "Task request"),
                              detail: incoming ? String(localized: "Their request · \(requestStatusName(status))")
                                               : String(localized: "Your request · \(requestStatusName(status, taskStatus: taskStatus))"), action: nil)
            }.buttonStyle(SurfaceRowButtonStyle())
            let view: AnyView = if !incoming, let requestID = request.string("id") {
                AnyView(link.contextMenu {
                    if status == "pending" {
                        Button(role: .destructive) {
                            Task { _ = await model.scope.perform("taskRequests.withdraw", ["request": requestID], workspaceParameter: false) }
                        } label: {
                            Label { Text("Withdraw request") } icon: { MenuIcon.destructive("icon-close") }
                        }
                    } else {
                        Button(role: .destructive) { deletingRequest = requestID } label: {
                            Label { Text("Delete request") } icon: { MenuIcon.destructive("central-trash-can") }
                        }
                    }
                })
            } else {
                AnyView(link)
            }
            rows.append(Row(id: "request:" + id, at: at, view: view))
        }
        return rows.sorted { $0.at > $1.at }
    }
}

private struct RequestTarget: Identifiable {
    let target: NSDictionary
    var id: String { target.string("grant_id") ?? "" }
}

/// A request as the Task it asks for: waiting, the dashed ring of one not started (nil); accepted, its Task's own status
/// where the member has the Task; declined, withdrawn or expired, the ring of one that will not run.
func requestBucket(_ status: String?, task: TaskBucket?) -> TaskBucket? {
    switch status {
    case "pending": nil
    case "accepted": task ?? .inProgress
    default: .cancelled
    }
}

/// A row of a person's page that is not a Task of the member's list, led by the glyph the Tasks list shows for its
/// status (nil, the dashed ring of one not started), so a Task looks the same everywhere; a title over one line of
/// where it stands.
struct PersonPageRow: View {
    let status: TaskBucket?
    /// One that will not run keeps its glyph in the quiet ink rather than the cancelled red.
    var quiet = false
    let title: String
    let detail: String
    let action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { label }.buttonStyle(SurfaceRowButtonStyle())
        } else {
            label
        }
    }

    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 18

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(status?.iconName ?? TaskBucket.neutralIconName).renderingMode(.template).resizable().interpolation(.high)
                .frame(width: glyphSize, height: glyphSize)
                .foregroundStyle(quiet || status == nil ? CommaTheme.sidebarIcon : status!.tint)
                .accessibilityHidden(true)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + $0.height / 3 }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.body).foregroundStyle(CommaTheme.textPrimary).lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(verbatim: detail).font(.footnote).foregroundStyle(CommaTheme.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .surfaceRowFrame()
        .contentShape(Rectangle())
    }
}

func requestStatusName(_ value: String?, taskStatus: String? = nil) -> String {
    switch value {
    case "pending": String(localized: "Pending")
    case "accepted":
        if let trimmed = taskStatus?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            if trimmed.lowercased() == "escalated" {
                String(localized: "Needs input")
            } else {
                String(localized: TaskBucket(status: trimmed).label)
            }
        } else {
            String(localized: "Accepted")
        }
    case "declined": String(localized: "Declined")
    case "withdrawn": String(localized: "Withdrawn")
    case "expired": String(localized: "Expired")
    default: value ?? "—"
    }
}
