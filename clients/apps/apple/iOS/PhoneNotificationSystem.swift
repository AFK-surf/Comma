import UIKit
import UserNotifications
import CommaCore

/// UIKit/UN adapter only. Consent and server eligibility belong to the shared controller.
@MainActor
final class PhoneNotificationSystem: TaskNotificationSystem {
    private var token: String?
    private var waiters: [UUID: CheckedContinuation<String, any Error>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private let acquisitionTimeout: Duration
    private let acquire: @MainActor () -> Void
    init(acquisitionTimeout: Duration = .seconds(15), acquire: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() }) {
        self.acquisitionTimeout = acquisitionTimeout; self.acquire = acquire
    }

    static func permission(_ settings: UNNotificationSettings) -> TaskNotificationPermission {
        permission(authorization: settings.authorizationStatus, alert: settings.alertSetting,
                   lockScreen: settings.lockScreenSetting, center: settings.notificationCenterSetting)
    }
    static func permission(authorization status: UNAuthorizationStatus, alert: UNNotificationSetting,
                           lockScreen: UNNotificationSetting, center: UNNotificationSetting) -> TaskNotificationPermission {
        let authorization: TaskNotificationPermission.Authorization
        switch status {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        case .authorized, .provisional, .ephemeral: authorization = .allowed
        @unknown default: authorization = .denied
        }
        let centerOnly = center == .enabled && alert == .disabled && lockScreen == .disabled
        let quiet = status == .provisional || status == .ephemeral || centerOnly
        return TaskNotificationPermission(authorization: authorization, quiet: quiet)
    }
    func settings() async -> TaskNotificationPermission {
        Self.permission(await UNUserNotificationCenter.current().notificationSettings())
    }
    func requestAuthorization() async throws -> TaskNotificationPermission {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await settings()
    }
    func deviceToken() async throws -> String {
        if let token { return token }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
            timeouts[id] = Task { [weak self, acquisitionTimeout] in
                do { try await Task.sleep(for: acquisitionTimeout) } catch { return }
                self?.finish(id, result: .failure(CommaError.transport))
            }
            acquire()
        }
    }
    func received(_ data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        for id in Array(waiters.keys) { finish(id, result: .success(token!)) }
    }
    func failed() {
        for id in Array(waiters.keys) { finish(id, result: .failure(CommaError.transport)) }
    }
    private func finish(_ id: UUID, result: Result<String, any Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        waiters.removeValue(forKey: id)?.resume(with: result)
    }
}
