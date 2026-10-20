import Foundation
import CommaCore

/// The Task actions the fixture answers besides reading: search, archive and restore, ending a Task by hand,
/// rename and labels, pins and share links. State lives for the launch, so an action reads back as done.
enum FixtureTaskActions {
    nonisolated(unsafe) private static var shared: Set<String> = []
    nonisolated(unsafe) private static var titles: [String: String] = [:]

    private static let share = #"{"url":"https://comma.surf/s/7Hq2xK","created_at":1700000000,"shared_at":1700000000,"message_count":12,"artifact_count":2,"has_newer_messages":true}"#

    /// The answer to `method path`, or nil when this is not one of these routes.
    static func answer(_ method: String, _ path: String, _ query: (String) -> String?, body: Data?) -> FixtureResponse? {
        let parts = path.split(separator: "/").map(String.init)
        switch (method, path) {
        case ("GET", "groups/g/conversations/search"):
            let words = (query("q") ?? "").lowercased()
            let hits = FixtureData.taskIDs.filter { id in title(of: id)?.lowercased().contains(words) == true }.prefix(20)
            return ok(#"{"data":[\#(hits.map { #"{"conversation_id":"\#($0)"}"# }.joined(separator: ","))]}"#)
        case ("GET", "groups/g/task-summaries"):
            let ids = (query("ids") ?? "").split(separator: ",").map(String.init)
            return ok(#"{"data":[\#(ids.compactMap(FixtureData.task(id:)).joined(separator: ","))]}"#)
        default:
            break
        }
        guard parts.count >= 4, parts[0] == "groups", parts[2] == "conversations" else { return nil }
        let id = parts[3], action = parts.count > 4 ? parts[4] : ""
        let fields = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] ?? [:]
        switch (method, parts.count, action) {
        case ("POST", 5, "archive"), ("POST", 5, "unarchive"):
            if action == "archive" { FixtureData.archivedIDs.insert(id) } else { FixtureData.archivedIDs.remove(id) }
            return FixtureData.task(id: id).map(ok)
        case ("POST", 5, "status"):
            FixtureData.statuses[id] = fields["status"] as? String
            FixtureData.statusTimes[id] = Date().timeIntervalSince1970
            return FixtureData.task(id: id).map(ok)
        case ("PATCH", 4, _):
            if let title = fields["title"] as? String { titles[id] = title }
            return FixtureData.task(id: id).map { ok(renamed($0, id)) }
        case ("PUT", 5, "pin"):
            return FixtureData.task(id: id).map { ok(#"{"conversation":\#($0),"pinned_at":1700000000}"#) }
        case ("DELETE", 5, "pin"), ("DELETE", 5, "share"):
            if action == "share" { shared.remove(id) }
            return .json(204, Data())
        case ("GET", 5, "share"):
            return shared.contains(id) ? ok(share) : .json(404, Data(#"{"error":"not_found"}"#.utf8))
        case ("PUT", 5, "share"), ("POST", 6, "share"):
            shared.insert(id)
            return ok(share)
        default:
            return nil
        }
    }

    private static func ok(_ json: String) -> FixtureResponse { .ok(json) }

    private static func title(of id: String) -> String? {
        guard let json = FixtureData.task(id: id), let range = json.range(of: #""title":""#) else { return nil }
        return json[range.upperBound...].split(separator: "\"", maxSplits: 1).first.map(String.init)
    }

    private static func renamed(_ json: String, _ id: String) -> String {
        guard let title = titles[id], let old = Self.title(of: id) else { return json }
        return json.replacingOccurrences(of: #""title":"\#(old)""#, with: #""title":"\#(title)""#)
    }
}
