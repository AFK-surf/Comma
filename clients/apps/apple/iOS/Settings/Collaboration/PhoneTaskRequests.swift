import SwiftUI
import Observation
import CommaCore

@MainActor @Observable final class PhoneTaskRequestsModel {
    let feed: WorkspaceTopic
    var scope: WorkspaceSettingsScope { feed.scope }
    var invite: URL?
    var link = ""
    private(set) var linkPreview = CoreJSON(value: nil)
    private var previewedLink = ""
    private(set) var invitePreview = CoreJSON(value: nil)
    private var previewedInvite = ""
    init(store: CommaStore, workspace: Workspace) {
        feed = WorkspaceTopic(store: store, workspace: workspace, topic: "taskRequests", parameters: ["prefer": workspace.id], workspaceField: true)
    }
    func rows(_ key: String) -> [NSDictionary] { feed.value.object?.objects(key) ?? [] }
    func refresh() async { _ = await scope.perform("taskRequests.refresh", workspaceParameter: false) }
    func invitePerson() async {
        let result = await scope.perform("taskRequests.createInvite", ["mode": "review"])
        invite = result?.object?.string("inviteUrl").flatMap(URL.init(string:))
    }
    func setMode(grant: String, mode: String) async {
        _ = await scope.perform("taskRequests.setMode", ["grant": grant, "mode": mode])
    }
    func setOwnAutoAccept(_ enabled: Bool) async {
        _ = await scope.perform("taskRequests.setOwnMode", ["mode": enabled ? "auto_accept" : "review"])
    }
    /// What accepting [invitation] in this workspace gives the inviter.
    func previewInvitation(_ invitation: String) async {
        let value = await scope.perform("taskRequests.invitePreview", ["invite": invitation.trimmingCharacters(in: .whitespacesAndNewlines)])
        previewedInvite = invitation; invitePreview = value ?? CoreJSON(value: nil)
    }
    func invalidateInvitePreview() { invitePreview = CoreJSON(value: nil); previewedInvite = "" }
    /// Accepted only as previewed, in this workspace: the inviter may send requests back to it.
    func acceptInvitation(_ invitation: String) async -> Bool {
        guard previewedInvite == invitation, let preview = invitePreview.object, !preview.bool("own") else { return false }
        return await scope.perform("taskRequests.acceptInvite", ["invite": invitation.trimmingCharacters(in: .whitespacesAndNewlines)]) != nil
    }
    func previewLink() async {
        let requested = link
        let value = await scope.perform("taskRequests.linkPreview", ["link": requested], workspaceParameter: false)
        guard requested == link else { return }
        previewedLink = requested; linkPreview = value ?? CoreJSON(value: nil)
    }
    func invalidatePreview() { linkPreview = CoreJSON(value: nil); previewedLink = "" }
    func acceptLink() async {
        guard previewedLink == link, linkPreview.object != nil else { return }
        if await scope.perform("taskRequests.acceptLink", ["link": link], workspaceParameter: false) != nil { link = ""; linkPreview = CoreJSON(value: nil) }
    }
}

struct PhoneTaskRequestsView: View {
    @State var model: PhoneTaskRequestsModel
    @State private var revoking: String?
    @State private var removingLink: String?
    @State private var acceptingInvitation = false

    var body: some View {
        SettingsPage {
            if !model.feed.loaded { ProgressView().frame(maxWidth: .infinity) }
            incoming
            access
            targets
            sent
            linkedAccounts
            if let error = model.scope.error { InlineError(message: error, retry: { Task { await model.refresh() } }) }
        }
        .pageTitle("Task requests")
        .task { await model.feed.follow() }
        .refreshable { await model.refresh() }
        .navigationDestination(isPresented: $acceptingInvitation) { PhoneAcceptRequestInvitationView(model: model) }
        .confirmationDialog("Revoke this access?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            if let grant = revoking { Button("Revoke access", role: .destructive) { Task { _ = await model.scope.perform("taskRequests.revokeGrant", ["grant": grant]) }; revoking = nil } }
        } message: { Text("Waiting requests from this person will be declined.") }
        .confirmationDialog("Unlink this account?", isPresented: Binding(get: { removingLink != nil }, set: { if !$0 { removingLink = nil } }), titleVisibility: .visible) {
            if let id = removingLink { Button("Unlink account", role: .destructive) { Task { _ = await model.scope.perform("taskRequests.removeLink", ["id": id], workspaceParameter: false) }; removingLink = nil } }
        }
        .disabled(model.scope.busy || !model.scope.current)
    }

