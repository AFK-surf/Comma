import AppKit
import ApplicationServices
import CryptoKit
import CUShared
import Foundation

public struct ComputerUseSnapshotMetadata: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var appName: String
    public var bundleID: String
    public var pid: pid_t
    public var windowTitle: String
    public var windowID: Int
    public var windowFrame: CGRectCodable
    public var screenshotPath: String?
    public var screenshotSize: CGSizeCodable?
    public var fingerprint: String
    /// One entry per flattened AX node at capture time, aligned with the
    /// public `--element-index`. Used to re-locate the element in a fresh
    /// tree via parent-chain matching when an action runs later.
    public var nodeSignatures: [CachedNodeSignature]

    public init(
        id: String,
        createdAt: Date,
        appName: String,
        bundleID: String,
        pid: pid_t,
        windowTitle: String,
        windowID: Int,
        windowFrame: CGRectCodable,
        screenshotPath: String?,
        screenshotSize: CGSizeCodable?,
        fingerprint: String,
        nodeSignatures: [CachedNodeSignature]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.windowFrame = windowFrame
        self.screenshotPath = screenshotPath
        self.screenshotSize = screenshotSize
        self.fingerprint = fingerprint
        self.nodeSignatures = nodeSignatures
    }
}

/// Per-node identity captured at snapshot time. Stable-ish attributes the
/// resolver uses to re-locate the same element in a later, possibly-shifted
/// UI tree. `childIndexAmongSameRole` disambiguates siblings that share
/// role+subrole+title (e.g. unlabeled rows).
public struct CachedNodeSignature: Codable, Equatable, Sendable {
    public var depth: Int
    public var role: String
    public var subrole: String
    public var title: String
    public var identifier: String
    public var childIndexAmongSameRole: Int
}

public struct CGRectCodable: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct CGSizeCodable: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(_ size: CGSize) {
        width = size.width
        height = size.height
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

struct ComputerUseSnapshotFile: Codable {
    var metadata: ComputerUseSnapshotMetadata
}

public enum ComputerUseError: Error, CustomStringConvertible {
    case accessibilityPermissionDenied
    case appNotRunning(String)
    case windowNotFound(app: String, title: String?)
    case snapshotNotFound(String)
    case staleState(appName: String)
    case screenshotUnavailable(windowID: Int)
    case coordinateActionRequiresScreenshot
    case elementNotFound(Int)
    case elementFrameUnavailable(Int)
    case elementNotSettable(Int)
    case elementNotScrollable(Int)
    case focusedElementUnavailable
    case noEditableValue(Int)
    case secondaryActionNotFound(elementIndex: Int, action: String)
    case unsupportedKey(String)
    case invalidArgument(String)
    case cgWindowUnavailable(pid: pid_t, title: String)
    case snapshotStoreFailure(String)

    public var description: String {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required for this process"
        case let .appNotRunning(app):
            return "appNotRunning \(app)"
        case let .windowNotFound(app, title):
            if let title, title.isEmpty == false {
                return "windowNotFound app=\(app) title~\"\(title)\""
            }
            return "windowNotFound app=\(app)"
        case let .snapshotNotFound(id):
            return "snapshotNotFound \(id)"
        case let .staleState(appName):
            return "The user changed '\(appName)'. Re-query the latest state with `get-app-state` before sending more actions."
        case let .screenshotUnavailable(windowID):
            return "screenshotUnavailable windowID=\(windowID)"
        case .coordinateActionRequiresScreenshot:
            return "coordinateActionRequiresScreenshot"
        case let .elementNotFound(index):
            return "elementNotFound \(index)"
        case let .elementFrameUnavailable(index):
            return "elementFrameUnavailable \(index)"
        case let .elementNotSettable(index):
            return "elementNotSettable \(index)"
        case let .elementNotScrollable(index):
            return "elementNotScrollable \(index)"
        case .focusedElementUnavailable:
            return "focusedElementUnavailable"
        case let .noEditableValue(index):
            return "noEditableValue \(index)"
        case let .secondaryActionNotFound(elementIndex, action):
            return "secondaryActionNotFound element=\(elementIndex) action=\"\(action)\""
        case let .unsupportedKey(key):
            return "unsupportedKey \(key)"
        case let .invalidArgument(message):
            return "invalidArgument \(message)"
        case let .cgWindowUnavailable(pid, title):
            return "cgWindowUnavailable pid=\(pid) title=\"\(title)\""
        case let .snapshotStoreFailure(message):
            return "snapshotStoreFailure \(message)"
        }
    }
}

public struct RunningAppDescriptor: Equatable, Sendable {
    public var name: String
    public var bundleID: String
    public var pid: pid_t
    public var isActive: Bool

    public init(name: String, bundleID: String, pid: pid_t, isActive: Bool) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
        self.isActive = isActive
    }
}

public struct ComputerUseCommandOutput: Sendable {
    public var text: String
    public var metadata: ComputerUseSnapshotMetadata?

    public init(text: String, metadata: ComputerUseSnapshotMetadata? = nil) {
        self.text = text
        self.metadata = metadata
    }
}

