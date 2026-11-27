import SwiftUI
import CommaCore

/// A Collaborative Task being written, as a new message is in Mail: who it is with on the To line (more from People,
/// or someone not on Comma by their email), what to do together, and Start. The member pays, and no one joins once it
/// starts. Started, its Task opens.
struct CollaborateSheet: View {
    let store: CommaStore
    let model: PeopleModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: [String]
    @State private var emails: [String] = []
    @State private var text = ""
    @State private var pending = false
    @State private var failure: String?
    @State private var addingEmail = false
    @State private var emailDraft = ""
    @State private var key = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    @FocusState private var writing: Bool

    init(store: CommaStore, model: PeopleModel, initial: [String]) {
        self.store = store
        self.model = model
        _chosen = State(initialValue: initial)
    }

    private var people: [PeoplePerson] { chosen.compactMap(model.person) }
    private var body_: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canStart: Bool { !pending && !body_.isEmpty && !(people.isEmpty && emails.isEmpty) && model.scope.current }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    recipients
                    Divider().padding(.leading, GroupedSurface.margin)
                    if let failure {
                        InlineError(message: failure, dismiss: { self.failure = nil })
                            .padding(.horizontal, GroupedSurface.margin).padding(.top, 12)
                    }
                    editor
                    notes
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(GroupedSurface.sheet)
            .navigationTitle("Collaborate")
            .navigationBarTitleDisplayMode(.inline)
            .sheetCloseButton(id: "collaborateClose") { dismiss() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if pending { ProgressView() } else {
                        Button("Start", action: start).fontWeight(.semibold).tint(CommaTheme.textPrimary)
                            .disabled(!canStart).accessibilityIdentifier("collaborateStart")
                    }
                }
            }
        }
        .commaSheet([.large])
        .interactiveDismissDisabled(pending || !body_.isEmpty)
        .onAppear { writing = true }
        .alert("Invite someone not on Comma", isPresented: $addingEmail) {
            TextField("Email", text: $emailDraft).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Add") { addEmail() }
            Button("Cancel", role: .cancel) { emailDraft = "" }
        } message: {
            Text("We email them an invite. They join by signing up to Comma with this email.")
        }
    }

    /// The To line: a chip for each person, and the add menu at its end.
    private var recipients: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("To:").font(.body).foregroundStyle(CommaTheme.textTertiary)
            FlowLayout(spacing: 6) {
                ForEach(people) { person in
                    chip(person.name, source: person.avatar) { chosen.removeAll { $0 == person.id } }
                }
                ForEach(emails, id: \.self) { email in
                    chip(email, source: nil) { emails.removeAll { $0 == email } }
                }
                addMenu
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, GroupedSurface.margin).padding(.vertical, 12)
        .disabled(pending)
    }

    private func chip(_ name: String, source: NSDictionary?, remove: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(CommaMotion.stateChange) { remove(); failure = nil } }) {
            HStack(spacing: 6) {
                PersonAvatar(store: store, name: name, source: source, size: 22)
                Text(verbatim: name).font(.subheadline).foregroundStyle(CommaTheme.textPrimary).lineLimit(1)
                CentralIcon("icon-close", size: 12).foregroundStyle(CommaTheme.textTertiary)
            }
            .padding(.leading, 3).padding(.trailing, 10).padding(.vertical, 3)
            .background(GroupedSurface.ink, in: Capsule())
        }
        .buttonStyle(TactileButtonStyle())
        .accessibilityLabel(Text("Remove \(name)"))
    }

    /// More people from People, checked as they are in; or someone by email.
    private var addMenu: some View {
        Menu {
            ForEach(model.people) { person in
                Toggle(isOn: Binding(get: { chosen.contains(person.id) }, set: { on in
                    failure = nil
                    if on { chosen.append(person.id) } else { chosen.removeAll { $0 == person.id } }
                })) { Text(verbatim: person.name) }
            }
            Divider()
            Button { addingEmail = true } label: { Label("Invite someone not on Comma", image: "central-plus-small") }
        } label: {
            CentralIcon("central-plus-small", size: 18)
                .foregroundStyle(CommaTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(GroupedSurface.ink, in: Circle())
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel("Add people")
        .accessibilityIdentifier("collaborateAdd")
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("What should you work on together?").font(.body).foregroundStyle(CommaTheme.textPlaceholder)
                    .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
            }
            TextEditor(text: $text).font(.body).focused($writing)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 180)
                .onChange(of: text) { _, _ in failure = nil }
                .disabled(pending)
                .accessibilityLabel("What should you work on together?")
                .accessibilityIdentifier("collaborateText")
        }
        .padding(.horizontal, GroupedSurface.margin - 5).padding(.top, 8)
    }

    /// Who pays and that it closes once started, then how someone by email joins.
    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text("You pay. No one can join once it starts.") } icon: { CentralIcon("central-people", size: 14) }
            if !emails.isEmpty {
                Label { Text("We email them an invite: they join by signing up to Comma with that email.") } icon: {
                    CentralIcon("central-share-os", size: 14)
                }
            }
        }
        .font(.footnote).foregroundStyle(CommaTheme.textTertiary)
        .padding(.horizontal, GroupedSurface.margin).padding(.vertical, 12)
    }

    private func addEmail() {
        let email = emailDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        emailDraft = ""
        guard email.contains("@"), email.split(separator: "@").count == 2, !emails.contains(email) else { return }
        withAnimation(CommaMotion.stateChange) { emails.append(email) }
        failure = nil
    }

    private func start() {
        guard canStart else { return }
        pending = true
        failure = nil
        var params: [String: Any] = ["workspace": model.workspace.id, "people": people.map(\.id), "content": body_, "key": key]
        if !emails.isEmpty { params["emails"] = emails }
        Task {
            do {
                let answer = try await model.scope.call("collaborations.start", params, workspaceParameter: false)
                guard let task = answer.object?.object("task")?.string("id") else { throw CoreError(code: "bad_response", message: "") }
                dismiss()
                await store.openTask(id: task)
            } catch is CancellationError {
                pending = false
            } catch {
                pending = false
                failure = Self.failure(error as? CoreError)
            }
        }
    }

    /// Why it did not start, in words: never a server's code.
    static func failure(_ error: CoreError?) -> String {
        if error?.status == 402 || error?.code == "billing_unavailable" {
            return String(localized: "Not enough credits to start it. Add credits, then try again.")
        }
        if error?.status == 409 || error?.code == "conflict" { return String(localized: "This collaboration has already started.") }
        if error?.status == 400 { return String(localized: "Couldn’t start it: check the people and the message, then try again.") }
        return String(localized: "Couldn’t start it. Try again in a moment.")
    }
}

