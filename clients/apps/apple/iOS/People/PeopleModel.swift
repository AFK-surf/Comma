import SwiftUI
import Observation
import CommaCore

/// A person of People, as the core's `taskRequests` topic lists them (`people`): who they are and how requests go
/// between the two of you. Nothing of it is stored on the device.
struct PeoplePerson: Identifiable, Equatable {
    let id: String
    let name: String
    let email: String?
    /// Where their avatar is read (a `files.read` source), when they have one.
    let avatar: NSDictionary?
    /// Their grant to send requests to the workspace and how the workspace takes them (`review`, `auto_accept`).
    let sends: (grant: String, mode: String)?
    /// The grant of a workspace of theirs the member may send a request to now; nil when they take none.
    let requestGrant: String?

    init?(_ contact: NSDictionary) {
        guard let id = contact.string("id") else { return nil }
        self.id = id
        email = contact.string("email")
        name = contact.string("name") ?? email ?? ""
        avatar = contact.object("avatar")
        sends = contact.object("sends").flatMap { sends in
            sends.string("grant").map { ($0, sends.string("mode") ?? "review") }
        }
        let receives = contact.objects("receives")
        requestGrant = (receives.first { !$0.bool("full") } ?? receives.first)?.string("grant")
    }

    static func == (a: PeoplePerson, b: PeoplePerson) -> Bool {
        a.id == b.id && a.name == b.name && a.email == b.email && a.sends?.grant == b.sends?.grant
            && a.sends?.mode == b.sends?.mode && a.requestGrant == b.requestGrant
            && (a.avatar?.isEqual(b.avatar) ?? (b.avatar == nil))
    }
}

/// A Collaborative Task another person hosts, as one of its people sees it (`collaborations`).
struct PeopleCollaboration: Identifiable, Equatable {
    let id: String
    let invited: Bool
    let title: String
    let taskID: String
    let groupID: String
    let host: NSDictionary?
    let members: [NSDictionary]
    let invitedAt: Date?

    init?(_ item: NSDictionary) {
        guard let id = item.string("id"), let task = item.object("task"), let taskID = task.string("id"),
              let group = task.string("group_id") else { return nil }
        self.id = id
        invited = item.string("status") == "invited"
        title = item.text("title") ?? ""
        self.taskID = taskID
        groupID = group
        host = item.object("host")
        members = item.objects("members")
        invitedAt = item.double("invited_at").map { Date(timeIntervalSince1970: $0) }
    }

    var hostName: String { host?.string("name") ?? host?.string("email") ?? "" }
    var hostID: String? { host?.string("id") }

    /// Whether `person` is in it: its host, or a member who has not left or been taken out.
    func includes(_ person: String) -> Bool {
        hostID == person || members.contains {
            $0.object("person")?.string("id") == person && ["invited", "active"].contains($0.string("status") ?? "")
        }
    }

    static func == (a: PeopleCollaboration, b: PeopleCollaboration) -> Bool {
        a.id == b.id && a.invited == b.invited && a.title == b.title && a.members.count == b.members.count
    }
}

/// People: the account's People (the `taskRequests` topic of the selected workspace) and the Collaborative Tasks it
/// was invited to or joined (`collaborations`). One model per workspace page; its scope retires with the workspace.
@MainActor @Observable final class PeopleModel {
    let requests: PhoneTaskRequestsModel
    private let store: CommaStore
    private(set) var collaborations: [PeopleCollaboration] = []
    private(set) var collaborationsLoaded = false
    /// The invite link just made, for the share sheet.
    var shareInvite: URL?

    init(store: CommaStore, workspace: Workspace) {
        self.store = store
        requests = PhoneTaskRequestsModel(store: store, workspace: workspace)
    }

    var scope: WorkspaceSettingsScope { requests.scope }
    var workspace: Workspace { scope.workspace }
    var loaded: Bool { requests.feed.loaded && requests.feed.value.object?["people"] is NSArray }

    /// Everyone, by name.
    var people: [PeoplePerson] {
        requests.rows("people").compactMap(PeoplePerson.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func person(_ id: String) -> PeoplePerson? { people.first { $0.id == id } }

    /// Someone's name and avatar source: from People, else from a Task together they host or are in (desktop
    /// `usePersonName`).
    func face(_ id: String) -> (name: String, avatar: NSDictionary?)? {
        if let person = person(id) { return (person.name, person.avatar) }
        for item in collaborations {
            if item.hostID == id { return (item.hostName, item.host?.object("avatar")) }
            if let person = item.members.lazy.compactMap({ $0.object("person") }).first(where: { $0.string("id") == id }) {
                return (person.string("name") ?? person.string("email") ?? "", person.object("avatar"))
            }
        }
        return nil
    }

    /// Follows both lists while the page shows; each is read again as it opens (the server tells no client of a
    /// change).
    func follow() async {
        async let people: Void = requests.feed.follow()
        async let together: Void = followCollaborations()
        _ = await (people, together)
    }

    func refresh() async {
        async let people: Void = requests.refresh()
        async let together = try? scope.call("collaborations.refresh", workspaceParameter: false)
        _ = await (people, together)
    }

    /// Follows only the invitations and memberships (the Inbox shows the invitations).
    func followCollaborations() async {
        Task { _ = try? await scope.call("collaborations.refresh", workspaceParameter: false) }
        for await update in store.core.subscribe(["topic": "collaborations"], read: { CoreJSON(value: $0) }) {
            guard scope.current, !Task.isCancelled else { return }
            guard case .value(let value) = update, let items = value.object?.array("items") else { continue }
            collaborations = items.compactMap { ($0 as? NSDictionary).flatMap(PeopleCollaboration.init) }
            collaborationsLoaded = true
        }
    }

    /// A new invite link for the share sheet: it works once, for seven days.
    func makeInvite() async {
        await requests.invitePerson()
        shareInvite = requests.invite
    }

    /// Joins or declines an invitation; joined, its Task opens.
    func answer(_ item: PeopleCollaboration, join: Bool) async -> Bool {
        guard await scope.perform("collaborations.answer", ["id": item.id, "answer": join ? "accept" : "decline"],
                                  workspaceParameter: false) != nil else { return false }
        if join { await store.openTask(id: item.taskID, group: item.groupID) }
        return true
    }

    /// The Tasks the member hosts with `person` (their list names them `together`).
    func hostedTasks(with person: String) -> [TaskSummary] {
        store.tasks.filter { $0.together.contains(person) }
    }

    /// The Tasks others host that `person` and the member are both in.
    func joinedTasks(with person: String) -> [PeopleCollaboration] {
        collaborations.filter { $0.includes(person) }
    }

    /// Requests either sent the other's Comma: theirs to the workspace, the member's to theirs.
    func requests(with person: String) -> [(request: NSDictionary, incoming: Bool)] {
        let incoming = requests.rows("received").filter { $0.object("sender")?.string("id") == person }.map { ($0, true) }
        let sent = requests.rows("sent").filter { $0.object("workspace")?.object("owner")?.string("id") == person }.map { ($0, false) }
        return (incoming + sent).sorted { ($0.0.int("created_at") ?? 0) > ($1.0.int("created_at") ?? 0) }
    }

    /// Where the member's requests to `person` go: their row of `targets`.
    func target(for person: PeoplePerson) -> NSDictionary? {
        guard let grant = person.requestGrant else { return nil }
        return requests.rows("targets").first { $0.string("grant_id") == grant }
    }
}