    private var incoming: some View {
        SettingsSection(Text("task_requests_incoming")) {
            ForEach(model.rows("incoming"), id: \.self) { request in
                NavigationLink { PhoneRequestDetail(model: model, request: request, incoming: true) } label: {
                    HStack(spacing: GroupedSurface.groupSpacing) {
                        description(request.string("title") ?? String(localized: "Task request"),
                                    detail: [personName(request.object("sender")), date(request.int("created_at"))].filter { !$0.isEmpty }.joined(separator: " · "))
                        Text("task_requests_review").font(.subheadline).foregroundStyle(CommaTheme.brandSolid)
                    }.surfaceRowFrame()
                }.buttonStyle(SurfaceRowButtonStyle())
            }
            if model.feed.loaded, model.rows("incoming").isEmpty { SettingsRow(Text("task_requests_incoming_empty")) }
        }
    }

    private var access: some View {
        section("task_requests_senders", action: {
            Button {
                Task {
                    await model.invitePerson()
                    if let invite = model.invite { copy(invite.absoluteString) }
                }
            } label: { Label { Text("task_requests_create_invite") } icon: { CentralIcon("central-plus-small", size: 16) } }
                .buttonStyle(CommaButtonStyle(hierarchy: .secondary, compact: true))
        }) {
            ForEach(model.rows("grants").filter { $0.string("status") != "revoked" }, id: \.self) { grant in
                HStack(spacing: GroupedSurface.groupSpacing) {
                    description(grant.string("status") == "invited" ? String(localized: "task_requests_open_invite") : personName(grant.object("grantee")),
                                detail: grantDescription(grant))
                    Menu {
                        if grant.string("status") == "invited" {
                            if let link = grant.string("invite_url") { Button("task_requests_copy_link") { copy(link) } }
                        } else {
                            let mode = grant.string("mode") == "auto_accept" ? "review" : "auto_accept"
                            Button(mode == "auto_accept" ? "task_requests_switch_auto" : "task_requests_switch_review") {
                                if let id = grant.string("id") { Task { await model.setMode(grant: id, mode: mode) } }
                            }
                        }
                        Divider()
                        Button("Revoke access", role: .destructive) { revoking = grant.string("id") }
                    } label: {
                        CentralIcon("inbox-actions", size: 20, relativeTo: .body)
                            .foregroundStyle(CommaTheme.textSecondary)
                            .frame(width: GroupedSurface.rowHeight, height: GroupedSurface.rowHeight)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("Manage access for \(grant.string("status") == "invited" ? String(localized: "task_requests_open_invite") : personName(grant.object("grantee")))"))
                    .accessibilityIdentifier("requestAccessMenu-" + (grant.string("id") ?? ""))
                }.surfaceRowFrame()
            }
            if model.feed.loaded, model.rows("grants").filter({ $0.string("status") != "revoked" }).isEmpty {
                SettingsRow(Text("task_requests_senders_empty"))
            }
            if let invite = model.invite {
                ShareLink(item: invite) { SettingsRow(Text("Share invitation"), role: .action) }.buttonStyle(SurfaceRowButtonStyle())
            }
        }
    }

