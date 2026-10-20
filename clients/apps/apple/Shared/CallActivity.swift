import ActivityKit
import AppIntents
import Foundation

/// The voice call on the Lock Screen and in the Dynamic Island. It carries no credential, transcript or audio.
struct CallActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable, Sendable { case calling, connected, ending, ended, failed }

    struct ContentState: Codable, Hashable, Sendable {
        var phase: Phase
        /// When the agent first spoke; the duration counts from here.
        var connectedAt: Date?
        /// When the call finished, so a finished card shows its final length instead of a running timer.
        var endedAt: Date?
        var muted: Bool
    }

    let accountID: String
    let workspaceID: String
}

/// The Live Activity's End button. ActivityKit runs a `LiveActivityIntent` in the app's own process,
/// where the call lives; the widget extension only draws the button.
struct EndCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End call"
    static let description = IntentDescription("Ends the current Comma voice call.")
    static let isDiscoverable = false

    /// Installed by the app at launch. Nil in the widget extension, which never performs the intent.
    @MainActor static var hangUp: (@MainActor () -> Void)?

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { Self.hangUp?() }
        return .result()
    }
}

struct ToggleCallMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute"
    static let isDiscoverable = false

    @MainActor static var toggleMute: (@MainActor @Sendable () async -> Void)?

    init() {}

    func perform() async throws -> some IntentResult {
        await Self.toggleMute?()
        return .result()
    }
}

enum CallDuration {
    /// `0:27`, `12:05`, `1:02:09`: minutes are not zero-padded.
    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
}