struct CUWindowSnapshot {
    let windowID: Int
    let ownerName: String
    let name: String
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

struct RuntimeAXNode {
    let index: Int
    let depth: Int
    let element: AXUIElement
    let role: String
    let subrole: String
    let title: String
    let value: Any?
    let help: String
    let identifier: String
    let url: URL?
    let enabled: Bool?
    let selected: Bool?
    let expanded: Bool?
    let focused: Bool?
    let frame: CGRect?
    let actions: [String]
    let isValueSettable: Bool
    let valueTypeDescription: String?
}

struct RuntimeAppSnapshot {
    let app: NSRunningApplication
    let appElement: AXUIElement
    let windowElement: AXUIElement
    let windowID: Int
    let windowLayer: Int
    let windowTitle: String
    let windowFrame: CGRect
    let nodes: [RuntimeAXNode]
    let focusedElementIndex: Int?
    let selectedText: String?
    let screenshotURL: URL?
    let screenshotSize: CGSize?
    let fingerprint: String

    func node(index: Int) throws -> RuntimeAXNode {
        guard let node = nodes.first(where: { $0.index == index }) else {
            throw ComputerUseError.elementNotFound(index)
        }
        return node
    }
}

struct WindowSelection {
    var titleSubstring: String?
}

enum ComputerUseSnapshotStore {
    static var rootURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "computerusenext",
            isDirectory: true
        )
    }

    static func ensureRootDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    static func metadataURL(for snapshotID: String) -> URL {
        rootURL.appendingPathComponent("\(snapshotID).json")
    }

    static func screenshotURL(for snapshotID: String) -> URL {
        rootURL.appendingPathComponent("\(snapshotID).png")
    }

    static func save(snapshot: RuntimeAppSnapshot) throws -> ComputerUseSnapshotMetadata {
        try ensureRootDirectory()

        let snapshotID = UUID().uuidString.lowercased()
        let screenshotPath: String?
        let screenshotSize: CGSizeCodable?

        if let sourceScreenshotURL = snapshot.screenshotURL {
            let targetURL = screenshotURL(for: snapshotID)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: sourceScreenshotURL, to: targetURL)
            screenshotPath = targetURL.path
            screenshotSize = snapshot.screenshotSize.map(CGSizeCodable.init)
        } else {
            screenshotPath = nil
            screenshotSize = nil
        }

        let metadata = ComputerUseSnapshotMetadata(
            id: snapshotID,
            createdAt: Date(),
            appName: snapshot.app.localizedName ?? snapshot.app.bundleIdentifier ?? "Unknown",
            bundleID: snapshot.app.bundleIdentifier ?? "",
            pid: snapshot.app.processIdentifier,
            windowTitle: snapshot.windowTitle,
            windowID: snapshot.windowID,
            windowFrame: CGRectCodable(snapshot.windowFrame),
            screenshotPath: screenshotPath,
            screenshotSize: screenshotSize,
            fingerprint: snapshot.fingerprint,
            nodeSignatures: nodeSignatures(for: snapshot.nodes)
        )

        let data = try JSONEncoder.computerUse.encode(ComputerUseSnapshotFile(metadata: metadata))
        try data.write(to: metadataURL(for: snapshotID), options: .atomic)
        return metadata
    }

    static func load(snapshotID: String) throws -> ComputerUseSnapshotMetadata {
        let url = metadataURL(for: snapshotID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ComputerUseError.snapshotNotFound(snapshotID)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.computerUse.decode(ComputerUseSnapshotFile.self, from: data).metadata
    }
}