    private var targets: some View {
        section("task_requests_targets", action: {
            Button { acceptingInvitation = true } label: {
                Label { Text("task_requests_enter_invite") } icon: { CentralIcon("central-plus-small", size: 16) }
            }.buttonStyle(CommaButtonStyle(hierarchy: .secondary, compact: true))
        }) {
            ForEach(model.rows("targets"), id: \.self) { target in
                NavigationLink { PhoneSendRequestView(model: model, target: target) } label: {
                    HStack(spacing: GroupedSurface.groupSpacing) {
                        description([personName(target.object("workspace")?.object("owner")), target.object("workspace")?.string("name") ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                                    detail: String(localized: "\(target.int("sent_today") ?? 0) of \(target.int("daily_limit") ?? 0) sent today"))
                        Text("task_requests_send").font(.subheadline).foregroundStyle(CommaTheme.brandSolid)
                    }.surfaceRowFrame()
                }.buttonStyle(SurfaceRowButtonStyle())
            }
            if model.feed.loaded, model.rows("targets").isEmpty { SettingsRow(Text("task_requests_targets_empty")) }
        }
    }

    private var sent: some View {
        SettingsSection(Text("task_requests_sent")) {
            ForEach(model.rows("sent"), id: \.self) { request in
                HStack(spacing: GroupedSurface.groupSpacing) {
                    NavigationLink { PhoneRequestDetail(model: model, request: request, incoming: false) } label: {
                        description(request.string("title") ?? String(localized: "Task request"),
                                    detail: [personName(request.object("workspace")?.object("owner")), requestStatus(request.string("status")), request.string("decline_reason") ?? "", request.string("reply") ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    }.buttonStyle(.plain)
                    if request.string("status") == "pending", let id = request.string("id") {
                        Button("Withdraw request", role: .destructive) {
                            Task { _ = await model.scope.perform("taskRequests.withdraw", ["request": id], workspaceParameter: false) }
                        }.font(.subheadline)
                    }
                }.surfaceRowFrame()
            }
            if model.feed.loaded, model.rows("sent").isEmpty { SettingsRow(Text("task_requests_sent_empty")) }
        }
    }

    private var linkedAccounts: some View {
        SettingsSection(Text("task_requests_links")) {
            ForEach(model.rows("links"), id: \.self) { account in
                HStack(spacing: GroupedSurface.groupSpacing) {
                    description(account.string("name") ?? account.string("provider") ?? "",
                                detail: [account.string("provider") ?? "", account.string("email") ?? "", account.string("workspace") ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    Button("Unlink", role: .destructive) { removingLink = account.string("id") }.font(.subheadline)
                }.surfaceRowFrame()
            }
            if model.feed.loaded, model.rows("links").isEmpty { SettingsRow(Text("task_requests_links_empty")) }
            if let own = model.feed.value.object?.string("own") {
                VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing / 2) {
                    Toggle("task_requests_own_auto", isOn: Binding(get: { own == "auto_accept" }, set: { enabled in
                        Task { await model.setOwnAutoAccept(enabled) }
                    })).tint(CommaTheme.brandSolid)
                    Text("task_requests_own_auto_description").font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                }.surfaceRowFrame()
            }
            NavigationLink { PhoneLinkChatAccountView(model: model) } label: {
                SettingsRow(Text("Link a chat account"), role: .action) { SettingsChevron() }
            }.buttonStyle(SurfaceRowButtonStyle())
        }
    }

    private func section<Action: View, Rows: View>(_ title: LocalizedStringKey, @ViewBuilder action: () -> Action,
                                                   @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing) {
            SurfaceCaption(title: Text(title)) { action() }
            SurfaceGroup { rows() }
        }
    }

    private func description(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: GroupedSurface.groupSpacing / 2) {
            Text(verbatim: title).font(.body).foregroundStyle(CommaTheme.textPrimary)
            if !detail.isEmpty { Text(verbatim: detail).font(.footnote).foregroundStyle(CommaTheme.textTertiary) }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private func grantDescription(_ grant: NSDictionary) -> String {
        if grant.string("status") == "invited" {
            let expiry = date(grant.int("invite_expires_at"))
            return expiry.isEmpty ? "" : String(localized: "Expires \(expiry)")
        }
        let mode = grant.string("mode") == "auto_accept" ? String(localized: "task_requests_mode_auto") : String(localized: "task_requests_mode_review")
        return String(localized: "\(mode) · up to \(grant.int("daily_limit") ?? 0) a day")
    }

    private func personName(_ person: NSDictionary?) -> String { person?.string("name") ?? person?.string("email") ?? "" }
    private func date(_ seconds: Int?) -> String {
        seconds.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .shortened) } ?? ""
    }
    private func copy(_ text: String) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(120)])
    }
}

