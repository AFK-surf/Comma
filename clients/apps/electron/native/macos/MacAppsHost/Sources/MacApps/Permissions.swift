import AppKit
import Contacts
import CoreGraphics
import CoreServices
import EventKit
import Foundation

/// Reads and requests macOS privacy permissions. `status` never prompts and never
/// launches an app; only `request` may show a system prompt, and only Comma's
/// Main asks for it, when the user turns an app on.
public protocol PermissionAuthority: Sendable {
    func status(_ requirement: Requirement) async -> PermissionState
    func request(_ requirement: Requirement) async -> PermissionState
}

/// What each app needs. `onEnable` requirements are requested when the user turns the
/// app on; the others are reported, because macOS has no prompt for them or the app
/// works without them.
public struct AppRequirement: Sendable {
    public let requirement: Requirement
    public let onEnable: Bool
    /// Empty when every tool of the app needs it.
    public let tools: [String]
}

public enum AppRequirements {
    public static func of(_ app: MacApp) -> [AppRequirement] {
        switch app {
        case .calendar:
            [AppRequirement(requirement: .calendars, onEnable: true, tools: [])]
        case .reminders:
            [AppRequirement(requirement: .reminders, onEnable: true, tools: [])]
        case .contacts:
            [AppRequirement(requirement: .contacts, onEnable: true, tools: [])]
        case .messages:
            [AppRequirement(requirement: .automation(BundleID.messages), onEnable: true, tools: [])]
        case .mail:
            [AppRequirement(requirement: .automation(BundleID.mail), onEnable: true, tools: [])]
        case .notes:
            [AppRequirement(requirement: .automation(BundleID.notes), onEnable: true, tools: [])]
        case .music:
            [AppRequirement(requirement: .automation(BundleID.music), onEnable: true, tools: [])]
        case .maps:
            []
        case .system:
            [
                AppRequirement(
                    requirement: .automation(BundleID.systemEvents), onEnable: true,
                    tools: ["system_set_appearance"])
            ]
        case .vision:
            [
                AppRequirement(
                    requirement: .screenRecording, onEnable: true,
                    tools: ["vision_recognize_screen_text"])
            ]
        }
    }
}

/// Keeps one EventKit store, replaced when the authorization changes: a store
/// made before access was granted keeps answering as if it had none.
final class EventStoreBox: @unchecked Sendable {
    private let lock = NSLock()
    private var store: EKEventStore?
    private var madeWith: [EKAuthorizationStatus] = []

    func current() -> EKEventStore {
        lock.lock()
        defer { lock.unlock() }
        let now = [EKEventStore.authorizationStatus(for: .event), EKEventStore.authorizationStatus(for: .reminder)]
        if let store, madeWith == now { return store }
        let fresh = EKEventStore()
        store = fresh
        madeWith = now
        return fresh
    }
}

public final class SystemPermissions: PermissionAuthority, @unchecked Sendable {
    let events: EventStoreBox

    init(events: EventStoreBox) {
        self.events = events
    }

    public func status(_ requirement: Requirement) async -> PermissionState {
        switch requirement {
        case .calendars:
            Self.state(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            Self.state(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            Self.state(CNContactStore.authorizationStatus(for: .contacts))
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case let .automation(bundleID):
            TargetApp.isRunning(bundleID) ? Automation.state(bundleID, ask: false) : .unknown
        }
    }

    public func request(_ requirement: Requirement) async -> PermissionState {
        switch requirement {
        case .calendars:
            _ = try? await events.current().requestFullAccessToEvents()
        case .reminders:
            _ = try? await events.current().requestFullAccessToReminders()
        case .contacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .screenRecording:
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            // macOS also asks once whether Comma may capture the screen without its
            // window picker; one capture now puts that question here, not in a tool call.
            if CGPreflightScreenCaptureAccess() { _ = try? await ScreenPicture.mainDisplay() }
        case let .automation(bundleID):
            let wasRunning = TargetApp.isRunning(bundleID)
            guard (try? await TargetApp.launch(bundleID)) != nil else { return .unavailable }
            let state = await Task.detached { Automation.state(bundleID, ask: true) }.value
            // An app opened only to ask is closed again.
            if !wasRunning { TargetApp.quit(bundleID) }
            return state
        }
        return await status(requirement)
    }

    static func state(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .fullAccess, .authorized: .granted
        // Write-only access cannot read; asking for full access again upgrades it.
        case .writeOnly, .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    static func state(_ status: CNAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        // .authorized, and .limited where it exists: the permitted contacts can be read.
        default: .granted
        }
    }
}

enum Automation {
    private static let wildcard: FourCharCode = 0x2A2A_2A2A  // '****'
    private static let wouldRequireConsent: OSStatus = -1744  // errAEEventWouldRequireUserConsent

    /// Asks macOS whether Comma may send Apple Events to the app. With `ask`, macOS
    /// may show its Automation prompt and this blocks until the user answers.
    static func state(_ bundleID: String, ask: Bool) -> PermissionState {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(address, wildcard, wildcard, ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case wouldRequireConsent: return .notDetermined
        default: return .unknown  // procNotFound: the app is not running
        }
    }
}

enum TargetApp {
    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func quit(_ bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
    }

    /// Opens the app in the background and waits until it answers Apple Events.
    static func launch(_ bundleID: String) async throws {
        if isRunning(bundleID), Automation.state(bundleID, ask: false) != .unknown { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw ToolFailure("app_unavailable", "The app \(bundleID) is not installed on this Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<50 {
            if Automation.state(bundleID, ask: false) != .unknown { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ToolFailure("app_unavailable", "The app \(bundleID) did not start in time.")
    }
}