enum ComputerUseCore {
    static func listRunningApps() -> [RunningAppDescriptor] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy != .prohibited &&
                    (app.localizedName?.isEmpty == false || app.bundleIdentifier?.isEmpty == false)
            }
            .sorted { lhs, rhs in
                let lhsName = lhs.localizedName ?? lhs.bundleIdentifier ?? ""
                let rhsName = rhs.localizedName ?? rhs.bundleIdentifier ?? ""
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }
            .map { app in
                RunningAppDescriptor(
                    name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                    bundleID: app.bundleIdentifier ?? "",
                    pid: app.processIdentifier,
                    isActive: app.isActive
                )
            }
    }

    static func captureSnapshot(
        appIdentifier: String,
        selection: WindowSelection = .init(),
        includeScreenshot: Bool = true
    ) throws -> RuntimeAppSnapshot {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityPermissionDenied
        }

        let app = try resolveRunningApplication(matching: appIdentifier)
        return try captureSnapshot(
            app: app,
            selection: selection,
            includeScreenshot: includeScreenshot
        )
    }

    static func captureSnapshot(
        metadata: ComputerUseSnapshotMetadata,
        includeScreenshot: Bool
    ) throws -> RuntimeAppSnapshot {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityPermissionDenied
        }

        guard let app = resolveRunningApp(metadata: metadata) else {
            throw ComputerUseError.staleState(appName: metadata.appName)
        }

        return try captureSnapshot(
            app: app,
            selection: WindowSelection(titleSubstring: metadata.windowTitle),
            includeScreenshot: includeScreenshot,
            preferredWindowID: metadata.windowID,
            preferredWindowFrame: metadata.windowFrame.cgRect
        )
    }

    /// Look up the running app by bundleID + pid, falling back to pid-only if
    /// the metadata's bundleID is empty (unpackaged binaries have no bundle
    /// id, but we still identify them uniquely by pid).
    private static func resolveRunningApp(
        metadata: ComputerUseSnapshotMetadata
    ) -> NSRunningApplication? {
        if metadata.bundleID.isEmpty == false {
            if let match = NSRunningApplication.runningApplications(
                withBundleIdentifier: metadata.bundleID
            ).first(where: { $0.processIdentifier == metadata.pid }) {
                return match
            }
        }
        return NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier == metadata.pid
        })
    }

    static func formattedState(
        snapshot: RuntimeAppSnapshot,
        metadata: ComputerUseSnapshotMetadata
    ) -> ComputerUseCommandOutput {
        let stateDump = ComputerUseStateFormatter.format(snapshot: snapshot)
        var text = """
        Computer Use state (ComputerUseNext Snapshot: \(metadata.id))
        <app_state>
        \(stateDump)
        </app_state>
        """

        if let screenshotPath = metadata.screenshotPath {
            text += "\nScreenshot: \(screenshotPath)"
        }

        if let screenshotSize = metadata.screenshotSize {
            text += "\nScreenshotSize: \(Int(screenshotSize.width))x\(Int(screenshotSize.height))"
        }

        return ComputerUseCommandOutput(text: text, metadata: metadata)
    }

    /// Re-fetch the target window and its AX tree. Fails only when the window
    /// is actually gone (closed, app quit, different window surfaced).
    ///
    /// Frame drift is deliberately NOT treated as stale here: dynamic web
    /// content (Chrome PWAs like Telegram Web) regularly causes AX to report
    /// sub-pixel frame shifts that don't affect element resolution. Coordinate
    /// actions layer their own drift check on top via
    /// `ensureStableFrameForCoordinateAction`.
    static func validateSnapshot(_ metadata: ComputerUseSnapshotMetadata) throws -> RuntimeAppSnapshot {
        do {
            return try captureSnapshot(metadata: metadata, includeScreenshot: false)
        } catch {
            throw ComputerUseError.staleState(appName: metadata.appName)
        }
    }

    /// Tolerance for coordinate actions: Chrome PWAs frequently report AX
    /// frames that shift by 1–4 px between successive reads during message
    /// rendering / composer height changes. 2 px was too tight; 8 px is still
    /// well below a clickable-target size.
    private static let coordinateFrameTolerance: CGFloat = 8

    /// Guard that coordinate-addressed actions (click --x/--y, drag) should
    /// call before translating screenshot pixels to a click point. Element-
    /// index actions don't care about frame drift.
    static func ensureStableFrameForCoordinateAction(
        metadata: ComputerUseSnapshotMetadata,
        fresh: RuntimeAppSnapshot
    ) throws {
        guard nearlyEqualRects(
            fresh.windowFrame,
            metadata.windowFrame.cgRect,
            tolerance: coordinateFrameTolerance
        ) else {
            throw ComputerUseError.staleState(appName: metadata.appName)
        }
    }

    /// Re-locate the element the caller addressed with `--element-index N`
    /// against the fresh tree. The cached signatures + parent-chain walk
    /// tolerate small UI reshuffles (row insertions, same-name siblings
    /// reordering) but reject if the target clearly no longer exists.
    static func resolveCachedElement(
        cachedIndex: Int,
        metadata: ComputerUseSnapshotMetadata,
        fresh: RuntimeAppSnapshot
    ) throws -> RuntimeAXNode {
        guard let freshIndex = resolveFreshElementIndex(
            cachedIndex: cachedIndex,
            cached: metadata.nodeSignatures,
            fresh: fresh.nodes
        ) else {
            throw ComputerUseError.staleState(appName: metadata.appName)
        }
        return try fresh.node(index: freshIndex)
    }

    static func persistAndFormat(snapshot: RuntimeAppSnapshot) throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.save(snapshot: snapshot)
        return formattedState(snapshot: snapshot, metadata: metadata)
    }

    static func captureSettledSnapshot(
        afterActionOn snapshot: RuntimeAppSnapshot,
        includeScreenshot: Bool
    ) throws -> RuntimeAppSnapshot {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityPermissionDenied
        }

        let deadline = ProcessInfo.processInfo.systemUptime + ComputerUseActionSettleTiming.timeout
        let requiredStablePasses = ComputerUseActionSettleTiming.requiredStablePasses
        var lastFingerprint: String?
        var stablePasses = 0
        var latestSnapshot: RuntimeAppSnapshot?

        while true {
            let candidate = try captureSnapshot(
                app: snapshot.app,
                selection: WindowSelection(titleSubstring: snapshot.windowTitle),
                includeScreenshot: false,
                preferredWindowID: snapshot.windowID
            )
            latestSnapshot = candidate

            if candidate.fingerprint == lastFingerprint {
                stablePasses += 1
            } else {
                lastFingerprint = candidate.fingerprint
                stablePasses = 1
            }

            if stablePasses >= requiredStablePasses {
                break
            }

            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                break
            }

            ActionOverlayRuntime.pump(
                for: min(ComputerUseActionSettleTiming.pollInterval, remaining)
            )
        }

        guard let latestSnapshot else {
            throw ComputerUseError.windowNotFound(
                app: snapshot.app.localizedName ?? snapshot.app.bundleIdentifier ?? "Unknown",
                title: snapshot.windowTitle
            )
        }

        guard includeScreenshot else {
            return latestSnapshot
        }

        return try captureSnapshot(
            app: latestSnapshot.app,
            selection: WindowSelection(titleSubstring: latestSnapshot.windowTitle),
            includeScreenshot: true,
            preferredWindowID: latestSnapshot.windowID
        )
    }

    private static func captureSnapshot(
        app: NSRunningApplication,
        selection: WindowSelection,
        includeScreenshot: Bool,
        preferredWindowID: Int? = nil,
        preferredWindowFrame: CGRect? = nil
    ) throws -> RuntimeAppSnapshot {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        ChromiumAccessibilityActivation.shared.activateIfNeeded(
            pid: app.processIdentifier,
            root: appElement
        )
        let windowMatch = try resolveWindow(
            in: appElement,
            app: app,
            titleSubstring: selection.titleSubstring,
            preferredWindowID: preferredWindowID,
            preferredWindowFrame: preferredWindowFrame
        )

        let focusedElement = cuAttribute(
            appElement,
            name: kAXFocusedUIElementAttribute as String
        ) as AXUIElement?

        let nodes = flattenTree(
            from: windowMatch.element,
            focusedElement: focusedElement
        )

        let focusedIndex = focusedElement.flatMap { focused in
            nodes.first(where: { CFEqual($0.element, focused) })?.index
        }

        let selectedText = focusedElement.flatMap {
            cuAttribute($0, name: kAXSelectedTextAttribute as String) as String?
        }

        let screenshotCapture = includeScreenshot
            ? BackgroundWindowCapture.captureWindowScreenshot(windowID: windowMatch.cgWindow.windowID)
            : nil

        let fingerprint = fingerprint(
            app: app,
            windowID: windowMatch.cgWindow.windowID,
            windowTitle: windowMatch.title,
            windowFrame: windowMatch.frame,
            nodes: nodes,
            focusedElementIndex: focusedIndex,
            selectedText: selectedText
        )

        return RuntimeAppSnapshot(
            app: app,
            appElement: appElement,
            windowElement: windowMatch.element,
            windowID: windowMatch.cgWindow.windowID,
            windowLayer: windowMatch.cgWindow.layer,
            windowTitle: windowMatch.title,
            windowFrame: windowMatch.frame,
            nodes: nodes,
            focusedElementIndex: focusedIndex,
            selectedText: selectedText,
            screenshotURL: screenshotCapture?.url,
            screenshotSize: screenshotCapture?.size,
            fingerprint: fingerprint
        )
    }

    private static func resolveRunningApplication(matching identifier: String) throws -> NSRunningApplication {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }

        if let byBundleID = runningApps.first(where: { $0.bundleIdentifier == identifier }) {
            return byBundleID
        }

        if let byName = runningApps.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return byName
        }

        if let containsName = runningApps.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains(identifier)
        }) {
            return containsName
        }

        throw ComputerUseError.appNotRunning(identifier)
    }

    private static func resolveWindow(
        in appElement: AXUIElement,
        app: NSRunningApplication,
        titleSubstring: String?,
        preferredWindowID: Int?,
        preferredWindowFrame: CGRect? = nil
    ) throws -> (element: AXUIElement, title: String, frame: CGRect, cgWindow: CUWindowSnapshot) {
        let windows = mergeAXWindowCandidates(
            listedWindows: cuAttribute(appElement, name: kAXWindowsAttribute as String) as [AXUIElement]? ?? [],
            focusedWindow: cuAttribute(appElement, name: kAXFocusedWindowAttribute as String) as AXUIElement?,
            mainWindow: cuAttribute(appElement, name: kAXMainWindowAttribute as String) as AXUIElement?
        )
        let cgWindows = cuCGWindows(for: app.processIdentifier)

        var candidates: [(AXUIElement, String, CGRect, CUWindowSnapshot)] = []

        for window in windows {
            guard let frame = cuFrame(window) else {
                continue
            }

            let title = cuTitle(window)
            let matchingWindow = matchCGWindow(
                axWindow: window,
                candidates: cgWindows,
                preferredWindowID: preferredWindowID,
                title: title,
                frame: frame
            )

            guard let cgWindow = matchingWindow else {
                continue
            }

            candidates.append((window, title, frame, cgWindow))
        }

        if let preferredWindowID,
           let exact = candidates.first(where: { $0.3.windowID == preferredWindowID })
        {
            return exact
        }

        // Chrome/PWA rotates CG window IDs more aggressively than AX, so
        // preferredWindowID often misses. When the caller also supplies the
        // cached frame, prefer the candidate closest in size/position — this
        // reliably discriminates a 1044x737 main window from a 320x370
        // contextual popup that shares the same app.
        if let preferredWindowFrame,
           let best = bestCandidateByFrame(candidates, hint: preferredWindowFrame)
        {
            return best
        }

        let filtered: [(AXUIElement, String, CGRect, CUWindowSnapshot)] = if let titleSubstring, titleSubstring.isEmpty == false {
            candidates.filter { candidate in
                candidate.1.localizedCaseInsensitiveContains(titleSubstring)
            }
        } else {
            candidates
        }

        if let main = filtered.first(where: { cuBoolAttribute($0.0, name: kAXMainAttribute as String) == true }) {
            return main
        }

        if let focused = filtered.first(where: { cuBoolAttribute($0.0, name: kAXFocusedAttribute as String) == true }) {
            return focused
        }

        if let first = filtered.first {
            return first
        }

        throw ComputerUseError.windowNotFound(
            app: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
            title: titleSubstring
        )
    }

    /// Pick the candidate whose AX frame is closest (by center + size) to a
    /// hint frame. Returns nil if no candidate is within the max distance
    /// threshold, so a totally-off hint doesn't make us confidently pick
    /// a wrong window.
    private static func bestCandidateByFrame(
        _ candidates: [(AXUIElement, String, CGRect, CUWindowSnapshot)],
        hint: CGRect
    ) -> (AXUIElement, String, CGRect, CUWindowSnapshot)? {
        func score(_ frame: CGRect) -> CGFloat {
            let dx = frame.midX - hint.midX
            let dy = frame.midY - hint.midY
            let dw = frame.width - hint.width
            let dh = frame.height - hint.height
            return sqrt(dx * dx + dy * dy) + abs(dw) + abs(dh)
        }
        return candidates
            .map { ($0, score($0.2)) }
            .min(by: { $0.1 < $1.1 })?.0
    }

    private static func matchCGWindow(
        axWindow: AXUIElement,
        candidates: [CUWindowSnapshot],
        preferredWindowID: Int?,
        title: String,
        frame: CGRect
    ) -> CUWindowSnapshot? {
        if let exactWindowID = BackgroundSkyLight.cgWindowID(forAXWindow: axWindow),
           let exact = candidates.first(where: { $0.windowID == Int(exactWindowID) })
        {
            return exact
        }

        // Preferred-ID pairing is only safe when the CG frame matches the AX
        // window's frame. Otherwise, when an app (Chrome PWAs, Electron) has
        // multiple AX windows but only one surfaces via CG, every AX window
        // would pair with the same CG window — and downstream windowID-based
        // tie-breakers then pick whichever happens to be first in the list.
        if let preferredWindowID,
           let preferred = candidates.first(where: { $0.windowID == preferredWindowID }),
           nearlyEqualRects(preferred.bounds, frame, tolerance: 4)
        {
            return preferred
        }

        if title.isEmpty == false {
            let sameTitle = candidates.filter {
                $0.name.localizedCaseInsensitiveContains(title)
            }
            if let frameMatch = sameTitle.first(where: {
                nearlyEqualRects($0.bounds, frame)
            }) {
                return frameMatch
            }
            if let firstTitle = sameTitle.first {
                return firstTitle
            }
        }

        return candidates.first(where: { nearlyEqualRects($0.bounds, frame) }) ??
            candidates.first(where: { $0.layer == 0 })
    }

    private static func flattenTree(
        from root: AXUIElement,
        focusedElement: AXUIElement?
    ) -> [RuntimeAXNode] {
        var stack: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited = Set<ObjectIdentifier>()
        var nodes: [RuntimeAXNode] = []
        var nextIndex = 0

        while let current = stack.popLast() {
            let identifier = ObjectIdentifier(current.element as AnyObject)
            if visited.contains(identifier) {
                continue
            }
            visited.insert(identifier)

            let role = cuAttribute(current.element, name: kAXRoleAttribute as String) as String? ?? "AXUnknown"
            let subrole = cuAttribute(current.element, name: kAXSubroleAttribute as String) as String? ?? ""
            let value = cuRawAttribute(current.element, name: kAXValueAttribute as String)
            let node = RuntimeAXNode(
                index: nextIndex,
                depth: current.depth,
                element: current.element,
                role: role,
                subrole: subrole,
                title: cuTitle(current.element),
                value: value,
                help: cuAttribute(current.element, name: kAXHelpAttribute as String) as String? ?? "",
                identifier: cuAttribute(current.element, name: kAXIdentifierAttribute as String) as String? ?? "",
                url: cuAttribute(current.element, name: kAXURLAttribute as String) as URL?,
                enabled: cuBoolAttribute(current.element, name: kAXEnabledAttribute as String),
                selected: cuBoolAttribute(current.element, name: kAXSelectedAttribute as String),
                expanded: cuBoolAttribute(current.element, name: kAXExpandedAttribute as String),
                focused: focusedElement.map { CFEqual($0, current.element) },
                frame: cuFrame(current.element),
                actions: cuActions(current.element),
                isValueSettable: cuIsAttributeSettable(current.element, name: kAXValueAttribute as String),
                valueTypeDescription: describeValueType(value)
            )
            nodes.append(node)
            nextIndex += 1

            let children = cuAttribute(current.element, name: kAXChildrenAttribute as String) as [AXUIElement]? ?? []
            for child in children.reversed() {
                stack.append((child, current.depth + 1))
            }
        }

        return nodes
    }

    private static func fingerprint(
        app: NSRunningApplication,
        windowID: Int,
        windowTitle: String,
        windowFrame: CGRect,
        nodes: [RuntimeAXNode],
        focusedElementIndex: Int?,
        selectedText: String?
    ) -> String {
        let parts = nodes.map { node -> String in
            let components: [String] = [
                "\(node.index)",
                node.role,
                node.subrole,
                node.title,
                stableFingerprintValue(for: node),
                node.help,
                node.identifier,
                stableFingerprintURL(for: node),
                node.enabled.map(String.init) ?? "",
                node.selected.map(String.init) ?? "",
                node.expanded.map(String.init) ?? "",
                node.frame.map(stableRectString) ?? "",
                node.actions.joined(separator: ","),
            ]
            return components.joined(separator: "|")
        }

        let payload = """
        \(app.bundleIdentifier ?? "")
        |\(app.processIdentifier)
        |\(windowID)
        |\(windowTitle)
        |\(stableRectString(windowFrame))
        |focus=\(focusedElementIndex.map(String.init) ?? "")
        |selected=\(selectedText ?? "")
        |\(parts.joined(separator: "\n"))
        """

        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum ComputerUseActionSettleTiming {
    static var timeout: TimeInterval {
        milliseconds(from: "CUNEXT_ACTION_SETTLE_TIMEOUT_MS", fallback: 1600)
    }

    static var pollInterval: TimeInterval {
        milliseconds(from: "CUNEXT_ACTION_SETTLE_POLL_MS", fallback: 120)
    }

    static var requiredStablePasses: Int {
        guard
            let raw = ProcessInfo.processInfo.environment["CUNEXT_ACTION_SETTLE_STABLE_PASSES"],
            let value = Int(raw)
        else {
            return 3
        }

        return max(1, value)
    }

    private static func milliseconds(from key: String, fallback: Double) -> TimeInterval {
        guard
            let raw = ProcessInfo.processInfo.environment[key],
            let value = Double(raw),
            value >= 0
        else {
            return fallback / 1000
        }

        return value / 1000
    }
}

enum ComputerUseStateFormatter {
    static func format(snapshot: RuntimeAppSnapshot) -> String {
        let appName = snapshot.app.localizedName ?? snapshot.app.bundleIdentifier ?? "Unknown"
        let focusedLine = if let focusedIndex = snapshot.focusedElementIndex,
                             let focusedNode = try? snapshot.node(index: focusedIndex)
        {
            "\nThe focused UI element is \(focusedIndex) \(describeRole(focusedNode.role))."
        } else {
            ""
        }

        let selectedTextLine = if let selectedText = snapshot.selectedText, selectedText.isEmpty == false {
            """

            Selected text: ```
            \(selectedText)
            ```

            Note: Pay special attention to the content selected by the user. If the user asks a question or refers to the content they are looking at on-screen, they might be referring to the selected content (but they might be referring to something else that's visible, too).
            """
        } else {
            ""
        }

        let lines = snapshot.nodes.map(format(node:))
        return """
        App=\(snapshot.app.bundleIdentifier ?? appName) (pid \(snapshot.app.processIdentifier))
        Window: "\(snapshot.windowTitle)", App: \(appName).
        \(lines.joined(separator: "\n"))\(focusedLine)\(selectedTextLine)
        """
    }

    private static func format(node: RuntimeAXNode) -> String {
        let indent = String(repeating: "\t", count: node.depth)
        let stateDescription = describeStates(node)
        let suffixParts = describeDetails(node)
        let suffix = suffixParts.isEmpty ? "" : " " + suffixParts.joined(separator: ", ")
        return "\(indent)\(node.index) \(describeRole(node.role))\(stateDescription)\(suffix)"
    }

    private static func describeStates(_ node: RuntimeAXNode) -> String {
        var states: [String] = []

        if node.enabled == false {
            states.append("disabled")
        }
        if node.selected == true {
            states.append("selected")
        }
        if node.expanded == true {
            states.append("expanded")
        }
        if node.isValueSettable {
            states.append("settable")
        }
        if let valueTypeDescription = node.valueTypeDescription, node.isValueSettable {
            states.append(valueTypeDescription)
        }

        guard states.isEmpty == false else {
            return ""
        }
        return " (\(states.joined(separator: ", ")))"
    }

    private static func describeDetails(_ node: RuntimeAXNode) -> [String] {
        var details: [String] = []

        if node.title.isEmpty == false {
            details.append(node.title)
        }

        if node.identifier.isEmpty == false {
            details.append("ID: \(node.identifier)")
        }

        if node.help.isEmpty == false {
            details.append("Help: \(node.help)")
        }

        if let url = node.url {
            details.append("URL: \(url.absoluteString)")
        }

        let valueString = stringifyValue(node.value)
        if valueString.isEmpty == false,
           valueString != node.title
        {
            details.append("Value: \(valueString)")
        }

        let secondaryActions = node.actions
            .map(displayName(forAction:))
            .filter { $0.caseInsensitiveCompare("Press") != .orderedSame }

        if secondaryActions.isEmpty == false {
            details.append("Secondary Actions: \(secondaryActions.joined(separator: ", "))")
        }

        return details
    }
}

extension JSONEncoder {
    static var computerUse: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var computerUse: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

func displayName(forAction action: String) -> String {
    let trimmed = action.hasPrefix("AX") ? String(action.dropFirst(2)) : action
    let noByPage = trimmed.replacingOccurrences(of: "ByPage", with: "")
    return splitCamelCase(noByPage).joined(separator: " ")
}

func describeRole(_ role: String) -> String {
    if role == kAXWindowRole as String {
        return "standard window"
    }
    if role == kAXStaticTextRole as String {
        return "text"
    }
    return splitCamelCase(role.hasPrefix("AX") ? String(role.dropFirst(2)) : role)
        .joined(separator: " ")
        .lowercased()
}

func splitCamelCase(_ string: String) -> [String] {
    guard string.isEmpty == false else {
        return []
    }

    var words: [String] = []
    var current = ""

    for scalar in string.unicodeScalars {
        let character = Character(scalar)
        if current.isEmpty == false,
           CharacterSet.uppercaseLetters.contains(scalar)
        {
            words.append(current)
            current = String(character)
        } else {
            current.append(character)
        }
    }

    if current.isEmpty == false {
        words.append(current)
    }

    return words
}

func stringifyValue(_ value: Any?) -> String {
    guard let value else {
        return ""
    }

    if let string = value as? String {
        return string
    }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "1" : "0"
        }
        return number.stringValue
    }
    if let url = value as? URL {
        return url.absoluteString
    }
    let cfObject = value as AnyObject
    if CFGetTypeID(cfObject) == AXValueGetTypeID() {
        let axValue = value as! AXValue
        switch AXValueGetType(axValue) {
        case .cgPoint:
            var point = CGPoint.zero
            guard AXValueGetValue(axValue, .cgPoint, &point) else {
                return ""
            }
            return NSStringFromPoint(point)
        case .cgSize:
            var size = CGSize.zero
            guard AXValueGetValue(axValue, .cgSize, &size) else {
                return ""
            }
            return NSStringFromSize(size)
        case .cfRange:
            var range = CFRange()
            guard AXValueGetValue(axValue, .cfRange, &range) else {
                return ""
            }
            return "{\(range.location), \(range.length)}"
        default:
            return ""
        }
    }
    return String(describing: value)
}