private struct PhoneAcceptRequestInvitationView: View {
    let model: PhoneTaskRequestsModel
    @State private var invitation = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsPage {
            SettingsSection(Text("Accept an invitation"), footer: Text("An invitation can be used once and expires after seven days.")) {
                TextField("Invitation link", text: $invitation).textInputAutocapitalization(.never).autocorrectionDisabled().surfaceRowFrame()
                Button("Preview invitation") { Task { await model.previewInvitation(invitation) } }
                    .surfaceRowFrame().disabled(invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let preview = model.invitePreview.object {
                    summary(preview).surfaceRowFrame()
                    if !preview.bool("own") {
                        Button("Accept invitation") { Task { if await model.acceptInvitation(invitation) { model.invalidateInvitePreview(); dismiss() } } }.surfaceRowFrame()
                    }
                }
            }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }.pageTitle("Accept an invitation")
            .onChange(of: invitation) { _, _ in model.invalidateInvitePreview() }
            .disabled(model.scope.busy || !model.scope.current)
    }

    /// What accepting gives each side, as the server said for this workspace.
    private func summary(_ preview: NSDictionary) -> Text {
        let workspace = preview.object("workspace")
        let owner = workspace?.object("owner")
        let name = owner?.string("name") ?? owner?.string("email") ?? workspace?.string("name") ?? ""
        let theirs = workspace?.string("name") ?? name
        if preview.bool("own") { return Text("This is your own invitation link. Give it to the person you want to work with.") }
        guard let back = preview.object("back") else { return Text("\(name) invites you to send requests to \(theirs). \(name) won't be able to send requests to you.") }
        let ours = back.object("workspace")?.string("name") ?? ""
        return back.string("mode") == "auto_accept"
            ? Text("\(name) invites you to send each other requests. You can then send requests to \(theirs), and \(name) can send requests to \(ours). You already let \(name)'s requests run there without your approval, and that stays.")
            : Text("\(name) invites you to send each other requests. You can then send requests to \(theirs), and \(name) can send requests to \(ours). Requests from \(name) wait for your approval.")
    }
}

private struct PhoneLinkChatAccountView: View {
    @Bindable var model: PhoneTaskRequestsModel
    var body: some View {
        SettingsPage {
            SettingsSection {
                TextField("Account link", text: $model.link).textInputAutocapitalization(.never).autocorrectionDisabled().surfaceRowFrame()
                Button("Preview account") { Task { await model.previewLink() } }.surfaceRowFrame().disabled(model.link.isEmpty)
                if let preview = model.linkPreview.object {
                    Text(verbatim: (preview.string("provider") ?? "") + " · " + (preview.string("name") ?? "")).surfaceRowFrame()
                    Button("Link this account") { Task { await model.acceptLink() } }.surfaceRowFrame()
                }
            }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }.pageTitle("Link a chat account")
            .onChange(of: model.link) { _, _ in model.invalidatePreview() }
            .disabled(model.scope.busy || !model.scope.current)
    }
}

