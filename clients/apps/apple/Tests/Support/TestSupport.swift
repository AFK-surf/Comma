import Foundation
import Observation
@testable import Comma

/// A credential record in memory, as the Keychain item would keep it.
final class MemoryRecord: CredentialRecord, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func read() throws -> Data? { lock.withLock { data } }
    func write(_ data: Data) throws { lock.withLock { self.data = data } }
    func delete() throws { lock.withLock { data = nil } }
}

/// Returns once `condition` holds, checking it again each time an observable value it read changes.
@MainActor
func until(_ condition: @escaping @MainActor () -> Bool) async {
    while true {
        let held: Bool = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let now = withObservationTracking { condition() } onChange: { once.resume(false) }
            if now { once.resume(true) }
        }
        if held { return }
    }
}

/// Resumes a continuation the first time only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func resume(_ value: Bool) {
        lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }?.resume(returning: value)
    }
}

let testOrigin = "https://comma-store.test"

/**
 * A `CommaStore` on a `FakeCore`, signed in as `phone-user` with the Workspace `w1` (Group `g1`) and its Router chat
 * `router`. The fake keeps each conversation's draft as the core would: `chatView.setDraft` saves it, and a
 * conversation shown again starts from it.
 */
@MainActor
struct StoreHarness {
    let core = FakeCore()
    let store: CommaStore

    init() throws {
        let custody = try SessionCustody(record: MemoryRecord(), apiOrigin: testOrigin)
        store = CommaStore(configuration: AppConfiguration(baseURL: URL(string: testOrigin)!, credentialService: "CommaTests"),
                           core: core, custody: custody, apple: AppleSignInSheet(),
                           workspacePreferences: UserDefaults(suiteName: UUID().uuidString)!)
        let drafts = Drafts()
        core.on("chat.resolveWorkspaceChat") { _ in
            ["status": "ready", "workspaceId": "w1", "groupId": "g1", "conversationId": "router"]
        }
        core.on("chatView.setDraft") { params in
            drafts.set(params["draft"] as? String ?? "", for: params["conversation"] as? String ?? "")
            return ["revision": 0]
        }
        core.serve("chatView") { topic in
            ["revision": 1, "state": ["status": "ready", "loaded": true, "draft": drafts.get(topic["conversation"] as? String ?? ""),
                                      "conversation": ["id": topic["conversation"] as? String ?? ""]]]
        }
        core.serve("session") { _ in Self.signedIn }
    }

    /// Signs in and waits for the Router chat.
    func start() async {
        await store.start()
        await until { store.router.pane != nil && store.workspace != nil }
    }

    nonisolated(unsafe) static let signedIn: [String: Any] = [
        "phase": "signed_in", "userId": "phone-user",
        "lifecycle": ["phase": "signed_in", "generation": 1, "authority": ["authorityInstanceId": "authority-1"],
                      "principal": ["userId": "phone-user", "email": "phone@example.com"],
                      "session": ["sessionId": "phone-session", "audience": testOrigin, "expiresAtEpochSeconds": 9_999_999_999]],
    ]
}

private final class Drafts: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [String: String] = [:]
    func set(_ text: String, for conversation: String) { lock.withLock { saved[conversation] = text } }
    func get(_ conversation: String) -> String { lock.withLock { saved[conversation] ?? "" } }
}

extension TaskSummary {
    /// A Task as the core's `tasks` topic lists it, in the section `section`.
    static func listed(_ id: String, title: String? = nil, status: String = "active", section: String = "in_progress",
                       updatedAt: Double = 0, group: String = "g", extra: [String: Any] = [:]) -> TaskSummary {
        var item: [String: Any] = ["conversationId": id, "groupId": group, "title": title ?? "Task \(id)", "status": status,
                                   "statusBucket": section, "kind": "agent_task", "updatedAt": updatedAt]
        item.merge(extra) { _, new in new }
        return TaskSummary(item as NSDictionary)!
    }
}

extension TaskSummary {
    /// A listed Task with the server's `status`, in the section the core folds it into.
    static func withStatus(_ id: String, _ status: String, updatedAt: Double = 0, extra: [String: Any] = [:]) -> TaskSummary {
        let section = switch status {
        case "ready_for_review": "needs_review"
        case "completed": "done"
        case "failed", "cancelled": "cancelled"
        case "archived": "archived"
        default: "in_progress"
        }
        return .listed(id, title: id, status: status, section: section, updatedAt: updatedAt, extra: extra)
    }
}

extension CoreClient {
    /// Stops the core and returns once its databases closed, so a test may remove their directory.
    func closed() async { await withCheckedContinuation { continuation in close { continuation.resume() } } }
}