func describeValueType(_ value: Any?) -> String? {
    guard let value else {
        return nil
    }
    if value is String {
        return "string"
    }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return "bool"
        }
        if CFNumberIsFloatType(number) {
            return "float"
        }
        return "int"
    }
    return nil
}

func stableRectString(_ rect: CGRect) -> String {
    "\(round(rect.origin.x * 100) / 100),\(round(rect.origin.y * 100) / 100),\(round(rect.width * 100) / 100),\(round(rect.height * 100) / 100)"
}

func stableFingerprintValue(for node: RuntimeAXNode) -> String {
    if node.role == kAXStaticTextRole as String {
        return ""
    }

    if node.isValueSettable {
        return stringifyValue(node.value)
    }

    switch node.role {
    case kAXCheckBoxRole as String,
         kAXRadioButtonRole as String,
         kAXSliderRole as String,
         kAXScrollBarRole as String:
        return stringifyValue(node.value)
    default:
        return ""
    }
}

func stableFingerprintURL(for node: RuntimeAXNode) -> String {
    guard node.role == kAXTextFieldRole as String else {
        return ""
    }
    return node.url?.absoluteString ?? ""
}

/// Parent index for each position in a depth-annotated DFS flatten.
/// Parent of node[i] is the most recent earlier node with depth == depth[i]-1.
func parentIndicesFromDepths(_ depths: [Int]) -> [Int?] {
    var parents: [Int?] = Array(repeating: nil, count: depths.count)
    var stack: [Int] = []
    for i in 0 ..< depths.count {
        while let top = stack.last, depths[top] >= depths[i] {
            stack.removeLast()
        }
        parents[i] = stack.last
        stack.append(i)
    }
    return parents
}

