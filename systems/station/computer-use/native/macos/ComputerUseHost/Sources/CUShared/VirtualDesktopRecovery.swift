import AppKit
import ApplicationServices
import Foundation

/// Persisted record of a window moved onto the agent's virtual desktop so
/// `deactivate()` (and crash recovery) can place it back on the user's display.
public struct MigratedWindowRecord: Codable, Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String?
    public var appName: String
    public var windowID: UInt32
    public var windowTitle: String?
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double

    public init(
        pid: Int32,
        bundleID: String?,
        appName: String,
        windowID: UInt32,
        windowTitle: String?,
        originX: Double,
        originY: Double,
        width: Double,
        height: Double
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    public var originalFrame: CGRect {
        CGRect(x: originX, y: originY, width: width, height: height)
    }
}

/// On-disk snapshot of windows moved onto the virtual desktop during an active
/// session. Lives in `DaemonPaths.runtimeDirectory/virtual-desktop-snapshot.json`.
public struct VirtualDesktopSnapshot: Codable, Sendable, Equatable {
    public var virtualDisplayID: UInt32
    public var windows: [MigratedWindowRecord]
    public var savedAt: Date

    public init(
        virtualDisplayID: UInt32,
        windows: [MigratedWindowRecord],
        savedAt: Date = Date()
    ) {
        self.virtualDisplayID = virtualDisplayID
        self.windows = windows
        self.savedAt = savedAt
    }
}

/// Crash-safe persistence & recovery for windows relocated to the virtual
/// desktop. If the daemon is `kill -9`'d mid-session, any subsequent startup
/// or `recover` call restores those windows back to their original frames.
public enum VirtualDesktopRecovery {
    public static var snapshotURL: URL {
        DaemonPaths.runtimeDirectory.appendingPathComponent("virtual-desktop-snapshot.json")
    }

    public static func hasSnapshot(at url: URL = snapshotURL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public static func loadSnapshot(from url: URL = snapshotURL) throws -> VirtualDesktopSnapshot {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VirtualDesktopSnapshot.self, from: data)
    }

    public static func writeSnapshot(_ snapshot: VirtualDesktopSnapshot, to url: URL = snapshotURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public static func discardSnapshot(at url: URL = snapshotURL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Restore any windows saved in an orphan snapshot back to their recorded
    /// Quartz screen positions and discard the snapshot file.
    @MainActor
    @discardableResult
    public static func applyRecovery(from url: URL = snapshotURL) -> String {
        guard hasSnapshot(at: url) else {
            return "no virtual desktop snapshot present"
        }
        let snapshot: VirtualDesktopSnapshot
        do {
            snapshot = try loadSnapshot(from: url)
        } catch {
            discardSnapshot(at: url)
            return "discarded unreadable virtual desktop snapshot: \(error)"
        }

        let restoredCount = restoreWindows(snapshot.windows)
        discardSnapshot(at: url)
        return "restored \(restoredCount) window(s) from virtual desktop"
    }

    private typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let axGetWindow: AXUIElementGetWindowFn? = {
        _ = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_LAZY
        )
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(sym, to: AXUIElementGetWindowFn.self)
    }()

    private static func cgWindowID(of element: AXUIElement) -> CGWindowID? {
        guard let axGetWindow else { return nil }
        var windowID: CGWindowID = 0
        guard axGetWindow(element, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    @MainActor
    @discardableResult
    public static func restoreWindows(_ records: [MigratedWindowRecord]) -> Int {
        guard !records.isEmpty else { return 0 }
        var restored = 0
        var matchedIndicesByPID: [Int32: Set<Int>] = [:]
        for record in records {
            guard let app = NSRunningApplication(processIdentifier: record.pid) else { continue }
            if let expectedBundle = record.bundleID, !expectedBundle.isEmpty,
               app.bundleIdentifier != expectedBundle
            {
                continue
            }
            let appElement = AXUIElementCreateApplication(record.pid)
            var windowsValue: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                let axWindows = windowsValue as? [AXUIElement],
                !axWindows.isEmpty
            else { continue }

            let used = matchedIndicesByPID[record.pid, default: []]
            let candidates = axWindows.enumerated().filter { !used.contains($0.offset) }

            let matchedPair: (offset: Int, element: AXUIElement)?
            if record.windowID != 0, axGetWindow != nil {
                // If we have an exact windowID and the original window is gone (closed),
                // skip rather than relocating a different window of the same app.
                matchedPair = candidates.first { cgWindowID(of: $0.element) == record.windowID }
            } else {
                matchedPair = candidates.first { _, win in
                    guard let expectedTitle = record.windowTitle, !expectedTitle.isEmpty else { return false }
                    var titleRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
                       let title = titleRef as? String
                    {
                        return title == expectedTitle
                    }
                    return false
                } ?? candidates.first
            }

            guard let matchedPair else { continue }
            matchedIndicesByPID[record.pid, default: []].insert(matchedPair.offset)
            let targetWindow = matchedPair.element

            var origin = CGPoint(x: record.originX, y: record.originY)
            var size = CGSize(width: record.width, height: record.height)
            if let posVal = AXValueCreate(.cgPoint, &origin) {
                _ = AXUIElementSetAttributeValue(targetWindow, kAXPositionAttribute as CFString, posVal)
            }
            if size.width > 50, size.height > 50, let sizeVal = AXValueCreate(.cgSize, &size) {
                _ = AXUIElementSetAttributeValue(targetWindow, kAXSizeAttribute as CFString, sizeVal)
            }
            restored += 1
        }
        return restored
    }
}
