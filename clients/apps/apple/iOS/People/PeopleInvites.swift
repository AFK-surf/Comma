import SwiftUI
import CommaCore

/// The invite link someone sent: pasted (or typed), it shows who sent it as the server reads it, and Accept adds them
/// to People, both ways when the member's workspace takes them.
struct EnterInviteSheet: View {
    let store: CommaStore
    let model: PhoneTaskRequestsModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var pendingPreview: String?
    @FocusState private var focused: Bool

    private var trimmed: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            SettingsPage(background: GroupedSurface.sheet) {
                SettingsSection(footer: Text("Each invite link works once and expires in 7 days.")) {
                    HStack(spacing: 8) {
                        TextField("Paste the link they sent you", text: $link)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .focused($focused).submitLabel(.go)
                            .onSubmit { Task { await model.previewInvitation(trimmed) } }
                            .accessibilityIdentifier("peopleInviteLink")
                        PasteButton(payloadType: String.self) { values in
                            guard let value = values.first else { return }
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            if link == value {
                                Task { await model.previewInvitation(trimmed) }
                            } else {
                                pendingPreview = trimmed
                                link = value
                            }
                        }
                        .labelStyle(.iconOnly).buttonBorderShape(.capsule)
                    }
                    .surfaceRowFrame()
                }
                if let preview = model.invitePreview.object { card(preview) }
                if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
            }
            .navigationTitle("Use an invite link")
            .navigationBarTitleDisplayMode(.inline)
            .sheetCloseButton(id: "peopleInviteClose") { dismiss() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if model.scope.busy { ProgressView() } else if model.invitePreview.object == nil {
                        Button("Next") { Task { await model.previewInvitation(trimmed) } }.fontWeight(.semibold)
                            .tint(CommaTheme.textPrimary).disabled(trimmed.isEmpty)
                    }
                }
            }
            .onChange(of: link) { _, _ in
                model.invalidateInvitePreview()
                let pending = pendingPreview
                pendingPreview = nil
                if let pending, pending == trimmed {
                    Task { await model.previewInvitation(pending) }
                }
            }
            .disabled(!model.scope.current)
        }
        .commaSheet([.medium, .large])
        .onAppear { focused = true }
        .onDisappear { model.invalidateInvitePreview() }
    }

    /// Who sent it, and accepting it; one's own link says so instead.
    private func card(_ preview: NSDictionary) -> some View {
        let owner = preview.object("workspace")?.object("owner")
        let name = owner?.string("name") ?? owner?.string("email") ?? preview.object("workspace")?.string("name") ?? ""
        return VStack(spacing: 14) {
            PersonAvatar(store: store, name: name, size: 56)
            if preview.bool("own") {
                Text("This is your own invite link. Send it to someone you want to work with.")
                    .font(.subheadline).foregroundStyle(CommaTheme.textSecondary).multilineTextAlignment(.center)
            } else {
                VStack(spacing: 4) {
                    Text(verbatim: name).font(.headline).foregroundStyle(CommaTheme.textPrimary)
                    Text("\(name) wants to add you to People.").font(.subheadline).foregroundStyle(CommaTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                Button("Accept") {
                    Task { if await model.acceptInvitation(trimmed) { model.invalidateInvitePreview(); dismiss() } }
                }
                .buttonStyle(CommaButtonStyle(hierarchy: .primary))
                .accessibilityIdentifier("peopleInviteAccept")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(GroupedSurface.surface, in: RoundedRectangle(cornerRadius: GroupedSurface.radius, style: .continuous))
        .transition(.opacity)
    }
}

/// An invitation to a Collaborative Task another person hosts: who is in it, who invited the member and pays, that only
/// this Task is shared, then Decline or Join. Nothing of the Task shows until the member joins; joined, it opens.
struct InvitationSheet: View {
    let store: CommaStore
    let model: PeopleModel
    let item: PeopleCollaboration
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    var body: some View {
        let everyone = [(item.hostName, item.hostID.flatMap(model.person)?.avatar)] + item.members.compactMap { member -> (String, NSDictionary?)? in
            guard ["invited", "active"].contains(member.string("status") ?? "") else { return nil }
            let person = member.object("person")
            let id = person?.string("id")
            guard id != store.session?.user.id else { return nil }
            guard let name = person?.string("name") ?? person?.string("email") else { return nil }
            return (name, id.flatMap(model.person)?.avatar)
        }
        NavigationStack {
            VStack(spacing: 20) {
                Spacer(minLength: 0)
                PersonAvatarStack(store: store, people: everyone.map { (name: $0.0, source: $0.1) }, size: 44, max: 5,
                                  ring: GroupedSurface.sheet)
                VStack(spacing: 6) {
                    Text(verbatim: item.title).font(.title3.weight(.semibold)).foregroundStyle(CommaTheme.textPrimary)
                        .multilineTextAlignment(.center).lineLimit(3)
                    Text("\(item.hostName) invited you").font(.subheadline).foregroundStyle(CommaTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label { Text("\(item.hostName) pays") } icon: { CentralIcon("central-people", size: 14) }
                    Label { Text("Only this task is shared") } icon: { CentralIcon("central-circle-check", size: 14) }
                    Label { Text("Join to see what is said in it, its files and its Worker’s progress.") } icon: {
                        CentralIcon("central-chain-link-4", size: 14)
                    }
                }
                .font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(GroupedSurface.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                if let error = model.scope.error { InlineError(message: error, dismiss: { model.scope.error = nil }) }
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Button("Decline") { answer(join: false) }.buttonStyle(CommaButtonStyle(hierarchy: .secondary))
                        .accessibilityIdentifier("invitationDecline")
                    Button("Join") { answer(join: true) }.buttonStyle(CommaButtonStyle(hierarchy: .primary))
                        .accessibilityIdentifier("invitationJoin")
                }
                .disabled(busy)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
            .background(GroupedSurface.sheet)
            .navigationBarTitleDisplayMode(.inline)
            .sheetCloseButton(id: "invitationClose") { dismiss() }
        }
        .commaSheet([.medium, .large])
    }

    private func answer(join: Bool) {
        busy = true
        Task {
            let done = await model.answer(item, join: join)
            busy = false
            if done { dismiss() }
        }
    }
}