/// For each index i, the 0-based position of i among its siblings that share
/// the same role+subrole. Used to tie-break when multiple siblings have the
/// same title/identifier.
func childIndicesAmongSameRole(
    roles: [String],
    subroles: [String],
    parents: [Int?]
) -> [Int] {
    var counts: [Int: [String: Int]] = [:] // parentIndex → "role|subrole" → nextIndex
    var result: [Int] = Array(repeating: 0, count: roles.count)
    for i in 0 ..< roles.count {
        let parentKey = parents[i] ?? -1
        let bucketKey = "\(roles[i])|\(subroles[i])"
        let next = counts[parentKey, default: [:]][bucketKey, default: 0]
        result[i] = next
        counts[parentKey, default: [:]][bucketKey] = next + 1
    }
    return result
}

/// Build a signature for each node aligned with `nodes[i].index`.
func nodeSignatures(for nodes: [RuntimeAXNode]) -> [CachedNodeSignature] {
    let depths = nodes.map(\.depth)
    let roles = nodes.map(\.role)
    let subroles = nodes.map(\.subrole)
    let parents = parentIndicesFromDepths(depths)
    let childIndices = childIndicesAmongSameRole(
        roles: roles,
        subroles: subroles,
        parents: parents
    )
    return nodes.enumerated().map { i, node in
        CachedNodeSignature(
            depth: node.depth,
            role: node.role,
            subrole: node.subrole,
            title: node.title,
            identifier: node.identifier,
            childIndexAmongSameRole: childIndices[i]
        )
    }
}

