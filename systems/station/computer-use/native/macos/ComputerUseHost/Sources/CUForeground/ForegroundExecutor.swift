import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CUShared
import Foundation

/// Executes a parsed `ForegroundCommand`. Mouse motion uses the shared
/// `DaemonCursor` bezier overlay — same rotating sprite the background
/// mode uses — so foreground clicks get a curved position-and-heading
/// animation instead of a straight-line warp. Before each action we
/// `syncPose(toScreenPoint: CGEvent.location)` so the bezier starts
/// from where the real (hidden) cursor is, then the `body` closure
/// fires the CGEvent at the target after the sprite lands.
/// `AgentCursorOverlay` now owns only system-cursor-hide + observe
/// marker; the agent-visible sprite is DaemonCursor.
@MainActor
public enum ForegroundExecutor {
    /// `presentation` is optional so this enum stays useful outside the
    /// daemon context (e.g., tests / CLI). When present, thinking commands
    /// route through the HUD controller instead of the deprecated
    /// `AgentHUD` singleton.
    static func execute(
        _ command: ForegroundCommand,
        presentation: AgentPresentationCoordinator? = nil
    ) async throws -> ForegroundCommandOutput {
        switch command {
        case let .click(x, y, button, count):
            try click(x: x, y: y, button: button, count: count)
            return .empty
        case let .mouseDown(x, y, button):
            try mouseButton(downAt: x, y: y, button: button)
            return .empty
        case let .mouseUp(x, y, button):
            try mouseButton(upAt: x, y: y, button: button)
            return .empty
        case let .mouseMove(x, y):
            try moveMouse(x: x, y: y)
            return .empty
        case let .drag(fromX, fromY, toX, toY, button):
            try drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY, button: button)
            return .empty
        case let .typeText(text):
            try typeText(text)
            return .empty
        case let .pressKey(combo):
            try pressKey(combo: combo)
            return .empty
        case let .holdKey(combo, seconds):
            try holdKey(combo: combo, seconds: seconds)
            return .empty
        case let .scroll(x, y, direction, amount):
            try scroll(x: x, y: y, direction: direction, amount: amount)
            return .empty
        case let .wait(seconds):
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return .empty
        case .screenshot:
            let capture = try await takeScreenshot()
            return try ForegroundCommandOutput(
                text: encodeImageResponse(url: capture.url, width: capture.width, height: capture.height)
            )
        case .screenSize:
            let size = primaryDisplayPixelSize()
            return ForegroundCommandOutput(text: "\(Int(size.width))x\(Int(size.height))")
        case .cursorPosition:
            let point = currentCursorPosition()
            return ForegroundCommandOutput(text: "\(Int(point.x)),\(Int(point.y))")
        case .listApplications:
            return ForegroundCommandOutput(text: listRunningApplications())
        case .listWindows:
            return ForegroundCommandOutput(text: listOnScreenWindows())
        case let .focus(app):
            return try ForegroundCommandOutput(text: focusApplication(named: app))
        case let .zoom(x1, y1, x2, y2):
            return try await captureZoom(x1: x1, y1: y1, x2: x2, y2: y2)
        case let .thinking(text):
            _ = presentation?.updateThinking(text)
            return .empty
        }
    }

    // MARK: - Click / move / scroll

    private static func click(
        x: Double,
        y: Double,
        button: ForegroundCommand.MouseButton,
        count: Int
    ) throws {
        let cgPoint = pixelToCG(x: x, y: y)
        let appKitPoint = toAppKitScreenPoint(fromCG: cgPoint)
        let (cgButton, down, up) = cgEventTypes(for: button)
        let sharedButton: MouseButton = switch button {
        case .left: .left
        case .right: .right
        case .middle: .middle
        }
        let clamped = max(1, min(3, count))

        syncPoseToCurrentCursor()
        try DaemonCursor.shared.runApproachThenAction(
            kind: .click(button: sharedButton),
            target: .display(screenID: CGMainDisplayID()),
            fallbackScreenPoint: appKitPoint,
            fallbackWindowFrame: .zero,
            tracking: ActionOverlayTracking(resolvePlacement: { nil })
        ) {
            CGWarpMouseCursorPosition(cgPoint)
            for n in 1 ... clamped {
                try post(mouseEvent: down, button: cgButton, at: cgPoint, clickCount: n)
                try post(mouseEvent: up, button: cgButton, at: cgPoint, clickCount: n)
            }
        }
    }

    private static func moveMouse(x: Double, y: Double) throws {
        let cgPoint = pixelToCG(x: x, y: y)
        let appKitPoint = toAppKitScreenPoint(fromCG: cgPoint)
        syncPoseToCurrentCursor()
        try DaemonCursor.shared.runApproachThenAction(
            kind: .accessibilityAction,
            target: .display(screenID: CGMainDisplayID()),
            fallbackScreenPoint: appKitPoint,
            fallbackWindowFrame: .zero,
            tracking: ActionOverlayTracking(resolvePlacement: { nil })
        ) {
            CGWarpMouseCursorPosition(cgPoint)
            try post(mouseEvent: .mouseMoved, button: .left, at: cgPoint, clickCount: 0)
        }
    }

    private static func scroll(
        x: Double,
        y: Double,
        direction: ForegroundCommand.ScrollDirection,
        amount: Int
    ) throws {
        let cgPoint = pixelToCG(x: x, y: y)
        let appKitPoint = toAppKitScreenPoint(fromCG: cgPoint)
        let dy: Int32
        let dx: Int32
        switch direction {
        case .up: dy = Int32(max(1, amount)); dx = 0
        case .down: dy = -Int32(max(1, amount)); dx = 0
        case .left: dx = Int32(max(1, amount)); dy = 0
        case .right: dx = -Int32(max(1, amount)); dy = 0
        }

        syncPoseToCurrentCursor()
        try DaemonCursor.shared.runApproachThenAction(
            kind: .scroll(direction: direction.rawValue),
            target: .display(screenID: CGMainDisplayID()),
            fallbackScreenPoint: appKitPoint,
            fallbackWindowFrame: .zero,
            tracking: ActionOverlayTracking(resolvePlacement: { nil })
        ) {
            CGWarpMouseCursorPosition(cgPoint)
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 2,
                wheel1: dy,
                wheel2: dx,
                wheel3: 0
            ) else {
                throw UIElementError.synthesizedEventCreationFailed(type: "scroll")
            }
            event.setIntegerValueField(.eventSourceUserData, value: COMPUTER_USE_EVENT_TAG)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Re-anchor `DaemonCursor` to where the real (hidden) system cursor
    /// currently sits before running an approach animation. Prevents
    /// the bezier from starting at yesterday's last-action endpoint
    /// after an intervention+recovery moved the cursor.
    ///
    /// `DaemonCursor.syncPose` takes Quartz-space screen points; we
    /// convert to AppKit because the panel origin math inside
    /// DaemonCursor lives in AppKit coords.
    private static func syncPoseToCurrentCursor() {
        guard let cgLoc = CGEvent(source: nil)?.location else { return }
        let appKit = toAppKitScreenPoint(fromCG: cgLoc)
        DaemonCursor.shared.syncPose(toScreenPoint: appKit)
    }

    private static func post(
        mouseEvent type: CGEventType,
        button: CGMouseButton,
        at point: CGPoint,
        clickCount: Int
    ) throws {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else {
            throw UIElementError.synthesizedEventCreationFailed(type: "\(type.rawValue)")
        }
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        // Tag so InterventionDetector knows this came from the agent
        // itself, not from the user.
        event.setIntegerValueField(.eventSourceUserData, value: COMPUTER_USE_EVENT_TAG)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    private static func typeText(_ text: String) throws {
        // One keyDown + keyUp pair per Unicode grapheme cluster, with the
        // payload set via `keyboardSetUnicodeString`. Matches the strategy
        // of `BackgroundInputDispatcher` so React/IME input handlers fire.
        for cluster in text {
            try postUnicode(String(cluster))
        }
    }

    private static func postUnicode(_ str: String) throws {
        let down = try makeUnicodeKeyEvent(str, isDown: true)
        let up = try makeUnicodeKeyEvent(str, isDown: false)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func makeUnicodeKeyEvent(_ str: String, isDown: Bool) throws -> CGEvent {
        // A nil event source inherits current modifier state. Text must not
        // become a shortcut after a preceding command-key action.
        let event = try makeKeyEvent(virtualKey: 0, isDown: isDown, flags: [])
        let utf16 = Array(str.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        return event
    }

    private static func pressKey(combo: String) throws {
        let parsed = try parseKeyCombo(combo)
        let down = try makeKeyEvent(virtualKey: parsed.keyCode, isDown: true, flags: parsed.flags)
        let up = try makeKeyEvent(virtualKey: parsed.keyCode, isDown: false, flags: parsed.flags)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func virtualKeyCode(forName name: String) -> Int? {
        switch name {
        case "a": return kVK_ANSI_A; case "b": return kVK_ANSI_B
        case "c": return kVK_ANSI_C; case "d": return kVK_ANSI_D
        case "e": return kVK_ANSI_E; case "f": return kVK_ANSI_F
        case "g": return kVK_ANSI_G; case "h": return kVK_ANSI_H
        case "i": return kVK_ANSI_I; case "j": return kVK_ANSI_J
        case "k": return kVK_ANSI_K; case "l": return kVK_ANSI_L
        case "m": return kVK_ANSI_M; case "n": return kVK_ANSI_N
        case "o": return kVK_ANSI_O; case "p": return kVK_ANSI_P
        case "q": return kVK_ANSI_Q; case "r": return kVK_ANSI_R
        case "s": return kVK_ANSI_S; case "t": return kVK_ANSI_T
        case "u": return kVK_ANSI_U; case "v": return kVK_ANSI_V
        case "w": return kVK_ANSI_W; case "x": return kVK_ANSI_X
        case "y": return kVK_ANSI_Y; case "z": return kVK_ANSI_Z
        case "0": return kVK_ANSI_0; case "1": return kVK_ANSI_1
        case "2": return kVK_ANSI_2; case "3": return kVK_ANSI_3
        case "4": return kVK_ANSI_4; case "5": return kVK_ANSI_5
        case "6": return kVK_ANSI_6; case "7": return kVK_ANSI_7
        case "8": return kVK_ANSI_8; case "9": return kVK_ANSI_9
        case "return", "enter": return kVK_Return
        case "tab": return kVK_Tab
        case "space": return kVK_Space
        case "delete", "backspace": return kVK_Delete
        case "escape", "esc": return kVK_Escape
        case "left": return kVK_LeftArrow
        case "right": return kVK_RightArrow
        case "up": return kVK_UpArrow
        case "down": return kVK_DownArrow
        case "home": return kVK_Home
        case "end": return kVK_End
        case "pageup": return kVK_PageUp
        case "pagedown": return kVK_PageDown
        default: return nil
        }
    }

    // MARK: - Screenshot / metadata

    struct ForegroundCapture {
        let url: URL
        let width: Int
        let height: Int
    }

    private static func takeScreenshot() async throws -> ForegroundCapture {
        let out = try await ScreenCapture.captureToPNG()
        return ForegroundCapture(url: out.url, width: out.width, height: out.height)
    }

    private static func captureZoom(
        x1: Double,
        y1: Double,
        x2: Double,
        y2: Double
    ) async throws -> ForegroundCommandOutput {
        let region = CGRect(
            x: min(x1, x2),
            y: min(y1, y2),
            width: abs(x2 - x1),
            height: abs(y2 - y1)
        )
        let out = try await ScreenCapture.captureCropToPNG(region: region)
        return try ForegroundCommandOutput(
            text: encodeImageResponse(url: out.url, width: out.width, height: out.height)
        )
    }

    /// Turn a captured PNG into the JSON envelope SalixConnector expects
    /// (`{image_data_url, image_width, image_height, image_size_bytes}`).
    /// The file stays on disk for debugging.
    private static func encodeImageResponse(url: URL, width: Int, height: Int) throws -> String {
        let data = try Data(contentsOf: url)
        let base64 = data.base64EncodedString()
        let payload: [String: Any] = [
            "image_data_url": "data:image/png;base64,\(base64)",
            "image_width": width,
            "image_height": height,
            "image_size_bytes": data.count,
            "path": url.path,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: encoded, encoding: .utf8) ?? "{}"
    }

    private static func primaryDisplayPixelSize() -> CGSize {
        let displayID = CGMainDisplayID()
        return CGSize(
            width: CGDisplayPixelsWide(displayID),
            height: CGDisplayPixelsHigh(displayID)
        )
    }

    private static func currentCursorPosition() -> CGPoint {
        guard let event = CGEvent(source: nil) else { return .zero }
        return event.location
    }

    // MARK: - Coordinate helpers

    /// Convert screenshot-pixel coordinates (top-left origin, in the
    /// scaled image the agent actually received) into Quartz CG points
    /// (top-left, display points) suitable for `CGEvent`.
    ///
    /// Delegates to `ForegroundCoordinateMap`, which reads the last
    /// screenshot's dimensions recorded by `ScreenCapture`. Without this
    /// indirection a 961×624 image on a 1512×982 logical display would
    /// click at ~1/3 of the intended screen-space — the agent's
    /// coordinates would be interpreted as device pixels instead of
    /// "scaled image pixels the agent actually saw".
    ///
    /// Also clamps to the active desktop union so a bogus off-screen
    /// image coordinate from the agent (model hallucinated pixel 10000)
    /// doesn't warp the cursor outside visible bounds where
    /// `CGWarpMouseCursorPosition` silently no-ops on some macOS
    /// versions.
    private static func pixelToCG(x: Double, y: Double) -> CGPoint {
        let raw = ForegroundCoordinateMap.imageToScreen(x: x, y: y)
        return clampToDesktop(raw)
    }

    /// Convert a Quartz CG point (top-left, y-down) into AppKit screen
    /// space (bottom-left, y-up) using the typed conversions in
    /// `CoordinateSpaces`. `DaemonCursor` lives in AppKit space so the
    /// sprite lands where the CGEvent fires.
    private static func toAppKitScreenPoint(fromCG point: CGPoint) -> CGPoint {
        appKitScreenPoint(from: Point<AXScreenSpace>(point)).cgPoint
    }

    // MARK: - Mouse-button down/up

    private static func mouseButton(
        downAt x: Double,
        y: Double,
        button: ForegroundCommand.MouseButton
    ) throws {
        let cgPoint = pixelToCG(x: x, y: y)
        let (cgButton, down, _) = cgEventTypes(for: button)
        CGWarpMouseCursorPosition(cgPoint)
        try post(mouseEvent: down, button: cgButton, at: cgPoint, clickCount: 1)
    }

    private static func mouseButton(
        upAt x: Double,
        y: Double,
        button: ForegroundCommand.MouseButton
    ) throws {
        let cgPoint = pixelToCG(x: x, y: y)
        let (cgButton, _, up) = cgEventTypes(for: button)
        CGWarpMouseCursorPosition(cgPoint)
        try post(mouseEvent: up, button: cgButton, at: cgPoint, clickCount: 1)
    }

    private static func cgEventTypes(
        for button: ForegroundCommand.MouseButton
    ) -> (CGMouseButton, CGEventType, CGEventType) {
        switch button {
        case .left: (.left, .leftMouseDown, .leftMouseUp)
        case .right: (.right, .rightMouseDown, .rightMouseUp)
        case .middle: (.center, .otherMouseDown, .otherMouseUp)
        }
    }

    // MARK: - Drag (with bezier approach + interpolated mid-stroke moves)

    private static func drag(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        button: ForegroundCommand.MouseButton
    ) throws {
        let startCG = pixelToCG(x: fromX, y: fromY)
        let endCG = pixelToCG(x: toX, y: toY)
        let startAppKit = toAppKitScreenPoint(fromCG: startCG)
        let endAppKit = toAppKitScreenPoint(fromCG: endCG)
        let (cgButton, down, up) = cgEventTypes(for: button)
        let sharedButton: MouseButton = switch button {
        case .left: .left
        case .right: .right
        case .middle: .middle
        }

        syncPoseToCurrentCursor()
        try DaemonCursor.shared.runApproachThenDrag(
            button: sharedButton,
            target: .display(screenID: CGMainDisplayID()),
            startScreenPoint: startAppKit,
            endScreenPoint: endAppKit,
            fallbackWindowFrame: .zero,
            approachTracking: ActionOverlayTracking(resolvePlacement: { nil }),
            onDragDown: {
                CGWarpMouseCursorPosition(startCG)
                try post(mouseEvent: down, button: cgButton, at: startCG, clickCount: 1)
            },
            onDragMove: { _, progress in
                let p = CGFloat(progress)
                let pt = CGPoint(
                    x: startCG.x + (endCG.x - startCG.x) * p,
                    y: startCG.y + (endCG.y - startCG.y) * p
                )
                CGWarpMouseCursorPosition(pt)
                let dragType: CGEventType = (button == .left)
                    ? .leftMouseDragged
                    : (button == .right ? .rightMouseDragged : .otherMouseDragged)
                try post(mouseEvent: dragType, button: cgButton, at: pt, clickCount: 1)
            },
            onDragUp: { _ in
                CGWarpMouseCursorPosition(endCG)
                try post(mouseEvent: up, button: cgButton, at: endCG, clickCount: 1)
            }
        )
    }

    // MARK: - Hold-key

    private static func holdKey(combo: String, seconds: Double) throws {
        let parsed = try parseKeyCombo(combo)
        let down = try makeKeyEvent(virtualKey: parsed.keyCode, isDown: true, flags: parsed.flags)
        down.post(tap: .cghidEventTap)

        Thread.sleep(forTimeInterval: max(0, seconds))

        let up = try makeKeyEvent(virtualKey: parsed.keyCode, isDown: false, flags: parsed.flags)
        up.post(tap: .cghidEventTap)
    }

    private static func parseKeyCombo(_ combo: String) throws -> (keyCode: Int, flags: CGEventFlags) {
        let parts = combo
            .lowercased()
            .split(separator: "-")
            .map(String.init)
        guard let keyName = parts.last else {
            throw UIElementError.synthesizedEventCreationFailed(type: "key:")
        }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "fn": flags.insert(.maskSecondaryFn)
            default:
                throw UIElementError.synthesizedEventCreationFailed(type: "modifier:\(modifier)")
            }
        }
        guard let virtualKey = virtualKeyCode(forName: keyName) else {
            throw UIElementError.synthesizedEventCreationFailed(type: "key:\(keyName)")
        }
        return (virtualKey, flags)
    }

    static func makeKeyEvent(
        virtualKey: Int,
        isDown: Bool,
        flags: CGEventFlags
    ) throws -> CGEvent {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(virtualKey),
            keyDown: isDown
        ) else {
            throw UIElementError.synthesizedEventCreationFailed(type: isDown ? "keyDown" : "keyUp")
        }
        // Release synthetic modifiers with the key, including hold-key.
        event.flags = isDown ? flags : []
        event.setIntegerValueField(.eventSourceUserData, value: COMPUTER_USE_EVENT_TAG)
        return event
    }

    // MARK: - Introspection

    private static func listRunningApplications() -> String {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> String? in
                guard let name = app.localizedName else { return nil }
                let bundle = app.bundleIdentifier ?? ""
                let hidden = app.isHidden ? " [hidden]" : ""
                return "\(name) (\(bundle))\(hidden)"
            }
        return apps.joined(separator: "\n")
    }

    private static func listOnScreenWindows() -> String {
        let descriptors = WindowDescriptor.onScreenWindows()
        let lines = descriptors.compactMap { d -> String? in
            let bounds = d.bounds.map {
                "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))"
            } ?? "(no bounds)"
            return "[\(d.number)] \(d.ownerName ?? "?") \(bounds)"
        }
        return lines.joined(separator: "\n")
    }

    private static func focusApplication(named name: String) throws -> String {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }
        let app: NSRunningApplication? = {
            if let byBundle = runningApps.first(where: { $0.bundleIdentifier == name }) {
                return byBundle
            }
            let lower = name.lowercased()
            return runningApps.first(where: { ($0.localizedName ?? "").lowercased() == lower })
        }()
        guard let app else {
            throw UIElementError.synthesizedEventCreationFailed(type: "focus:\(name)")
        }
        if app.isHidden { app.unhide() }
        app.activate(options: [.activateAllWindows])
        return "focused: \(app.localizedName ?? name)"
    }
}

public struct ForegroundCommandOutput: Sendable {
    public var text: String
    public init(text: String = "") {
        self.text = text
    }

    public static let empty = ForegroundCommandOutput(text: "")
}
