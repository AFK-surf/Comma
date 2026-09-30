import AppKit
import CUShared
import Foundation

/// Foreground-mode "focus this app, hide everything else" helper, ported
/// from legacy ComputerUse's `WindowManager.isolateWorkspace` /
/// `restoreWorkspace`. Uses `AppIsolationRecovery` to persist a snapshot of
/// which regular apps were visible at start time, so a crash or kill -9
/// leaves enough breadcrumbs for `ComputerUse recover` to un-hide them.
@MainActor
enum AppWorkspaceIsolation {
    /// Hide every `activationPolicy == .regular` app whose name/bundle
    /// isn't in `requestedApps`. Writes an `AppIsolationSnapshot` so a
    /// crashed session can be recovered. Best-effort: missing apps are
    /// silently skipped (the agent can still ask to focus them later).
    ///
    /// - Returns: the matched app's localized names (for logging). Empty
    ///   when `requestedApps.isEmpty`.
    @discardableResult
    static func isolate(apps requestedApps: [String]) -> [String] {
        guard !requestedApps.isEmpty else { return [] }

        let runningApps = regularRunningApps()
        var matchedApps: [NSRunningApplication] = []
        for name in requestedApps {
            if let app = findApp(name: name, in: runningApps) {
                matchedApps.append(app)
            }
        }
        guard !matchedApps.isEmpty else { return [] }

        // Snapshot what's visible right now so `restore()` (and the CLI's
        // orphan-recovery path) can un-hide them later.
        let visibleBundleIDs = runningApps
            .filter { !$0.isHidden }
            .compactMap(\.bundleIdentifier)
        let snapshot = AppIsolationSnapshot(
            visibleBundleIDs: visibleBundleIDs,
            matchedNames: matchedApps.compactMap(\.localizedName)
        )
        try? AppIsolationRecovery.writeSnapshot(snapshot)

        let keepPIDs = Set(matchedApps.map(\.processIdentifier))
        for app in runningApps where !keepPIDs.contains(app.processIdentifier) {
            if !app.isHidden {
                app.hide()
            }
        }

        if let first = matchedApps.first {
            first.activate(options: [.activateAllWindows])
        }

        return matchedApps.compactMap(\.localizedName)
    }

    /// Undo the most recent `isolate(apps:)`. Unhides every app captured
    /// in the snapshot (if one exists), then removes the snapshot file.
    static func restore() {
        guard AppIsolationRecovery.hasSnapshot() else { return }
        let snapshot: AppIsolationSnapshot
        do {
            snapshot = try AppIsolationRecovery.loadSnapshot()
        } catch {
            AppIsolationRecovery.discardSnapshot()
            return
        }

        let visible = Set(snapshot.visibleBundleIDs)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, visible.contains(bundleID) else { continue }
            if app.isHidden {
                app.unhide()
            }
        }
        AppIsolationRecovery.discardSnapshot()
    }

    // MARK: - Matching helpers (mirrors legacy WindowManager.findApp)

    private static func regularRunningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    private static func findApp(name: String, in apps: [NSRunningApplication]) -> NSRunningApplication? {
        let needle = name.trimmingCharacters(in: .whitespaces)
        let lowered = needle.lowercased()

        // 1. Exact localized name ("Safari" → "Safari").
        if let app = apps.first(where: { $0.localizedName == needle }) {
            return app
        }
        // 2. Case-insensitive localized name.
        if let app = apps.first(where: { $0.localizedName?.lowercased() == lowered }) {
            return app
        }
        // 3. Exact bundle last-segment ("Safari" → "com.apple.Safari").
        if let app = apps.first(where: {
            guard let bid = $0.bundleIdentifier else { return false }
            return bid.split(separator: ".").last.map(String.init) == needle
        }) {
            return app
        }
        // 4. Full bundle identifier ("com.apple.Safari" → "com.apple.Safari").
        if let app = apps.first(where: { $0.bundleIdentifier?.lowercased() == lowered }) {
            return app
        }
        // 5. Substring fallback. Needed for names the agent commonly uses
        //    that don't exactly match the localized app name — e.g.,
        //    "Settings" vs "System Settings", "Preferences" vs
        //    "com.apple.systempreferences". Only accept if exactly one
        //    regular app contains the token, to avoid ambiguous matches.
        guard lowered.count >= 3 else { return nil }
        let candidates = apps.filter { app in
            (app.localizedName?.lowercased().contains(lowered) ?? false)
                || (app.bundleIdentifier?.lowercased().contains(lowered) ?? false)
        }
        return candidates.count == 1 ? candidates.first : nil
    }
}
