import AppKit
import CoreGraphics

/// Foreground-mode helper with two narrow jobs, ported from legacy
/// ComputerUse's `AgentCursorOverlay.swift` but trimmed:
///
///   1. Hide the system mouse cursor while the agent is active, and
///      restore it on intervention / session end. Uses the SkyLight
///      `SetsCursorInBackground` + `CGDisplayHideCursor` trick so the
///      cursor stays hidden even though the daemon is `.accessory`.
///   2. During observe (user intervention) mode, paint a static pink
///      marker sprite at the paused screen point so the user sees
///      where to return their cursor for auto-recovery.
///
/// The "agent cursor" sprite itself lives in `CUShared.DaemonCursor`
/// now — it's the same bezier-animated, rotating ActionOverlay sprite
/// background mode uses. Driving one sprite instead of two avoids the
/// "two cursors appearing at the same time" artifact users complained
/// about previously.
@MainActor
final class AgentCursorOverlay: OverlayWindowSource {
    private enum PresentationMode {
        case hidden
        case following
        case marker(CGPoint)
    }

    private var markerWindow: NSWindow?
    private var markerImageView: NSImageView?
    private var systemCursorHidden = false
    private var backgroundCursorControlEnabled = false
    private var cursorHideDepth = 0
    private var presentationMode: PresentationMode = .hidden
    private var maintainTimer: Timer?
    /// Interval at which the watchdog checks whether macOS has sneaked
    /// the system cursor back (happens on app focus changes, dock
    /// interactions, fast-user-switch transitions, etc.) while we
    /// believe it should be hidden. 100ms matches legacy ComputerUse's
    /// CVDisplayLink-driven maintain loop closely enough.
    private let maintainInterval: TimeInterval = 0.1

    private let backgroundCursorControlKey = "SetsCursorInBackground" as CFString

    var overlayWindows: [NSWindow] {
        markerWindow.map { [$0] } ?? []
    }

    init() {
        OverlayWindowRegistry.shared.register(self)
    }

    /// Enter active presentation: hide system cursor. The visible agent
    /// cursor is driven by `DaemonCursor` externally.
    func activate() {
        presentationMode = .following
        enableBackgroundCursorControlIfNeeded()
        hideSystemCursorIfNeeded()
        startMaintainTimer()
        markerWindow?.orderOut(nil)
    }

    /// Switch to observe marker: paint the pink marker at `screenPoint`
    /// (Quartz coords, y-down) and restore the user's real cursor.
    func show(at screenPoint: CGPoint) {
        presentationMode = .marker(screenPoint)
        restoreSystemCursorIfNeeded()
        disableBackgroundCursorControlIfNeeded()
        // Keep the watchdog ticking through observe mode too — now it
        // enforces the *opposite* invariant: if macOS (or any rogue
        // CGDisplayHideCursor leaked from elsewhere) re-hides the
        // system cursor while we're supposed to be handing it back to
        // the user, force it visible again.
        startMaintainTimer()
        if markerWindow == nil {
            createMarkerWindow()
        }
        positionMarker(at: screenPoint)
        markerWindow?.orderFront(nil)
    }

    func deactivate() {
        presentationMode = .hidden
        stopMaintainTimer()
        markerWindow?.orderOut(nil)
        restoreSystemCursorIfNeeded()
        disableBackgroundCursorControlIfNeeded()
    }

    private func createMarkerWindow() {
        let size = ComputerUseCursor.canvasSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        let imageView = NSImageView(frame: container.bounds)
        imageView.image = ComputerUseCursor.markerImage
        imageView.imageScaling = .scaleNone
        container.addSubview(imageView)

        window.contentView = container
        markerWindow = window
        markerImageView = imageView
    }

    private func positionMarker(at screenPoint: CGPoint) {
        guard let window = markerWindow else { return }
        let frame = ComputerUseCursor.frame(
            for: screenPoint,
            desktopMaxY: DesktopCoordinateSpace.desktopMaxY()
        )
        if window.frame.size == frame.size {
            window.setFrameOrigin(frame.origin)
        } else {
            window.setFrame(frame, display: true)
        }
    }

    private func hideSystemCursorIfNeeded() {
        guard !systemCursorHidden else { return }
        requestCursorHidden()
        systemCursorHidden = true
    }

