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
    private var invitePreviewToken = 0
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
        let trimmed = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        invitePreviewToken += 1
        let token = invitePreviewToken
        let value = await scope.perform("taskRequests.invitePreview", ["invite": trimmed])
        guard token == invitePreviewToken else { return }
        previewedInvite = trimmed; invitePreview = value ?? CoreJSON(value: nil)
    }
    func invalidateInvitePreview() { invitePreviewToken += 1; invitePreview = CoreJSON(value: nil); previewedInvite = "" }
    /// Accepted only as previewed, in this workspace: the inviter may send requests back to it.
    func acceptInvitation(_ invitation: String) async -> Bool {
        let trimmed = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard previewedInvite == trimmed, let preview = invitePreview.object, !preview.bool("own") else { return false }
        return await scope.perform("taskRequests.acceptInvite", ["invite": trimmed]) != nil
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
    @State private var deletingSent: String?
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
        .confirmationDialog("Delete this request?", isPresented: Binding(get: { deletingSent != nil }, set: { if !$0 { deletingSent = nil } }), titleVisibility: .visible) {
            if let id = deletingSent {
                Button("Delete request", role: .destructive) {
                    deletingSent = nil
                    Task { _ = await model.scope.perform("taskRequests.hide", ["request": id], workspaceParameter: false) }
                }
            }
        } message: { Text("It will be removed from your lists across devices. The recipient's task is not affected.") }
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
                                    detail: [personName(request.object("workspace")?.object("owner")), requestStatusName(request.string("status"), taskStatus: request.string("task_status")), request.string("decline_reason") ?? "", request.string("reply") ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    }.buttonStyle(.plain)
                    if request.string("status") == "pending", let id = request.string("id") {
                        Button("Withdraw request", role: .destructive) {
                            Task { _ = await model.scope.perform("taskRequests.withdraw", ["request": id], workspaceParameter: false) }
                        }.font(.subheadline)
                    } else if let id = request.string("id") {
                        Button("Delete", role: .destructive) { deletingSent = id }.font(.subheadline)
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
    static let maxDeclineReasonBytes = 1_000

    /// Truncates `text` to at most `maxBytes` UTF-8 bytes without splitting an extended grapheme cluster.
    static func clampUTF8(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var bytes = 0
        var end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            let step = text[end..<next].utf8.count
            if bytes + step > maxBytes { break }
            bytes += step
            end = next
        }
        return String(text[..<end])
    }

    let model: PhoneTaskRequestsModel
    let request: NSDictionary
    let incoming: Bool
    @State private var title = ""
    @State private var content = ""
    @State private var reason = ""
    @State private var declining = false
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    private var id: String { request.string("id") ?? "" }
    var current: NSDictionary {
        if incoming {
            return model.rows("received").first { $0.string("id") == id }
                ?? model.rows("incoming").first { $0.string("id") == id }
                ?? request
        }
        return model.rows("sent").first { $0.string("id") == id } ?? request
    }
    var body: some View {
        let pendingIncoming = incoming && current.string("status") == "pending"
        Group {
            if pendingIncoming {
                pendingIncomingBody
            } else {
                conversationBody
            }
        }
        .toolbar {
            if !pendingIncoming {
                ToolbarItem(placement: .principal) {
                    conversationTitleBar
                }
            }
            if !incoming, !id.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if current.string("status") == "pending" {
                            Button(role: .destructive) {
                                Task { _ = await model.scope.perform("taskRequests.withdraw", ["request": id], workspaceParameter: false) }
                            } label: {
                                Label { Text("Withdraw request") } icon: { MenuIcon.destructive("icon-close") }
                            }
                        } else {
                            Button(role: .destructive) { deleting = true } label: {
                                Label { Text("Delete request") } icon: { MenuIcon.destructive("central-trash-can") }
                            }
                        }
                    } label: {
                        Label("Request actions", image: "icon-more")
                    }
                    .accessibilityIdentifier("requestDetailMore")
                }
            }
        }
        .onAppear { title = request.text("title") ?? ""; content = request.text("content") ?? "" }
        .alert("Decline this request?", isPresented: $declining) {
            TextField("Reason (optional)", text: $reason)
                .onChange(of: reason) { _, value in
                    let clamped = Self.clampUTF8(value, maxBytes: Self.maxDeclineReasonBytes)
                    if clamped != value { reason = clamped }
                }
            Button("Cancel", role: .cancel) {}
            Button("Decline", role: .destructive) {
                let note = Self.clampUTF8(reason.trimmingCharacters(in: .whitespacesAndNewlines), maxBytes: Self.maxDeclineReasonBytes)
                Task { _ = await model.scope.perform("taskRequests.decline", ["request": id, "reason": note]) }
            }
        } message: {
            Text("The sender will see your reason if you add one.")
        }
        .confirmationDialog("Delete this request?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete request", role: .destructive) {
                Task {
                    if await model.scope.perform("taskRequests.hide", ["request": id], workspaceParameter: false) != nil {
                        dismiss()
                    }
                }
            }
        } message: { Text("It will be removed from your lists across devices. The recipient's task is not affected.") }
        .disabled(model.scope.busy || !model.scope.current)
    }

    private var statusBucket: TaskBucket? {
        let status = current.string("status")
        let taskStatus = incoming ? nil : current.string("task_status")
        return switch status {
        case "pending": nil
        case "accepted":
            taskStatus.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : TaskBucket(status: $0) } ?? .inProgress
        default: .cancelled
        }
    }

    private var statusQuiet: Bool {
        !["pending", "accepted"].contains(current.string("status") ?? "")
    }

    private var statusLabel: String {
        requestStatusName(current.string("status"), taskStatus: incoming ? nil : current.string("task_status"))
    }

    private var headingText: String {
        let raw = current.string("title") ?? ""
        return raw.isEmpty ? String(localized: "Task request") : raw
    }

    /// Two-line navigation title matching `TaskDockHeader`: title over status glyph and label.
    private var conversationTitleBar: some View {
        let bucket = statusBucket
        return VStack(spacing: 1) {
            Text(verbatim: headingText)
                .font(.body.weight(.medium))
                .foregroundStyle(CommaTheme.textPrimary)
                .lineLimit(1)
            HStack(spacing: 4) {
                if let bucket, !statusQuiet {
                    TaskStatusIcon(bucket: bucket, size: 11)
                } else {
                    Image(bucket?.iconName ?? TaskBucket.neutralIconName)
                        .renderingMode(.template).resizable().interpolation(.high)
                        .frame(width: 11, height: 11)
                        .foregroundStyle(CommaTheme.sidebarIcon)
                        .accessibilityHidden(true)
                }
                if bucket == .inProgress, !statusQuiet {
                    ShimmerText(text: statusLabel, font: .footnote.weight(.medium))
                } else {
                    Text(verbatim: statusLabel)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(CommaTheme.textQuaternary)
                        .lineLimit(1)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .combine)
    }

    /// Incoming pending request review: sender metadata, a labeled editable request card, and a pinned Decline / Create task footer.
    private var pendingIncomingBody: some View {
        let sender = current.object("sender")
        let senderID = sender?.string("id")
        let senderName = sender?.string("name") ?? sender?.string("email") ?? ""
        let avatarSource = senderID.flatMap { pid in model.rows("people").first { $0.string("id") == pid }?.object("avatar") }
        let timestamp = current.int("created_at").map {
            Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .shortened)
        } ?? ""
        let canAccept = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !senderName.isEmpty || !timestamp.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if !senderName.isEmpty {
                            recipientChip(name: senderName, source: avatarSource, label: String(localized: "From \(senderName)"))
                        }
                        if !timestamp.isEmpty {
                            Text(verbatim: timestamp)
                                .font(.footnote)
                                .foregroundStyle(CommaTheme.textTertiary)
                        }
                    }
                    .padding(.top, 8)
                }

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(CommaTheme.textTertiary)
                        TextField("Title", text: $title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(CommaTheme.textPrimary)
                            .accessibilityIdentifier("incomingRequestTitle")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    Divider()
                        .padding(.leading, 16)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Request content")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(CommaTheme.textTertiary)
                        ZStack(alignment: .topLeading) {
                            if content.isEmpty {
                                Text("Request content")
                                    .font(.body)
                                    .foregroundStyle(CommaTheme.textPlaceholder)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $content)
                                .font(.body)
                                .foregroundStyle(CommaTheme.textPrimary)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 120)
                                .padding(.horizontal, -5)
                                .accessibilityLabel("Request content")
                                .accessibilityIdentifier("incomingRequestContent")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                }
                .background(
                    GroupedSurface.surface,
                    in: RoundedRectangle(cornerRadius: GroupedSurface.radius, style: .continuous)
                )

                Text("Creates a new task in your workspace. You can edit the title or content before accepting.")
                    .font(.footnote)
                    .foregroundStyle(CommaTheme.textTertiary)
                    .padding(.horizontal, 4)

                if let error = model.scope.error {
                    InlineError(message: error, dismiss: { model.scope.error = nil })
                }
            }
            .padding(.horizontal, GroupedSurface.margin)
            .padding(.bottom, 20)
            .frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(CommaTheme.bgPrimary)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    Button("Decline", role: .destructive) {
                        reason = ""
                        declining = true
                    }
                    .buttonStyle(RequestActionButtonStyle(tone: .destructive))
                    .accessibilityIdentifier("incomingRequestDecline")
                    Button("Create task") {
                        Task {
                            guard let answer = await model.scope.perform(
                                "taskRequests.accept",
                                ["request": id, "title": title, "content": content]
                            ) else { return }
                            dismiss()
                            if let task = answer.object?.object("task")?.string("id") {
                                await model.scope.store.openTask(id: task)
                            }
                        }
                    }
                    .buttonStyle(RequestActionButtonStyle(tone: .primary))
                    .disabled(!canAccept)
                    .accessibilityIdentifier("incomingRequestAccept")
                }
                .padding(.horizontal, GroupedSurface.margin)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .background(CommaTheme.bgPrimary)
        }
        .pageTitle("Task request")
        .toolbar(.hidden, for: .tabBar)
    }

    private func recipientChip(name: String, source: NSDictionary?, label: String) -> some View {
        HStack(spacing: 6) {
            PersonAvatar(store: model.scope.store, name: name, source: source, size: 22)
            Text(verbatim: label)
                .font(.subheadline)
                .foregroundStyle(CommaTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.leading, 3).padding(.trailing, 10).padding(.vertical, 3)
        .background(GroupedSurface.ink, in: Capsule())
    }

    private var conversationBody: some View {
        let status = current.string("status")
        let person = incoming ? current.object("sender") : current.object("workspace")?.object("owner")
        let personID = person?.string("id")
        let counterparty = person?.string("name") ?? person?.string("email") ?? current.object("workspace")?.string("name") ?? ""
        let avatarSource = personID.flatMap { pid in model.rows("people").first { $0.string("id") == pid }?.object("avatar") }
        let timestamp = current.int("created_at").map {
            Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .shortened)
        } ?? ""
        let requestText = (current.text("content") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = (current.string("reply") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let declineReason = (current.string("decline_reason") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !counterparty.isEmpty || !timestamp.isEmpty {
                    VStack(spacing: 6) {
                        if !counterparty.isEmpty {
                            HStack(spacing: 6) {
                                if !incoming {
                                    Text("To:").font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                                }
                                recipientChip(
                                    name: counterparty,
                                    source: avatarSource,
                                    label: incoming
                                        ? String(localized: "From \(counterparty)")
                                        : String(localized: "\(counterparty)’s Comma")
                                )
                            }
                        }
                        if !timestamp.isEmpty {
                            Text(verbatim: timestamp)
                                .font(.caption)
                                .foregroundStyle(CommaTheme.textTertiary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .padding(.bottom, 22)
                }

                if !requestText.isEmpty {
                    if !incoming {
                        HStack {
                            Spacer(minLength: 48)
                            ChatBubbleSurface(fill: CommaTheme.brandSolid, tail: .trailing) {
                                Text(MessageBubbles.inline(requestText))
                                    .font(CommaTheme.messageFont)
                                    .foregroundStyle(Color.white)
                                    .tint(Color.white)
                                    .padding(CommaTheme.bubblePadding)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    } else {
                        incomingRow(counterparty: counterparty, avatarSource: avatarSource, isComma: false, caption: counterparty, body: requestText)
                    }
                }

                if !reply.isEmpty {
                    incomingRow(
                        counterparty: counterparty,
                        avatarSource: avatarSource,
                        isComma: true,
                        caption: (!incoming && !counterparty.isEmpty) ? String(localized: "\(counterparty)’s Comma") : "",
                        body: reply
                    )
                    .padding(.top, 22)
                } else if !declineReason.isEmpty {
                    incomingRow(
                        counterparty: counterparty,
                        avatarSource: avatarSource,
                        isComma: false,
                        caption: String(localized: "Declined"),
                        body: declineReason
                    )
                    .padding(.top, 22)
                } else if !incoming, !["declined", "withdrawn", "expired"].contains(status ?? "") {
                    Text("No result yet.")
                        .font(.footnote)
                        .foregroundStyle(CommaTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }

                if let task = current.object("task")?.string("id") {
                    Button("Open task") { Task { await model.scope.store.openTask(id: task) } }
                        .buttonStyle(RequestActionButtonStyle(tone: .primary))
                        .padding(.top, 28)
                }
                if let error = model.scope.error {
                    InlineError(message: error, dismiss: { model.scope.error = nil })
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, GroupedSurface.margin).padding(.top, 4).padding(.bottom, 28)
            .frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .background(CommaTheme.bgPrimary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private func incomingRow(counterparty: String, avatarSource: NSDictionary?, isComma: Bool, caption: String, body: String) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isComma || !counterparty.isEmpty {
                ZStack(alignment: .bottomLeading) {
                    Color.clear
                    if isComma {
                        AgentAvatar(role: .router).padding(4)
                    } else {
                        PersonAvatar(store: model.scope.store, name: counterparty, source: avatarSource, size: 24)
                    }
                }
                .frame(width: CommaTheme.avatarGutter)
            }
            VStack(alignment: .leading, spacing: 5) {
                if !caption.isEmpty {
                    Text(verbatim: caption)
                        .font(.footnote)
                        .foregroundStyle(CommaTheme.textTertiary)
                        .padding(.leading, 13)
                }
                ChatBubbleSurface(fill: CommaTheme.bubbleAssistant, tail: .leading) {
                    Text(MessageBubbles.inline(body))
                        .font(CommaTheme.messageFont)
                        .foregroundStyle(CommaTheme.textPrimary)
                        .padding(CommaTheme.bubblePadding)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 42)
        }
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

/// Full-capsule action button for request review and detail actions, unified across iOS and Android.
private struct RequestActionButtonStyle: ButtonStyle {
    enum Tone { case primary, destructive }
    var tone: Tone = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(foreground)
            .background(background, in: shape)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.05) : CommaMotion.release, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch tone {
        case .primary: isEnabled ? .white : CommaTheme.textPlaceholder
        case .destructive: isEnabled ? CommaTheme.errorPrimary : CommaTheme.textPlaceholder
        }
    }

    private var background: Color {
        switch tone {
        case .primary: isEnabled ? CommaTheme.brandSolid : CommaTheme.bgDisabled
        case .destructive: GroupedSurface.surface
        }
    }
}
