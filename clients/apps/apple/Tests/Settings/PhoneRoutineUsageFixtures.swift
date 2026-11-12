import Foundation
@testable import Comma

/// Synthetic values for native rendering. Runtime tests send the API forms through the production core.
enum PhoneRoutineUsageFixtures {
    static var envelope: [String: Any] {
        ["state": "empty", "snapshot": NSNull(), "settings": ["autoEnableNewSources": true,
            "schedule": ["enabled": true, "hour": 8, "minute": 30, "timezone": "Asia/Singapore"],
            "sourcesCheckedAt": "2026-11-01T00:00:00Z", "sourceRevision": 1,
            "sources": [["connectionId": "github-1", "appId": "github", "appName": "GitHub", "label": "AFK-surf", "kind": "managed_oauth", "enabled": true],
                        ["connectionId": "linear-1", "appId": "linear", "appName": "Linear", "label": "Comma", "kind": "managed_oauth", "enabled": true],
                        ["connectionId": "slack-1", "appId": "slack", "appName": "Slack", "label": "Design team", "kind": "managed_oauth", "enabled": false]]]]
    }

    static var plan: [String: Any] {
        ["plan_key": "plus_monthly", "package_code": "plus", "package_version": "v1", "mode": "subscription",
         "name": "Plus", "currency": "USD", "amount_minor": 2000, "grant_credits": 20_000_000, "billing_period": "month"]
    }

    static var summary: [String: Any] {
        ["billing_account_id": "billing-1", "current_credits": 12_500_000,
         "active_subscription": ["package_code": "plus", "package_version": "v1", "status": "active", "source_id": "sub-fixture", "plan": plan],
         "active_grants": [["id": "cycle-1", "package_code": "plus", "package_version": "v1", "original_credits": 20_000_000,
            "remaining_credits": 12_000_000, "valid_from": "2026-11-01T00:00:00Z", "expires_at": "2026-12-01T00:00:00.000Z",
            "source_type": "subscription_cycle", "source_id": "sub-fixture"],
            ["id": "welcome-1", "package_code": NSNull(), "package_version": NSNull(), "original_credits": 500_000,
             "remaining_credits": 500_000, "valid_from": "2026-11-01T00:00:00Z", "expires_at": NSNull(), "source_type": "comma_signup", "source_id": NSNull()]]]
    }

    static var billing: [String: Any] {
        ["status": "ready", "workspace": ["id": "w1", "name": "Personal"], "plans": [plan], "summary": summary,
         "allowance": NSNull(), "planUsage": ["usedPercent": 40, "resetsAt": "2026-12-01T00:00:00.000Z", "ends": false, "otherCredits": 500_000], "unlimited": false]
    }

    static var suggestions: [[String: Any]] {
        [["id": "next", "label": "整理下一步", "prompt": "整理下一步"],
         ["id": "risks", "label": "检查风险", "prompt": "检查风险"],
         ["id": "summary", "label": "总结改动", "prompt": "总结改动"],
         ["id": "tasks", "label": "拆成任务", "prompt": "拆成任务"]]
    }

    static func chat(_ id: String = "answer-1", busy: Bool = false) -> [String: Any] {
        ["revision": 1, "state": ["status": "ready", "loaded": true,
            "conversation": ["id": "router", "group_id": "g1", "title": "Comma", "status": "active", "kind": "user_chat"],
            "serverMessages": [["messageId": "question", "seq": 1, "role": "user", "actorType": "user", "text": "帮我检查这次发布的准备情况。"],
                ["messageId": id, "seq": 2, "role": "assistant", "actorType": "agent", "text": "发布准备已检查完毕。\n\n核心流程已通过验证，建议先确认剩余风险，再安排发布后的观察任务。"]],
            "reply": ["coming": busy, "working": busy]]]
    }

    static func configure(_ core: FakeCore) {
        core.serve("recommendations") { _ in ["envelope": envelope, "refreshing": false, "failure": NSNull()] }
        core.serve("proactive") { _ in ["kind": "ready", "groupId": "g1", "enabled": true] }
        core.serve("billing") { _ in billing }
        core.serve("chatView") { _ in chat() }
        core.serve("chatSuggestions") { _ in suggestions }
    }
}