    private func restoreSystemCursorIfNeeded() {
        guard systemCursorHidden else { return }
        // Pair up every outstanding hide with an unhide so the nested
        // hide-counters on both `CGDisplay…Cursor` and `NSCursor` go back
        // to zero. An imbalance here is the classic "system cursor stays
        // hidden after the session ends" bug.
        for _ in 0 ..< cursorHideDepth {
            for displayID in activeDisplayIDs() {
                _ = CGDisplayShowCursor(displayID)
            }
            NSCursor.unhide()
        }
        cursorHideDepth = 0
        systemCursorHidden = false
        // Belt & braces: some CGEvent flows (notably in older legacy
        // paths that used `CGAssociateMouseAndMouseCursorPosition(false)`)
        // leave the system cursor dissociated from the physical device.
        // Re-associate unconditionally so the user's next mouse movement
        // actually drags the cursor around.
        _ = CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func requestCursorHidden() {
        let displayIDs = activeDisplayIDs()
        guard !displayIDs.isEmpty else { return }
        for displayID in displayIDs {
            _ = CGDisplayHideCursor(displayID)
        }
        NSCursor.hide()
        cursorHideDepth += 1
    }

    // MARK: - Maintain watchdog

    //
    // macOS re-shows the system cursor on a bunch of events we don't
    // get explicit callbacks for — app focus transitions, dock peek,
    // Mission Control, fast-user-switch, some CGEvent flows. Legacy
    // ComputerUse handled this inside its CVDisplayLink-driven cursor
    // follower; we no longer have that follower, so a small timer
    // polls `CGCursorIsVisible` instead and re-hides when it drifts.

    private func startMaintainTimer() {
        stopMaintainTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: maintainInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.maintainHiddenCursorIfNeeded()
            }
        }
        // `.common` so the timer still ticks while AppKit is spinning
        // its own inner loops (e.g., during `DaemonCursor` pump).
        RunLoop.main.add(timer, forMode: .common)
        maintainTimer = timer
    }

    private func stopMaintainTimer() {
        maintainTimer?.invalidate()
        maintainTimer = nil
    }

    private func maintainHiddenCursorIfNeeded() {
        switch presentationMode {
        case .hidden:
            // Not in a session — nothing to enforce. The timer should
            // already be stopped here; this branch is just belt &
            // braces against a stray tick between `deactivate()` and
            // `invalidate()`.
            return
        case .following:
            // We *want* the system cursor hidden. Re-hide if it drifted
            // visible (app focus change, Mission Control, fast user
            // switch, stray CGDisplayShowCursor from another app, …).
            guard LegacyCGCursorIsVisible() != 0 else { return }
            if !backgroundCursorControlEnabled {
                enableBackgroundCursorControlIfNeeded()
            }
            requestCursorHidden()
        case .marker:
            // We *want* the system cursor visible so the user can bring
            // it back to the marker. If something re-hid it (rogue
            // `CGDisplayHideCursor` from another app, stale NSCursor
            // counter, …), unhide until it's on-screen. Over-unhiding
            // is a no-op on macOS when the counter is already at zero,
            // so this is safe.
            guard LegacyCGCursorIsVisible() == 0 else { return }
            for displayID in activeDisplayIDs() {
                _ = CGDisplayShowCursor(displayID)
            }
            NSCursor.unhide()
            // If something re-enabled the SkyLight background-cursor
            // control (which lets another app's hide stick across
            // focus transitions), turn it back off so macOS's normal
            // cursor visibility logic resumes control.
            if backgroundCursorControlEnabled {
                disableBackgroundCursorControlIfNeeded()
            }
        }
    }

    private func enableBackgroundCursorControlIfNeeded() {
        guard !backgroundCursorControlEnabled else { return }
        backgroundCursorControlEnabled = setBackgroundCursorControl(enabled: true)
    }

    private func disableBackgroundCursorControlIfNeeded() {
        guard backgroundCursorControlEnabled else { return }
        _ = setBackgroundCursorControl(enabled: false)
        backgroundCursorControlEnabled = false
    }

    private func setBackgroundCursorControl(enabled: Bool) -> Bool {
        let connection = CGSMainConnectionID()
        let value = (enabled ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        let result = CGSSetConnectionProperty(connection, connection, backgroundCursorControlKey, value)
        return result == .success
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            let mainDisplayID = CGMainDisplayID()
            return mainDisplayID == 0 ? [] : [mainDisplayID]
        }
        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            let mainDisplayID = CGMainDisplayID()
            return mainDisplayID == 0 ? [] : [mainDisplayID]
        }
        return Array(displayIDs.prefix(Int(count)))
    }
}

private typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(
    _ connection: CGSConnectionID,
    _ targetConnection: CGSConnectionID,
    _ key: CFString,
    _ value: CFTypeRef
) -> CGError

@_silgen_name("CGCursorIsVisible")
private func LegacyCGCursorIsVisible() -> Int32