/// Resolve the element index in `fresh` that best matches `cachedIndex`'s
/// parent chain in `cached`. Returns nil if no viable match exists, which
/// callers translate to staleState.
func resolveFreshElementIndex(
    cachedIndex: Int,
    cached: [CachedNodeSignature],
    fresh: [RuntimeAXNode]
) -> Int? {
    guard cachedIndex >= 0, cachedIndex < cached.count, !fresh.isEmpty else {
        return nil
    }

    let cachedParents = parentIndicesFromDepths(cached.map(\.depth))
    var path: [CachedNodeSignature] = []
    var cursor: Int? = cachedIndex
    while let c = cursor {
        path.append(cached[c])
        cursor = cachedParents[c]
    }
    path.reverse()

    let freshDepths = fresh.map(\.depth)
    let freshParents = parentIndicesFromDepths(freshDepths)
    let freshChildIndices = childIndicesAmongSameRole(
        roles: fresh.map(\.role),
        subroles: fresh.map(\.subrole),
        parents: freshParents
    )

    // Root is index 0 by construction of flattenTree. Verify root role still
    // matches — if the window root changed role entirely, the tree is alien.
    guard let rootStep = path.first, rootStep.role == fresh[0].role else {
        return nil
    }

    var freshCursor = 0
    for step in path.dropFirst() {
        let children = (0 ..< fresh.count).filter { freshParents[$0] == freshCursor }
        var bestScore = Int.min
        var best: Int?
        for child in children {
            let s = matchScore(
                candidate: fresh[child],
                childIndex: freshChildIndices[child],
                target: step
            )
            if s > bestScore {
                bestScore = s
                best = child
            }
        }
        guard let best, bestScore >= 0 else {
            return nil
        }
        freshCursor = best
    }
    return freshCursor
}

