import Foundation

/// The fixture's server state: 30 running Tasks plus a few finished ones for the Inbox, five Loop Tasks (scheduled
/// paused, running and ended, one on updates and one on a trigger the client cannot read), two archived Tasks behind an empty first page, a Slack card with two messages, a Linear card
/// with two issues, a project whose image can't load and a prompt, a GitHub card with a pull request on the personal
/// account beside a quiet acme one, three workspace skills, and the router chat's 30 messages, the newest of which
/// references Task 0.
enum FixtureData {
    /// id, title, status, origin, client platform and age in seconds, newest first after the running Tasks.
    private static let finished: [(String, String, String, String?, String?, Double)] = [
        ("review0", "Review the launch checklist", "ready_for_review", "slack", nil, 300),
        ("review1", "Draft the Q4 planning notes", "ready_for_review", "comma", "macos", 3 * 3600),
        ("done0", "Summarize this week’s support tickets", "completed", "telegram", "ios", 26 * 3600),
        ("done1", "Compare the three vendor quotes", "completed", "comma", "macos", 50 * 3600),
        ("failed0", "Book the team offsite venue", "failed", "slack", nil, 74 * 3600),
        ("loop0", "Check competitor prices every morning", "escalated", "comma", "ios", 600),
        ("loop1", "Post the metrics digest on Mondays and Wednesdays", "active", "slack", nil, 2 * 3600),
        ("watch0", "Watch PR #12 for new comments", "active", "comma", "macos", 40 * 60),
        ("hook0", "Tidy the release notes after each deploy", "active", "slack", nil, 5 * 3600),
    ]
    /// What wakes a fixture Loop: a cron with the windows it fires at on Shanghai's wall clock (weekday 1 is Sunday),
    /// the updates the person named, or a cadence kind the client does not know yet.
    private enum Trigger {
        case cron(String, [DateComponents])
        case events(String)
        case unknown
    }
    /// The Loop Tasks' Loops: id, trigger, wakes so far, run limit and stop condition. A Loop also ended (`done0`, by
    /// its last run) or ended by hand reads as ended, as the server sends it.
    private static let loops: [(String, Trigger, Int, Int?, String?)] = [
        ("loop0", .cron("0 9 * * *", [DateComponents(hour: 9, minute: 0)]), 4, 14, nil),
        ("loop1", .cron("30 18 * * 1,3", [2, 4].map { DateComponents(hour: 18, minute: 30, weekday: $0) }), 7, nil,
         "the Q4 launch ships"),
        ("done0", .cron("0 9 * * 1", [DateComponents(hour: 9, minute: 0, weekday: 2)]), 4, 4, nil),
        ("watch0", .events("new comments on PR #12"), 3, nil, nil),
        ("hook0", .unknown, 2, nil, nil),
    ]
    private static let archived: [(String, String, String)] = [
        ("arch0", "Clean up the old design tokens", "completed"),
        ("arch1", "Collect feedback on the beta", "ready_for_review"),
    ]

