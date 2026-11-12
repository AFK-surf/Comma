import Foundation
@testable import Comma

/// Synthetic accounts and files for native rendering and behavior tests. No service is contacted.
enum PhoneFeatureFixtures {
    static func plugin(_ id: String = "github", installed: Bool = true) -> [String: Any] {
        ["id": id, "name": id == "github" ? "GitHub" : "Google Workspace", "brand": id,
         "summary": id == "github" ? "Work with repositories, issues and pull requests" : "Use your mail, calendar and files",
         "description": id == "github" ? "Connect GitHub so Comma can work with your repositories, review changes and manage issues." : "Connect your Google account to work with mail, calendar and files.",
         "category": "Productivity", "installed": installed, "locked": false, "activity": "idle", "toolGroups": true,
         "mcps": [["id": "github", "name": "GitHub"]], "skills": [["id": "review", "name": "Code review"]]]
    }

    static var plugins: [String: Any] {
        ["status": "ready", "workspace": "w1", "plugins": [plugin(), plugin("google-workspace", installed: false)], "installed": ["github"], "categories": []]
    }

    static var sources: [String: Any] {
        ["sources": [["connectionId": "connection-1", "toolkit": "GitHub", "kind": "managed_oauth", "state": "ready",
                      "selectedAccountId": "alex@example.com", "candidates": [["id": "alex@example.com"]]]]]
    }

    static var groups: [String: Any] {
        ["groups": [["id": "repos", "name": "Repositories", "enabled": true],
                    ["id": "issues", "name": "Issues and pull requests", "enabled": true],
                    ["id": "actions", "name": "GitHub Actions", "enabled": false]]]
    }

    static var profile: [String: Any] {
        ["id": "profile-1", "source": "codex", "name": "Alex’s ChatGPT", "email": "alex@example.com", "disabled": false,
         "status": "active", "credential_kind": "subscription_oauth", "version": "v1", "subscription": true, "usable": true,
         "meters": [["window": "5h", "percent": 76], ["window": "week", "percent": 54]]]
    }

    static var catalog: [String: Any] {
        ["sources": ["openai": ["name": "OpenAI", "kind": "api_key"], "codex": ["name": "ChatGPT", "kind": "subscription"]],
         "models": [["id": "gpt-5.5", "name": "GPT-5.5", "vendor": "openai", "efforts": ["low", "medium", "high"],
                     "routes": ["codex": ["model": "gpt-5.5", "protocol": "responses"]]]]]
    }

    static var agents: [String: Any] {
        ["workspace_id": "w1", "agents": ["router": ["agent_id": "router-agent", "name": "Comma", "role": "router", "reply_style": "concise",
           "selection": ["kind": "catalog", "model": "gpt-5.5", "reasoning_effort": "high", "profile_id": NSNull(), "allow_paid": false]]],
         "task_model": ["selection": ["kind": "builtin"]], "task_place": ["place": ["kind": "salix"]]]
    }

    static var models: [String: Any] {
        ["workspace": "w1", "catalog": catalog, "profiles": [profile, apiProfile], "agents": agents, "error": false, "moreProfiles": false,
         "presets": [["id": "openai", "name": "OpenAI", "keySource": "openai", "subscriptionSource": "codex"]],
         "models": [["id": "gpt-5.5", "name": "GPT-5.5", "vendor": "openai", "efforts": ["low", "medium", "high"], "serving": ["profile-1"]]]]
    }

    static var apiProfile: [String: Any] {
        ["id": "profile-key", "source": "openai", "name": "Project API key", "disabled": false,
         "status": "active", "credential_kind": "provider_api_key", "version": "v1", "subscription": false,
         "key_hint": "sk-…demo", "usable": true, "meters": []]
    }

    static func file(_ name: String = "Launch brief.pdf", index: Int = 0) -> [String: Any] {
        ["conversation_id": "task-1", "task_title": "Prepare the launch", "message_id": "files-message", "index": index,
         "seq": 4, "type": "file", "file_name": name, "mime_type": name.hasSuffix("png") ? "image/png" : "application/pdf",
         "size": 248_320 + index * 145_000, "created_at": 1_793_415_000_000]
    }

    static func configure(_ core: FakeCore) {
        core.serve("plugins") { _ in plugins }
        core.serve("pluginSources") { _ in sources }
        core.serve("pluginToolGroups") { _ in groups }
        core.serve("pluginNotices") { _ in ["notices": []] }
        core.serve("models") { _ in models }
        core.serve("router") { _ in ["agent": "router-agent", "name": "Comma", "reply_style": "concise"] }
        core.on("router.refresh") { _ in ["agent_id": "router-agent", "name": "Comma", "role": "router", "reply_style": "concise"] }
        core.on("systemFiles.instructions") { _ in
            ["content": "Keep replies concise and practical.\n\nWhen reviewing work, explain the trade-offs and suggest the next concrete step.", "hash": "instructions-v1"]
        }
        core.on("taskFiles.list") { _ in
            ["status": "ready", "files": [file(), file("Website preview.png", index: 1), file("Release notes.md", index: 2)], "nextCursor": NSNull()]
        }
    }
}