private func matchScore(
    candidate: RuntimeAXNode,
    childIndex: Int,
    target: CachedNodeSignature
) -> Int {
    guard candidate.role == target.role else { return Int.min }
    var score = 0

    if !target.subrole.isEmpty {
        if candidate.subrole == target.subrole { score += 2 }
        else if !candidate.subrole.isEmpty { score -= 2 }
    } else if !candidate.subrole.isEmpty {
        score -= 1
    }

    if !target.identifier.isEmpty {
        if candidate.identifier == target.identifier { score += 4 }
        else if !candidate.identifier.isEmpty { score -= 3 }
    }

    if !target.title.isEmpty {
        if candidate.title == target.title { score += 3 }
        else if !candidate.title.isEmpty { score -= 2 }
    }

    if childIndex == target.childIndexAmongSameRole { score += 1 }

    return score
}

func windowLocalPoint(
    fromScreenshotPixel point: CGPoint,
    screenshotSize: CGSize,
    windowFrame: CGRect
) -> CGPoint {
    windowLocalPoint(
        fromScreenshotPixel: Point<ScreenshotPixelSpace>(point),
        screenshotSize: screenshotSize,
        windowFrame: windowFrame
    ).cgPoint
}

func nearlyEqualRects(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 2) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance &&
        abs(lhs.height - rhs.height) <= tolerance
}