    static func task(id: String) -> String? {
        let archived = archivedIDs.contains(id) ? #","archived_at":1700000000"# : ""
        if id.hasPrefix("task"), let index = Int(id.dropFirst(4)), (0..<30).contains(index) {
            let status = statuses[id] ?? "running"
            return #"{"id":"\#(id)","group_id":"g","title":"Task \#(index)","status":"\#(status)","kind":"agent_task","updated_at":1700000000\#(archived)}"#
        }
        guard let row = finished.first(where: { $0.0 == id }) else { return nil }
        let status = statuses[id] ?? (accepted.contains(id) ? "completed" : row.2)
        let review = status == "ready_for_review" ? #","review_version":1"# : ""
        let now = Date().timeIntervalSince1970
        // A status set by hand changed the Task then.
        let updated = statusTimes[id] ?? now - row.5
        let origin = row.3.map { #","origin":"\#($0)""# } ?? ""
        let platform = row.4.map { #","client_platform":"\#($0)""# } ?? ""
        // A running Loop has run up to now; one that waits on the member or finished, up to when it did that.
        let ranUntil = min(statusTimes[id] ?? now, row.2 == "active" ? now : now - row.5)
        let loop = loopValue(id: id, status: status, ranUntil: ranUntil, now: now).map { #","loop":\#($0)"# } ?? ""
        let availability = #"{"allowed":true,"reason":null}"#
        return #"{"id":"\#(row.0)","group_id":"g","title":"\#(row.1)","status":"\#(status)","kind":"agent_task","updated_at":\#(Int(updated))\#(review)\#(origin)\#(platform)\#(archived)\#(loop),"archive_availability":\#(availability)}"#
    }

    /// A Loop Task's public `loop`: active while the Task is, paused (waiting) while it waits on the member, and
    /// ended once it ran its last run or the member ended the Task. Its last wake is its cron's latest window up to
    /// `ranUntil` (an hour before then for other triggers), its next run the cron's window after now while it is
    /// active, and a Loop ended by hand ended when the member did it. Times are epoch milliseconds.
    private static func loopValue(id: String, status: String, ranUntil: Double, now: Double) -> String? {
        guard let loop = loops.first(where: { $0.0 == id }) else { return nil }
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let windows: [DateComponents], cadence: String
        switch loop.1 {
        case .cron(let cron, let fires):
            windows = fires
            cadence = #"{"cron":"\#(cron)","timezone":"Asia/Shanghai"}"#
        case .events(let events):
            windows = []
            cadence = #"{"events":"\#(events)"}"#
        case .unknown:
            windows = []
            cadence = #"{"webhook":"deploys"}"#
        }
        let window = { (seconds: Double, direction: Calendar.SearchDirection) in
            windows.compactMap {
                shanghai.nextDate(after: Date(timeIntervalSince1970: seconds), matching: $0, matchingPolicy: .nextTime,
                                  direction: direction)?.timeIntervalSince1970
            }
        }
        let ms = { (seconds: Double) in Int(seconds * 1000) }
        let lastWake = window(ranUntil, .backward).max() ?? ranUntil - 3600
        let limit = loop.3.map { #","max_runs":\#($0)"# } ?? ""
        let until = loop.4.map { #","until":"\#($0)""# } ?? ""
        let facts = #""cadence":\#(cadence)\#(limit)\#(until),"started_at":\#(ms(now - 30 * 86400)),"wake_count":\#(loop.2),"last_wake_at":\#(ms(lastWake))"#
        // The last run ends a Loop as it wakes; Done or Cancelled ends it when the member sets it.
        let end: (String, Double)? = loop.2 == loop.3 ? ("max_runs", lastWake + 5)
            : ["completed", "cancelled"].contains(status) ? (status, statusTimes[id] ?? now) : nil
        if let end {
            return #"{"state":"ended","reason":"\#(end.0)",\#(facts),"ended_at":\#(ms(end.1))}"#
        }
        guard status == "active" else { return #"{"state":"paused","reason":"waiting",\#(facts)}"# }
        let next = window(now, .forward).min().map { #","next_run_at":\#(ms($0))"# } ?? ""
        return #"{"state":"active",\#(facts)\#(next)}"#
    }

    /// Tasks whose review was accepted (Mark as done); they read as completed from then on.
    nonisolated(unsafe) static var accepted: Set<String> = []
    /// Statuses set by hand (Done or Cancelled) and when, and Tasks archived during the launch
    /// (`FixtureTaskActions`).
    nonisolated(unsafe) static var statuses: [String: String] = [:]
    nonisolated(unsafe) static var statusTimes: [String: Double] = [:]
    nonisolated(unsafe) static var archivedIDs: Set<String> = []
    /// Every live Task, for search.
    static var taskIDs: [String] { (0..<30).map { "task\($0)" } + finished.map(\.0) }

    static func taskPage() -> String {
        let ids = taskIDs.filter { !archivedIDs.contains($0) }
        return #"{"data":[\#(ids.compactMap(task(id:)).joined(separator: ","))],"has_more":false}"#
    }

    /// The archive's first page is empty but has more, as the server's post-fetch filtering can leave it.
    static func archivedPage(cursor: String?) -> String {
        guard cursor == "archive-2" else { return #"{"data":[],"has_more":true,"next_cursor":"archive-2"}"# }
        let rows = archived.map { id, title, from in
            #"{"id":"\#(id)","group_id":"g","title":"\#(title)","status":"archived","kind":"agent_task","archived_at":1700000000,"archived_from_status":"\#(from)","updated_at":1700000000}"#
        }
        return #"{"data":[\#(rows.joined(separator: ","))],"has_more":false}"#
    }

    /// The router chat's messages as JSON, oldest first; `--perf-long-chat` swaps in `PerfChat`'s.
    static let routerMessages: [String] = (0..<30).map { index in
        let reference = index == 29 ? #",{"type":"conversation_ref","conversation_id":"task0","title":"Task 0"}"# : ""
        // Two Tasks named inline, the first in a line of Chinese, for `InlineTaskUITests`. Neither is loaded, so
        // each shows the status it was sent with.
        if index == 27 {
            return #"{"message_id":"message27","kind":"message","actor_type":"agent","content":[{"type":"text","text":"我已开始注册 Meta 官方 Muse 账号，进度在这里："},{"type":"conversation_ref","conversation_id":"inline-muse","title":"注册 Meta Muse","presentation":"inline","kind":"agent_task","status":"in_progress"},{"type":"text","text":" 完成后告诉你。Also a Latin line with "},{"type":"conversation_ref","conversation_id":"inline-review","title":"Review launch","presentation":"inline","kind":"agent_task","status":"in_progress"},{"type":"text","text":" inline."}]}"#
        }
        return #"{"message_id":"message\#(index)","kind":"message","actor_type":"agent","content":[{"type":"text","text":"History message \#(index). This is a reply in the Home conversation."}\#(reference)]}"#
    }

    /// A Task's messages as JSON, oldest first: review0 holds a Worker's history long enough to scroll; the others none.
    static func taskMessages(id: String) -> [String] {
        guard id == "review0" else { return [] }
        return (0..<20).map { index in
            #"{"message_id":"review0-m\#(index)","kind":"message","actor_type":"agent","content":[{"type":"text","text":"Worker update \#(index). Checked another part of the launch list and noted what is left."}]}"#
        }
    }

    static func routerConversation(_ messages: ArraySlice<String>) -> String {
        #"{"id":"home","group_id":"g","title":"Home","status":"open","kind":"user_chat","messages":[\#(messages.joined(separator: ","))]}"#
    }

    /// A history page of `limit` messages before the 1-based sequence `before`, or the newest ones.
    static func messagePage(_ messages: [String], limit: Int, before: Int?) -> String {
        let end = min(messages.count, before.map { $0 - 1 } ?? messages.count)
        let start = max(0, end - limit)
        let covered = start < end ? "{\"first\":\(start + 1),\"last\":\(end)}" : "null"
        return "{\"data\":[\(messages[start..<max(start, end)].joined(separator: ","))],\"covered\":\(covered),\"bounds\":{\"first\":1,\"last\":\(messages.count)},\"has_older\":\(start > 0),\"has_newer\":false}"
    }

    /// The workspace's skills as the server projects them: a system skill, an imported one without a description
    /// and a per-message one, each at its runtime location.
    static let skills = #"""
    {"data":[
      {"skill_id":"frontend-design","name":"Frontend design","description":"Distinctive, production-grade interfaces with high design quality","location":"/.runtime/skills/frontend-design/SKILL.md","source":"system","activation":"regular"},
      {"skill_id":"pdf","name":"PDF","description":"","location":"/.runtime/skills/pdf/SKILL.md","source":"imported","activation":"regular"},
      {"skill_id":"release-notes","name":"Release notes","description":"Turn merged work into release notes","location":"/.runtime/skills/release-notes/SKILL.md","source":"custom","activation":"per-message"}]}
    """#

    /// The model catalog: two models an OpenAI key serves (one with thinking efforts) and one only a Claude plan
    /// would, which no profile of the Workspace signs in to.
    static let modelCatalog = #"""
    {"sources":{"openai":{"name":"OpenAI","kind":"api_key"},"claude":{"name":"Claude","kind":"subscription"}},"models":[
      {"id":"gpt-5.5","name":"GPT 5.5","vendor":"openai","efforts":["low","medium","high"],"routes":{"openai":{"model":"gpt-5.5","protocol":"responses"}}},
      {"id":"gpt-5.5-mini","name":"GPT 5.5 mini","vendor":"openai","efforts":[],"routes":{"openai":{"model":"gpt-5.5-mini","protocol":"responses"}}},
      {"id":"claude-opus-5","name":"Claude Opus 5","vendor":"anthropic","efforts":["low","high"],"routes":{"claude":{"model":"claude-opus-5","protocol":"anthropic"}}}]}
    """#

    /// The Workspace's one profile, an OpenAI key.
    static let modelProfiles = #"""
    {"accounts":[{"id":"p1","credential_kind":"provider_api_key","source":"openai","disabled":false,"status":"active","version":"1"}],"next":""}
    """#

    static let agentModels = #"""
    {"workspace_id":"w","agents":{"router":{"agent_id":"a1","name":"Comma","role":"router"}},"task_model":{"selection":{"kind":"builtin"}}}
    """#

    /// A sent message as the server echoes it: the member's text under the send's request id.
    static func sentMessage(text: String, requestID: String) -> String {
        let quoted = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return #"{"message_id":"sent-\#(requestID)","kind":"message","actor_type":"user","user_id":"u","client_request_id":"\#(requestID)","content":[{"type":"text","text":\#(quoted)}]}"#
    }

    static let recommendations = #"""
    {"state":"fresh","settings":{"autoEnableNewSources":true,"schedule":{"enabled":false,"hour":9,"minute":0,"timezone":"UTC"},
      "sourcesCheckedAt":"2023-11-14T22:13:20Z","sourceRevision":1,"sources":[
      {"appId":"slack","appName":"Slack","connectionId":"conn-slack","enabled":true,"kind":"composio","label":"acme"},
      {"appId":"linear","appName":"Linear","connectionId":"conn-linear","enabled":true,"kind":"composio","label":"acme"},
      {"appId":"github","appName":"GitHub","connectionId":"conn-github","enabled":true,"kind":"composio","label":"acme"},
      {"appId":"github","appName":"GitHub","connectionId":"conn-github-2","enabled":true,"kind":"composio","label":"personal"}]},
     "snapshot":{"generatedAt":1700000000000,"generation":1,"protocolVersion":1,"sourceRevision":1,"templateCatalogVersion":1,"warnings":[],
      "summary":[{"kind":"markdown","text":"Your work briefing\n\nTwo things need you before the **3 pm launch sync**: Ada is waiting on the final launch date, and the #launch thread moved fast this morning. "},
        {"kind":"inline-task","task":{"label":"Review the launch checklist","conversationId":"review0","sourceId":"conn-slack"}},
        {"kind":"markdown","text":" is ready for your review, and a pull request waits on you in GitHub."}],
      "prompts":{"p2":{"sourceId":"conn-slack","objective":"Reply to Ada about the launch date",
        "context":"Ada asked in #launch whether the launch date is final.","contextLabel":"Slack"}},
      "cards":[{"id":"card-slack","title":"Slack","template":"text-list@1","sourceIds":["conn-slack"],"fallbackText":"Slack","items":[
        {"id":"item-1","parts":[{"kind":"markdown","text":"Summarize the "},
          {"kind":"inline-link","link":{"label":"#launch","href":"https://acme.slack.com/archives/C04LAUNCH","sourceId":"conn-slack"}},
          {"kind":"markdown","text":" thread before the 3 pm sync"}],
         "action":{"type":"open_task_form","label":"Ask Comma","prompt":"Summarize the #launch thread before the 3 pm sync","requiresConfirmation":false}},
        {"id":"item-2","parts":[{"kind":"inline-link","link":{"label":"Ada Lovelace","href":"https://acme.slack.com/archives/C04LAUNCH/p1700000000","sourceId":"conn-slack"}},
          {"kind":"markdown","text":" is waiting on your reply: is the launch date final?"}],
         "action":{"type":"send_to_comma","label":"Ask Comma","promptId":"p2","requiresConfirmation":true}}]},
        {"id":"card-linear","title":"Linear","template":"text-list@1","sourceIds":["conn-linear"],"fallbackText":"Linear","items":[
        {"id":"item-5","parts":[{"kind":"markdown","text":"Login fails on iPad since this morning’s build · ENG-142 · Urgent"}],
         "action":{"type":"open_url","label":"Open","href":"https://linear.app/acme/issue/ENG-142","requiresConfirmation":false}},
        {"id":"item-6","parts":[{"kind":"markdown","text":"Sync stalls when the app returns from background · ENG-139 · In Review"}],
         "action":{"type":"open_url","label":"Open","href":"https://linear.app/acme/issue/ENG-139","requiresConfirmation":false}},
        {"id":"item-4","parts":[{"kind":"markdown","text":"Break "},
          {"kind":"inline-link","link":{"label":"ENG-150","href":"https://linear.app/acme/issue/ENG-150","sourceId":"conn-linear"}},
          {"kind":"markdown","text":" into tasks before Thursday’s planning"}],
         "action":{"type":"open_task_form","label":"Ask Comma","prompt":"Break ENG-150 into tasks before Thursday’s planning","requiresConfirmation":false}}]},
        {"id":"card-linear-project","title":"Linear","template":"media-list@1","sourceIds":["conn-linear"],"fallbackText":"Q4 roadmap review","items":[
        {"id":"item-3","title":"Q4 roadmap review","description":"Project · 3 issues moved to In Review overnight","imageUrl":"https://fixture.invalid/roadmap.png",
         "action":{"type":"open_url","label":"Open","href":"https://linear.app/acme/project/q4-roadmap","requiresConfirmation":false}}]},
        {"id":"card-github","title":"GitHub","template":"text-list@1","sourceIds":["conn-github-2"],"fallbackText":"GitHub","items":[
        {"id":"item-7","parts":[{"kind":"markdown","text":"Fix the token refresh race in the sync client · alex/notes-sync #31 · Review requested"}],
         "action":{"type":"open_url","label":"Open","href":"https://github.com/alex/notes-sync/pull/31","requiresConfirmation":false}},
        {"id":"item-8","parts":[{"kind":"markdown","text":"Find why the checks on "},
          {"kind":"inline-link","link":{"label":"#29","href":"https://github.com/alex/notes-sync/pull/29","sourceId":"conn-github-2"}},
          {"kind":"markdown","text":" fail and suggest a fix"}],
         "action":{"type":"open_task_form","label":"Ask Comma","prompt":"Find why the checks on alex/notes-sync#29 fail and suggest a fix","requiresConfirmation":false}}]}]}}
    """#
}