struct PhoneRequestDetail: View {
    @Environment(AppNavigation.self) private var navigation
    let model: PhoneTaskRequestsModel
    let request: NSDictionary
    let incoming: Bool
    @State private var title = ""
    @State private var content = ""
    @State private var reason = ""
    @State private var destination = "task"
    @State private var declining = false
    @Environment(\.dismiss) private var dismiss
    private var id: String { request.string("id") ?? "" }
    private var current: NSDictionary { model.rows(incoming ? "incoming" : "sent").first { $0.string("id") == id } ?? request }
    var body: some View {
        SettingsPage {
            SettingsSection(Text("Request")) {
                if incoming, current.string("status") == "pending" {
                    TextField("Title", text: $title).surfaceRowFrame()
                    TextEditor(text: $content).frame(minHeight: GroupedSurface.rowHeight * 3).surfaceRowFrame().accessibilityLabel("Request content")
                    Picker("Send to", selection: $destination) { Text("New task").tag("task"); Text("Router chat").tag("router") }.surfaceRowFrame()
                    Button("Accept request") {
                        Task {
                            guard let answer = await model.scope.perform("taskRequests.accept", ["request": id, "title": title, "content": content, "to": destination]) else { return }
                            dismiss()
                            if let task = answer.object?.object("task")?.string("id") { await model.scope.store.openTask(id: task) }
                            else if destination == "router" { navigation.openRouter() }
                        }
                    }.surfaceRowFrame().disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    TextField("Decline reason (optional)", text: $reason).surfaceRowFrame()
                    Button("Decline request", role: .destructive) { declining = true }.surfaceRowFrame()
                } else {
                    Text(verbatim: current.string("title") ?? "").font(.headline).surfaceRowFrame()
                    Text(verbatim: current.text("content") ?? "").textSelection(.enabled).surfaceRowFrame()
                    SettingsRow(Text("Status"), value: Text(requestStatus(current.string("status"))))
                    if let reply = current.string("reply") { Text(verbatim: reply).textSelection(.enabled).surfaceRowFrame() }
                    if let reason = current.string("decline_reason") { Text(verbatim: reason).surfaceRowFrame() }
                    if !incoming, current.string("status") == "pending" {
                        Button("Withdraw request", role: .destructive) { Task { _ = await model.scope.perform("taskRequests.withdraw", ["request": id], workspaceParameter: false) } }.surfaceRowFrame()
                    }
                    if let task = current.object("task")?.string("id") { Button("Open task") { Task { await model.scope.store.openTask(id: task) } }.surfaceRowFrame() }
                }
            }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }.pageTitle("Task request")
            .onAppear { title = request.text("title") ?? ""; content = request.text("content") ?? "" }
            .confirmationDialog("Decline this request?", isPresented: $declining, titleVisibility: .visible) {
                Button("Decline request", role: .destructive) { Task { _ = await model.scope.perform("taskRequests.decline", ["request": id, "reason": reason]) } }
            }.disabled(model.scope.busy || !model.scope.current)
    }
}

struct PhoneSendRequestView: View {
    let model: PhoneTaskRequestsModel
    let target: NSDictionary
    @State private var title = ""
    @State private var content = ""
    @State private var key = UUID().uuidString
    @State private var sent = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SettingsPage {
            SettingsSection(Text(verbatim: target.object("workspace")?.string("name") ?? String(localized: "Workspace"))) {
                TextField("Title", text: $title).surfaceRowFrame()
                TextEditor(text: $content).frame(minHeight: GroupedSurface.rowHeight * 4).surfaceRowFrame().accessibilityLabel("Request content")
                Text("\(target.int("sent_today") ?? 0) of \(target.int("daily_limit") ?? 0) sent today").font(.footnote).foregroundStyle(CommaTheme.textTertiary).surfaceRowFrame()
                Button("Send request") {
                    Task {
                        guard let grant = target.string("grant_id") else { return }
                        if await model.scope.perform("taskRequests.send", ["grant": grant, "title": title, "content": content, "key": key]) != nil { sent = true; dismiss() }
                    }
                }.surfaceRowFrame().disabled(sent || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || full)
            }
            if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
        }.pageTitle("Send a request").disabled(model.scope.busy || !model.scope.current)
    }
    private var full: Bool { (target.int("sent_today") ?? 0) >= (target.int("daily_limit") ?? 0) || (target.int("pending") ?? 0) >= (target.int("pending_limit") ?? 0) }
}

private func requestStatus(_ value: String?) -> String {
    switch value {
    case "pending": String(localized: "Pending")
    case "accepted": String(localized: "Accepted")
    case "declined": String(localized: "Declined")
    case "withdrawn": String(localized: "Withdrawn")
    case "expired": String(localized: "Expired")
    default: value ?? "—"
    }
}