func cuRawAttribute(_ element: AXUIElement, name: String) -> Any? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard error == .success else {
        return nil
    }
    return value
}

func cuAttribute<T>(_ element: AXUIElement, name: String) -> T? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard error == .success else {
        return nil
    }
    return value as? T
}

func cuBoolAttribute(_ element: AXUIElement, name: String) -> Bool? {
    cuAttribute(element, name: name) as Bool?
}

func cuTitle(_ element: AXUIElement) -> String {
    cuAttribute(element, name: kAXTitleAttribute as String) as String? ?? ""
}

func cuActions(_ element: AXUIElement) -> [String] {
    var value: CFArray?
    let error = AXUIElementCopyActionNames(element, &value)
    guard error == .success else {
        return []
    }
    return value as? [String] ?? []
}

func cuFrame(_ element: AXUIElement) -> CGRect? {
    guard
        let positionValue = cuAttribute(element, name: kAXPositionAttribute as String) as AXValue?,
        let sizeValue = cuAttribute(element, name: kAXSizeAttribute as String) as AXValue?,
        let position = cuCGPoint(from: positionValue),
        let size = cuCGSize(from: sizeValue)
    else {
        return nil
    }

    return CGRect(origin: position, size: size)
}

func cuIsAttributeSettable(_ element: AXUIElement, name: String) -> Bool {
    var settable = DarwinBoolean(false)
    let error = AXUIElementIsAttributeSettable(
        element,
        name as CFString,
        &settable
    )
    return error == .success && settable.boolValue
}

func cuCGPoint(from value: AXValue) -> CGPoint? {
    guard AXValueGetType(value) == .cgPoint else {
        return nil
    }

    var point = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &point) ? point : nil
}

func cuCGSize(from value: AXValue) -> CGSize? {
    guard AXValueGetType(value) == .cgSize else {
        return nil
    }

    var size = CGSize.zero
    return AXValueGetValue(value, .cgSize, &size) ? size : nil
}

func cuRange(from value: AXValue) -> CFRange? {
    guard AXValueGetType(value) == .cfRange else {
        return nil
    }

    var range = CFRange()
    return AXValueGetValue(value, .cfRange, &range) ? range : nil
}

func cuCGWindows(for pid: pid_t) -> [CUWindowSnapshot] {
    guard
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
    else {
        return []
    }

    return info.compactMap { entry in
        guard
            let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
            ownerPID == Int(pid),
            let windowID = entry[kCGWindowNumber as String] as? Int,
            let layer = entry[kCGWindowLayer as String] as? Int
        else {
            return nil
        }

        let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
        let name = entry[kCGWindowName as String] as? String ?? ""
        let alpha = entry[kCGWindowAlpha as String] as? Double ?? -1
        let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .null

        return CUWindowSnapshot(
            windowID: windowID,
            ownerName: ownerName,
            name: name,
            layer: layer,
            alpha: alpha,
            bounds: bounds
        )
    }
}

func mergeAXWindowCandidates(
    listedWindows: [AXUIElement],
    focusedWindow: AXUIElement?,
    mainWindow: AXUIElement?
) -> [AXUIElement] {
    var merged: [AXUIElement] = []

    for candidate in listedWindows + [focusedWindow, mainWindow].compactMap(\.self) {
        if merged.contains(where: { CFEqual($0, candidate) }) {
            continue
        }
        merged.append(candidate)
    }

    return merged
}
