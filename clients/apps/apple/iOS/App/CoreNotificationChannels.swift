import CommaCore
import Foundation

/// A registration the core's `notifications.*` calls answered, as the notification controllers take it.
private func registration(_ answer: NSDictionary) throws -> NotificationRegistration {
    guard let id = answer.string("id"),
          let data = try? JSONSerialization.data(withJSONObject: ["id": id, "status": "active"]) else {
        throw CoreError(code: "bad_response", message: "The registration has no id.")
    }
    return try JSONDecoder().decode(NotificationRegistration.self, from: data)
}

/**
 * The device's APNs slot for one session, through the client core (`notifications.registerDevice`,
 * `notifications.unregisterDevice`). A registration names the session it is for: the core refuses one for a session
 * that is no longer the current one. Retiring the slot of a session that has ended needs nothing: the server delivers
 * only to open sessions.
 */
struct CoreDeviceNotificationChannel: DeviceNotificationTransport {
    let core: any CoreAPI
    let sessionID: String
    let accountID: String
    /// Whether `sessionID` is still the session signed in.
    let current: @Sendable () async -> Bool

    func register(token: String, environment: PushEnvironment, workspace: Workspace, bundleID: String,
                  locale: String) async throws -> NotificationRegistration {
        try registration(try await core.object("notifications.registerDevice", [
            "session": sessionID, "workspace": workspace.id, "group": workspace.groupID, "token": token,
            "environment": environment.rawValue, "bundleId": bundleID, "locale": locale,
        ]))
    }

    func retire() async throws {
        guard await current() else { return }
        _ = try await core.call("notifications.unregisterDevice")
    }
}

/// The Tasks Live Activity's push tokens for one session and Workspace, through the client core
/// (`notifications.registerActivity`, `notifications.unregister`).
struct CoreActivityNotificationChannel: ActivityNotificationTransport {
    let core: any CoreAPI
    let sessionID: String
    let accountID: String
    let workspace: Workspace
    let environment: PushEnvironment
    let bundleID: String
    let locale: String
    let current: @Sendable () async -> Bool

    func register(token: String, activityID: String?, registrationID: String) async throws -> NotificationRegistration {
        var params: [String: Any] = [
            "session": sessionID, "workspace": workspace.id, "group": workspace.groupID, "token": token,
            "environment": environment.rawValue, "bundleId": bundleID, "locale": locale, "registration": registrationID,
        ]
        if let activityID { params["activity"] = activityID }
        let answer = try registration(try await core.object("notifications.registerActivity", params))
        guard answer.id.caseInsensitiveCompare(registrationID) == .orderedSame else {
            throw CoreError(code: "bad_response", message: "The registration is another one.")
        }
        return answer
    }

    func retire(id: String, reason: ActivityRetirementReason) async throws {
        guard await current() else { return }
        _ = try await core.call("notifications.unregister", ["id": id, "reason": reason.rawValue])
    }
}

extension CommaStore {
    /// The device's push slot for the session signed in now.
    func deviceNotificationChannel() throws -> any DeviceNotificationTransport {
        guard let session else { throw CoreError(code: "signed_out", message: "No one is signed in.") }
        let id = session.id
        return CoreDeviceNotificationChannel(core: core, sessionID: id, accountID: session.user.id) { [weak self] in
            await MainActor.run { self?.session?.id == id }
        }
    }

    /// The Live Activity's push tokens for the session signed in now and `workspace`.
    func activityNotificationChannel(workspace: Workspace, environment: PushEnvironment, bundleID: String,
                                     locale: String) throws -> any ActivityNotificationTransport {
        guard let session else { throw CoreError(code: "signed_out", message: "No one is signed in.") }
        let id = session.id
        return CoreActivityNotificationChannel(core: core, sessionID: id, accountID: session.user.id, workspace: workspace,
                                               environment: environment, bundleID: bundleID, locale: locale) { [weak self] in
            await MainActor.run { self?.session?.id == id }
        }
    }
}