/// A request to one person's Comma, written as a message: a title, what to do, and Send. Their Comma does it with
/// what they have; the member sees where it stands.
struct PersonRequestSheet: View {
    let model: PhoneTaskRequestsModel
    let person: PeoplePerson
    let target: NSDictionary
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""
    @State private var key = UUID().uuidString
    @FocusState private var writing: Bool

    private var full: Bool {
        (target.int("sent_today") ?? 0) >= (target.int("daily_limit") ?? 0)
            || (target.int("pending") ?? 0) >= (target.int("pending_limit") ?? 0)
    }
    private var canSend: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !full && !model.scope.busy && model.scope.current
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("To:").foregroundStyle(CommaTheme.textTertiary)
                        Text("\(person.name)’s Comma").foregroundStyle(CommaTheme.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .font(.body).padding(.horizontal, GroupedSurface.margin).padding(.vertical, 14)
                    Divider().padding(.leading, GroupedSurface.margin)
                    TextField("Title", text: $title).font(.body.weight(.semibold))
                        .padding(.horizontal, GroupedSurface.margin).padding(.vertical, 14)
                        .accessibilityIdentifier("requestTitle")
                    Divider().padding(.leading, GroupedSurface.margin)
                    if let error = model.scope.error {
                        InlineError(message: error, dismiss: { model.scope.error = nil })
                            .padding(.horizontal, GroupedSurface.margin).padding(.top, 12)
                    }
                    ZStack(alignment: .topLeading) {
                        if content.isEmpty {
                            Text("What should their Comma do?").foregroundStyle(CommaTheme.textPlaceholder)
                                .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                        TextEditor(text: $content).focused($writing).scrollContentBackground(.hidden).frame(minHeight: 180)
                            .accessibilityLabel("What should their Comma do?").accessibilityIdentifier("requestContent")
                    }
                    .font(.body).padding(.horizontal, GroupedSurface.margin - 5).padding(.top, 8)
                    Text(full ? String(localized: "No more requests to \(person.name) today.")
                              : String(localized: "\(person.name)’s Comma does it, with what \(person.name) has. \(target.int("sent_today") ?? 0) of \(target.int("daily_limit") ?? 0) sent today."))
                        .font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                        .padding(.horizontal, GroupedSurface.margin).padding(.vertical, 12)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(GroupedSurface.sheet)
            .navigationTitle("Request their Comma")
            .navigationBarTitleDisplayMode(.inline)
            .sheetCloseButton(id: "requestClose") { dismiss() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if model.scope.busy { ProgressView() } else {
                        Button("Send", action: send).fontWeight(.semibold).tint(CommaTheme.textPrimary)
                            .disabled(!canSend).accessibilityIdentifier("requestSend")
                    }
                }
            }
        }
        .commaSheet([.large])
        .interactiveDismissDisabled(!content.isEmpty)
        .onAppear { writing = true }
    }

    private func send() {
        guard canSend, let grant = target.string("grant_id") else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await model.scope.perform("taskRequests.send", ["grant": grant, "title": trimmedTitle, "content": trimmedContent, "key": key]) != nil {
                dismiss()
            }
        }
    }
}
