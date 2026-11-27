import SwiftUI
import CommaCore

/// The People tab follows the selected Workspace: its People and the Collaborative Tasks the member is in.
struct PeopleTabView: View {
    let store: CommaStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.shellColumnsFolded) private var columnsFolded

    var body: some View {
        let scope = "\(store.boundaryToken)/\(store.workspace?.id ?? "")"
        Group {
            if let workspace = store.workspace {
                PeopleView(store: store, workspace: workspace).id(scope)
            } else {
                // People owns the shell's columns, so it keeps clear of Routines itself.
                GeometryReader { geometry in
                    let columns = ShellColumnLayout(size: geometry.size, folded: columnsFolded ?? false,
                                                    division: geometry.shellFoldDivision)
                    NavigationStack {
                        EmptyState(Text("No workspace"), icon: "icon-people",
                                   description: Text("Choose or create a workspace to see your people."))
                            .background(CommaTheme.bgPrimary)
                            .pageTitle("People")
                    }
                    .padding(.leading, columnsFolded != nil ? columns.contentLeadingInset : 0)
                }
            }
        }
        // A person belongs to the workspace and account they were opened in.
        .onChange(of: scope) { _, _ in navigation.peoplePath = [] }
    }
}

/// People: everyone the member works with, by name. A row opens the person (who they are, collaborating with them,
/// a request to their Comma, and the Tasks the two of you share). Add shares the member's invite link through the
/// system share sheet or takes the link someone sent. What waits from them (invitations, requests) is the Inbox's.
/// On a wide screen it lays out as Settings does: the list stands in the trailing column, and opening a person
/// slides it to the leading one, in place of Routines, with the person beside it.
struct PeopleView: View {
    let store: CommaStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.shellColumnsFolded) private var columnsFolded
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: PeopleModel
    @State private var entering = false
    @State private var query = ""

    init(store: CommaStore, workspace: Workspace) {
        self.store = store
        _model = State(initialValue: PeopleModel(store: store, workspace: workspace))
    }

    var body: some View {
        @Bindable var navigation = navigation
        GeometryReader { geometry in
            let split = columnsFolded != nil && !navigation.peoplePath.isEmpty
            let columns = ShellColumnLayout(size: geometry.size, folded: columnsFolded ?? false,
                                            division: geometry.shellFoldDivision)
            ZStack(alignment: .leading) {
                // The native push owns the person page, back navigation, and nested pages.
                NavigationStack(path: $navigation.peoplePath) {
                    Group {
                        if columnsFolded == nil { list }
                        else { CommaTheme.bgPrimary.ignoresSafeArea().navigationTitle("People") }
                    }
                    .navigationDestination(for: String.self) { id in
                        PersonView(store: store, model: model, personID: id)
                            .background(SettingsPopGesturePolicy(blocked: columnsFolded != nil))
                    }
                }
                .padding(.leading, columnsFolded != nil ? columns.leadingWidth + columns.gap : 0)
                .accessibilityHidden(columnsFolded != nil && !split)
                .accessibilityIdentifier("peopleDetailColumn")
                if columnsFolded != nil {
                    NavigationStack { list }
                        .background(CommaTheme.bgPrimary)
                        .frame(width: split ? columns.leadingWidth : columns.trailingWidth)
                        .offset(x: split ? 0 : columns.leadingWidth + columns.gap)
                        .animation(reduceMotion ? nil : CommaMotion.release, value: split)
                        .accessibilityIdentifier("peopleMasterColumn")
                }
            }
        }
        .sheet(isPresented: $entering) { EnterInviteSheet(store: store, model: model.requests) }
        .sheet(item: Binding(get: { model.shareInvite.map(InviteShare.init) }, set: { if $0 == nil { model.shareInvite = nil } })) { share in
            InviteShareSheet(url: share.url).presentationDetents([.medium, .large]).ignoresSafeArea()
        }
    }

    private var list: some View {
        let people = model.people
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = people.filter { needle.isEmpty || ($0.name + " " + ($0.email ?? "")).localizedCaseInsensitiveContains(needle) }
        // As the system's contacts: under the initial each name starts with, with # strictly last.
        let sections = Self.groupedSections(shown)
        let selected = columnsFolded != nil ? navigation.peoplePath.first : nil
        return ScrollViewReader { scroller in
            List {
                if let error = model.scope.error {
                    InlineError(message: error, dismiss: { model.scope.error = nil })
                        .padding(.horizontal, GroupedSurface.margin).padding(.vertical, 8).commaListRow()
                }
                if !people.isEmpty {
                    FilterSearchField(prompt: "Search people", text: $query, icon: "icon-search", accessibilityID: "peopleSearch")
                        .padding(.horizontal, GroupedSurface.margin).padding(.bottom, 4)
                        .commaListRow()
                }
                ForEach(sections, id: \.key) { section in
                    Text(verbatim: section.key).font(.subheadline.weight(.semibold)).foregroundStyle(CommaTheme.textQuaternary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .commaListRow()
                    ForEach(section.value) { person in
                        PeopleRow(store: store, person: person, selected: selected == person.id) {
                            navigation.peoplePath = [person.id]
                        }
                            .id(person.id)
                            .commaListRow(.task)
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 44)
            .scrollContentBackground(.hidden)
            .background(CommaTheme.bgPrimary)
            .animation(CommaMotion.settle(reduced: reduceMotion), value: people.map(\.id))
            .overlay {
                if !model.loaded { ProgressView("Loading people…").allowsHitTesting(false) }
                else if people.isEmpty { empty }
            }
            .refreshable { await model.refresh() }
            .pageTitle("People")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { addMenu } }
            .task(whileShowing: .people) { await model.follow() }
            .onChange(of: navigation.reselect[.people]) { _, _ in
                if !navigation.peoplePath.isEmpty { navigation.peoplePath = []; return }
                query = ""
                if let first = people.first { withAnimation(CommaMotion.spatialMove) { scroller.scrollTo(first.id, anchor: .top) } }
            }
        }
    }

    /// Someone new: the member's own link to send them, or the link they sent.
    private var addMenu: some View {
        Menu {
            Button { Task { await model.makeInvite() } } label: { Label("Share invite link", image: "central-share-os") }
                .accessibilityIdentifier("peopleShareInvite")
            Button { entering = true } label: { Label("Use an invite link", image: "central-chain-link-4") }
                .accessibilityIdentifier("peopleEnterInvite")
        } label: {
            Label("Add", image: "central-plus-small")
        }
        .disabled(!model.loaded || model.scope.busy)
        .accessibilityIdentifier("peopleAdd")
    }

    private var empty: some View {
        EmptyState(Text("No one here yet"), icon: "icon-people",
                   description: Text("Share your invite link, or use one someone sent you.")) {
            Button("Share invite link") { Task { await model.makeInvite() } }
                .buttonStyle(CommaButtonStyle(hierarchy: .primary, compact: true))
            Button("Use an invite link") { entering = true }
        }
        .accessibilityIdentifier("peopleEmpty")
    }

    /// ASCII Latin initial (diacritics folded) A..Z; digits, symbols and non-Latin scripts group under `#`.
    static func sectionLetter(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).uppercased()
        guard let scalar = folded.unicodeScalars.first, scalar.value >= 65 && scalar.value <= 90 else { return "#" }
        return String(Character(scalar))
    }

    static func groupedSections(_ people: [PeoplePerson]) -> [(key: String, value: [PeoplePerson])] {
        Dictionary(grouping: people) { sectionLetter(for: $0.name) }
            .sorted { a, b in
                if a.key == b.key { return false }
                if a.key == "#" { return false }
                if b.key == "#" { return true }
                return a.key < b.key
            }
    }
}

/// One person in the list: their face, their name and their address.
private struct PeopleRow: View {
    let store: CommaStore
    let person: PeoplePerson
    /// The person open beside the list on a wide screen.
    var selected = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                PersonAvatar(store: store, name: person.name, source: person.avatar, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: person.name).font(.body).foregroundStyle(CommaTheme.textPrimary).lineLimit(1)
                    if let email = person.email, email != person.name {
                        Text(verbatim: email).font(.footnote).foregroundStyle(CommaTheme.textTertiary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(minHeight: 56)
            .background(selected ? CommaTheme.sidebarItem : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(TaskRowButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("people-" + person.id)
    }
}

private struct InviteShare: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet for an invite link.
struct InviteShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
