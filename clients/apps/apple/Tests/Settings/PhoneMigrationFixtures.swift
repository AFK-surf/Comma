import Foundation
@testable import Comma

enum PhoneMigrationFixtures {
    static var pr: [String: Any] {
        ["url": "https://github.com/fixture/ios/pull/42", "number": 42, "title": "Polish Duo settings", "body": "Align section headings and keep navigation state.", "headSha": String(repeating: "a", count: 40), "state": "open", "mergeable": "mergeable", "checks": ["passed": 4, "failed": 0, "skipped": 0, "total": 4], "newCommits": false]
    }
    static var changes: [String: Any] {
        ["source": "sandbox", "base": "main", "branch": "codex/duo-settings", "truncated": false, "uncommitted": true,
         "files": [["path": "Settings/ColumnTitle.swift", "status": "modified", "additions": 12, "deletions": 4, "patch": "@@ -1,3 +1,4 @@\n- .frame(maxWidth: .infinity)\n+ .frame(maxWidth: .infinity, alignment: .leading)\n+ .padding(.horizontal, GroupedSurface.margin)"]],
         "pullRequest": pr, "commits": [["sha": String(repeating: "b", count: 40), "title": "Align settings headings", "author": "Alex", "at": "2026-11-01T01:00:00Z"]]]
    }
    static var driveFile: [String: Any] {
        ["id": "system:memory/scoped/project.md", "spaceId": "comma-system-files", "name": "project.md", "folderPath": "memory/scoped", "contentsHash": "v1", "deviceId": "", "modifiedAt": 1793494800000, "sizeBytes": 124,
         "system": ["kind": "vfs", "group": "g1", "path": "/memory/scoped/project.md", "hash": "v1"], "writable": true]
    }
    static var driveHierarchy: [String: Any] {
        func file(_ id: String, _ name: String, _ folder: String, space: String = "projects") -> [String: Any] {
            ["id": id, "spaceId": space, "name": name, "folderPath": folder, "sizeBytes": 128]
        }
        var foreign = driveFile
        foreign["id"] = "foreign"; foreign["name"] = "private.md"
        foreign["system"] = ["kind": "vfs", "group": "other-group", "path": "/memory/scoped/private.md"]
        return ["node": ["status": "off"],
                "spaces": [["id": "comma-system-files", "name": ""], ["id": "projects", "name": "Projects"], ["id": "empty", "name": "Empty space"]],
                "files": [driveFile, foreign,
                          file("root", "readme.md", ""),
                          file("roadmap", "roadmap.md", "Design/2026"),
                          file("brief", "brief.md", "Design"),
                          file("sibling", "old.md", "Design-archive"),
                          file("system-root", "Instructions.md", "", space: "comma-system-files")]]
    }
    static var request: [String: Any] {
        ["id": "request-1", "title": "Review the iOS release", "content": "Please review the new Duo settings and the coding workflow.", "status": "pending", "sender": ["id": "alex", "name": "Alex Chen", "email": "alex@example.com"], "created_at": 1793494800, "expires_at": 1794099600]
    }
    static var requestLayout: [String: Any] {
        ["workspace": "w1", "incoming": [request],
         "grants": [["id": "grant-review", "status": "active", "mode": "review", "daily_limit": 10, "grantee": ["name": "Alex Chen", "email": "alex@example.com"]],
                    ["id": "grant-auto", "status": "active", "mode": "auto_accept", "daily_limit": 20, "grantee": ["name": "Jamie Lee", "email": "jamie@example.com"]],
                    ["id": "grant-invite", "status": "invited", "mode": "review", "invite_expires_at": 1794099600, "invite_url": "https://app.example.test/invite/sample"]],
         "targets": [["grant_id": "target-1", "workspace": ["name": "Design team", "owner": ["name": "Jamie Lee"]], "daily_limit": 10, "pending_limit": 5, "sent_today": 2, "pending": 1]],
         "sent": [["id": "sent-1", "title": "Review the release plan", "status": "pending", "workspace": ["name": "Design team", "owner": ["name": "Jamie Lee"]]]],
         "links": [["id": "slack-1", "provider": "Slack", "name": "Alex Chen", "email": "alex@example.com", "workspace": "Design team"]],
         "own": "review", "error": false]
    }
    static var voice: [String: Any] {
        ["workspace": "w1", "integration": ["lines": ["+12025550101"], "numbers": [["e164": "+6585550101", "pin_set": true, "status": "verified"]], "readiness": ["ready": true], "call_readiness": ["ready": true], "voices": ["alloy", "coral", "sage"], "preferences": ["voice": ["kind": "preset", "name": "coral"], "custom_voice": ["name": "Calm guide", "description": "Warm and clear"], "router_calls": true]], "keys": [["key_id": "key-1", "name": "Personal voice client", "prefix": "comma_voice_1234…", "status": "active"]], "integrationError": false, "keysError": false]
    }
    static func configure(_ core: FakeCore) {
        PhoneRoutineUsageFixtures.configure(core)
        core.serve("models") { _ in
            var agents = PhoneFeatureFixtures.agents
            agents["task_place"] = ["place": ["kind": "salix"], "sandboxes": true]
            return ["workspace": "w1", "catalog": PhoneFeatureFixtures.catalog, "presets": [], "profiles": [PhoneFeatureFixtures.profile], "models": [["id": "gpt-5.5", "name": "GPT-5.5", "vendor": "openai", "serving": ["profile-1"]]], "agents": agents, "error": false]
        }
        core.on("coding.repos") { _ in [["owner": "fixture", "name": "ios", "defaultBranch": "main", "private": true]] }
        core.on("coding.repoOwners") { _ in ["owners": [["login": "alex", "kind": "user"], ["login": "AFK-surf", "kind": "organization"], ["login": "Comma", "kind": "organization"]], "hasMore": false] }
        core.on("coding.repoSearch") { p in
            let owner = p["owner"] as? String ?? "AFK-surf"
            let query = p["query"] as? String ?? ""
            let names = ["Cue", "comma-ios", "comma-desktop", "design-system", "docs", "salix"]
            return ["repos": names.filter { query.isEmpty || $0.localizedStandardContains(query) }.map { ["owner": owner, "name": $0, "defaultBranch": "main", "private": true] as [String: Any] }, "hasMore": false, "limited": false]
        }
        core.on("coding.branches") { _ in ["main", "release/ios"] }
        core.serve("stations") { _ in ["workspace": "w1", "stations": [], "loading": false] }
        core.on("chat.startTask") { _ in ["conversationId": "cloud-task", "groupId": "g1"] }
        core.on("stations.newTask") { _ in ["conversationId": "station:mac:1", "groupId": "g1"] }
        core.on("stations.profiles") { _ in [["id": "local-codex", "name": "Codex", "runtimes": ["codex"], "models": ["gpt-5.5"]]] }
        core.on("coding.start") { _ in ["taskId": "code-1", "groupId": "g1"] }
        core.on("coding.session") { _ in ["repo": ["owner": "fixture", "name": "ios", "baseRef": "main", "branch": "codex/duo-settings"], "state": "ready"] }
        core.on("coding.changes") { _ in changes }
        core.on("coding.history") { _ in ["available": true, "start": 0, "total": 2, "items": [["kind": "received", "id": "received-1", "text": "Align the Duo settings titles"], ["kind": "group", "id": "group-1", "steps": [["kind": "tool", "id": "step-1", "tool": "apply_patch", "hint": "Update ColumnTitle.swift", "body": ["kind": "patch", "diff": "+ alignment: .leading"], "result": "Updated one file", "pending": false, "failed": false]]]]] }
        core.serve("drive") { _ in ["node": ["status": "off"], "spaces": [["id": "comma-system-files", "name": "System Files", "remote": true]], "files": [driveFile, ["id": "skill:review", "spaceId": "comma-system-files", "name": "Code review.md", "folderPath": "Skills", "contentsHash": "skill-1", "sizeBytes": 240, "system": ["kind": "skill", "skill": "review", "workspace": "w1"], "writable": false]], "devices": []] }
        core.on("systemFiles.read") { _ in ["path": "/memory/scoped/project.md", "content": "# iOS release\n\nSupport iPhone and Duo. Keep both settings headings left aligned.\n", "size": 83, "hash": "read-v2"] }
        core.on("systemFiles.write") { p in ["path": p["path"] ?? "", "size": 24, "hash": "saved-v3"] }
        core.on("skills.detail") { _ in ["content": "# Code review\n\nRead the change, check behavior and report actionable findings.", "files": ["SKILL.md"]] }
        core.serve("taskRequests") { _ in ["workspace": "w1", "incoming": [request], "sent": [], "targets": [["grant_id": "target-1", "workspace": ["id": "other", "name": "Design team"], "daily_limit": 10, "pending_limit": 5, "sent_today": 2, "pending": 1]], "grants": [["id": "grant-1", "status": "active", "mode": "review", "daily_limit": 10, "pending_limit": 5, "grantee": ["id": "alex", "name": "Alex Chen"]]], "links": [["id": "slack-1", "provider": "Slack", "name": "Alex", "workspace": "Design team"]], "own": "review", "error": false] }
        core.serve("taskShares") { _ in ["workspace": ["id": "w1", "group_id": "g1", "name": "Comma"], "shares": [["id": "code-1", "title": "Duo layout review", "shared_at": 1793494800, "artifact_count": 2]], "hasMore": false, "loading": false] }
        core.serve("voice") { _ in voice }
        core.serve("routerKeys") { _ in ["workspace": "w1", "keys": [["key_id": "router-key", "name": "Automation", "prefix": "comma_router_1234…", "status": "active"]], "error": false] }
        core.serve("telegram") { _ in ["workspace": "w1", "state": ["configured": true, "official_login_available": true, "bot_username": "comma_bot", "link": ["telegram_username": "alex", "telegram_user_id": "123"]], "busy": false, "error": false] }
        core.serve("wechat") { _ in ["state": ["connection": ["connection_active": true]], "busy": false, "error": false] }
        core.serve("signal") { _ in ["integration": ["bindings": [["binding_id": "signal-1", "kind": "user", "peer": "alex", "display_name": "Alex’s Signal"]]], "number": ["effective": ["e164": "+12025550102"]], "busy": false, "error": false] }
        core.serve("imessage") { _ in ["state": ["connection_active": true, "link": ["sender_handle": "alex@example.com"]], "busy": false, "error": false] }
        core.serve("linear") { _ in ["state": ["installation": ["organization_name": "Comma"], "member": ["linear_user_name": "Alex Chen", "completion_state_policy": "in_review"]], "busy": false, "error": false] }
        core.serve("compute") { _ in ["workspace": "w1", "projection": ["can_manage": true, "environments": [["id": "cloud", "can_create": true]], "workloads": [["id": "shell-1", "name": "iOS development", "kind": "shell", "generation": 3, "phase": "ready", "observed_state": "running", "actions": ["rename": true, "delete": true, "retry": false], "uses": [["kind": "task", "label": "Duo layout review"]]]]], "error": false] }
        core.serve("sessionBrowser") { _ in ["browser": ["agent_id": "agent-1", "session_id": "browser-1"]] }
        core.serve("browserView") { _ in ["tabs": [["tab_id": "tab-1", "title": "Review workspace", "url": "https://example.test"]], "tab": "tab-1", "controlling": true, "status": "human", "pending": false] }
        core.serve("dynamicUi") { _ in ["status": "ready", "ui": ["version": 1, "html": "<div class='card'><h2>Duo layout review</h2><p>Both headings now align to the left.</p><button id='continue'>Continue review</button></div>", "script": "comma.on('continue','click',()=>comma.request('Continue reviewing the iOS changes'));", "data": [:]]] }
        core.serve("dynamicUiState") { _ in ["state": NSNull(), "cards": NSNull()] }
    }
}
