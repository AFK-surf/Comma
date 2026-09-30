import AppKit
import Foundation

/// On-disk snapshot of which apps were visible before a foreground
/// session called `--apps` isolation. Lives at
/// `$TMPDIR/computerusenext/workspace-snapshot.json` so both the CLI and
/// the daemon can read/write it.
public struct AppIsolationSnapshot: Codable, Sendable {
    public var visibleBundleIDs: [String]
    public var matchedNames: [String]
    public var savedAt: Date

    public init(
        visibleBundleIDs: [String],
        matchedNames: [String],
        savedAt: Date = Date()
    ) {
        self.visibleBundleIDs = visibleBundleIDs
        self.matchedNames = matchedNames
        self.savedAt = savedAt
    }
}

/// CLI-callable orphan-recovery for the foreground app-isolation
/// snapshot. The daemon writes the snapshot on `start --mode foreground
/// <apps…>` and removes it on `stop`. If the daemon crashes or is
/// `kill -9`'d while a session is active, the snapshot stays on disk
/// and the user's hidden apps stay hidden until they run
/// `computeruse recover`.
public enum AppIsolationRecovery {
    public static var snapshotURL: URL {
        DaemonPaths.runtimeDirectory.appendingPathComponent("workspace-snapshot.json")
    }

    public static func hasSnapshot() -> Bool {
        FileManager.default.fileExists(atPath: snapshotURL.path)
    }

    public static func loadSnapshot() throws -> AppIsolationSnapshot {
        let data = try Data(contentsOf: snapshotURL)
        return try JSONDecoder().decode(AppIsolationSnapshot.self, from: data)
    }

    public static func writeSnapshot(_ snapshot: AppIsolationSnapshot) throws {
        try DaemonPaths.ensureRuntimeDirectory()
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }

    public static func discardSnapshot() {
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    /// Unhide every app that was visible before isolation, then remove
    /// the snapshot. Returns a human-readable summary for the CLI.
    @MainActor
    public static func applyRecovery() -> String {
        guard hasSnapshot() else {
            return "no orphan snapshot present"
        }
        let snapshot: AppIsolationSnapshot
        do {
            snapshot = try loadSnapshot()
        } catch {
            return "failed to read snapshot: \(error). Use `recover --discard` to delete it."
        }

        let visible = Set(snapshot.visibleBundleIDs)
        var unhidden: [String] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard
                let bundleID = app.bundleIdentifier,
                visible.contains(bundleID)
            else { continue }
            if app.isHidden {
                app.unhide()
                if let name = app.localizedName { unhidden.append(name) }
            }
        }
        discardSnapshot()
        if unhidden.isEmpty {
            return "snapshot consumed; no apps needed to be unhidden"
        }
        return "restored visibility for: \(unhidden.joined(separator: ", "))"
    }
}
