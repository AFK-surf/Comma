import CUBackground
import CoreGraphics
import Foundation

/// Posts a remote viewer's pointer and keyboard input. A display's stream sends HID events at the screen position, as
/// the picture shows every window. An app's stream sends through `windows`.
///
/// HID events are not tagged as agent input. A foreground computer-use session
/// therefore handles them as a user intervention and pauses the agent.
///
/// Text, click counts, the keys of other layouts, the fn and keypad flags and the wheel's pointer follow still.fail's
/// desktop input (station/src/screens/mac-input.ts `MacInput`, native/helper ScreenInput.swift). still.fail counts
/// clicks in its station; Cue's helper holds each view's input state, so it counts them here, from the press's place
/// and time, not from the client's `clicks`.
final class RemoteInputInjector {
    var windows: WindowInputSink?
    private let source = CGEventSource(stateID: .hidSystemState)
    private let now: () -> TimeInterval
    private var pressedButtons: Set<Int> = []
    private var lastPoint = CGPoint.zero
    /// Where the display's pointer was last posted (ScreenInput.swift `pointer`): a wheel goes there first.
    private var pointer = CGPoint(x: -1, y: -1)
    /// The last press, in the picture's fractions, for click counts (mac-input.ts `#press`).
    private var press: (at: TimeInterval, x: Double, y: Double, button: Int, clicks: Int)?

    init(windows: WindowInputSink? = nil, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.windows = windows
        self.now = now
    }

    func handle(_ event: [String: Any], mapPoint: (Double, Double) -> CGPoint?) {
        guard let type = event["type"] as? String else { return }
        let flags = Self.flags(event["mods"] as? [String] ?? [])
        let x = Self.double(event["x"]), y = Self.double(event["y"])
        if let x, let y, let point = mapPoint(x, y) {
            lastPoint = point
        }

        switch type {
        case "move":
            let button = pressedButtons.min()
            postMouse(button.map(Self.draggedType) ?? .mouseMoved, button: button ?? 0, flags: flags)
        case "down", "up":
            let button = Self.int(event["button"]) ?? 0
            let isDown = type == "down"
            if isDown { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
            postMouse(
                Self.buttonType(button, isDown: isDown),
                button: button,
                flags: flags,
                clickCount: clicks(button: button, down: isDown, x: x ?? 0, y: y ?? 0)
            )
        case "scroll":
            if let windows {
                let dx = Int32(-(Self.double(event["dx"]) ?? 0)), dy = Int32(-(Self.double(event["dy"]) ?? 0))
                windows.scroll(at: lastPoint, dx: dx, dy: dy, flags: flags)
                return
            }
            // A wheel turns what is under the pointer: it goes there first (ScreenInput.swift "scroll"). An app's
            // stream (above) posts to the window by the background route, which moves no pointer.
            if lastPoint != pointer {
                let move = CGEvent(
                    mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: lastPoint, mouseButton: .left
                )
                move?.flags = flags
                move?.post(tap: .cghidEventTap)
                pointer = lastPoint
            }
            let scroll = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(-(Self.double(event["dy"]) ?? 0)),
                wheel2: Int32(-(Self.double(event["dx"]) ?? 0)),
                wheel3: 0
            )
            scroll?.location = lastPoint
            scroll?.flags = flags
            scroll?.post(tap: .cghidEventTap)
        case "keydown", "keyup":
            guard let code = event["code"] as? String else { return }
            guard let keyCode = Self.keyCodes[code] else {
                // A key of no known place (another layout's): what it types, when it types one thing
                // (mac-input.ts `ops`, "key").
                if type == "keydown", let key = event["key"] as? String, key.unicodeScalars.count == 1,
                   flags.isDisjoint(with: [.maskControl, .maskCommand]) {
                    text(key)
                }
                return
            }
            let keyFlags = flags.union(Self.keyFlags(keyCode))
            if let windows {
                windows.key(keyCode, down: type == "keydown", flags: keyFlags)
                return
            }
            let key = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: type == "keydown")
            key?.flags = keyFlags
            key?.post(tap: .cghidEventTap)
        case "text":
            if let value = event["text"] as? String, !value.isEmpty { text(value) }
        default:
            break
        }
    }

    /// ⌘V where the focus is: what the viewer set on the clipboard, pasted (still.fail ScreenInput.swift `paste`), as
    /// the view's keys go (an app's view: to its windows).
    func paste() {
        for type in ["keydown", "keyup"] {
            handle(["type": type, "code": "KeyV", "key": "v", "mods": ["meta"]]) { _, _ in nil }
        }
    }

    /// Text typed where the focus is, as keyboard events that carry it (an IME's Chinese, a paste).
    private func text(_ value: String) {
        if let windows {
            windows.text(value)
            return
        }
        for event in Self.textEvents(value, source: source) {
            event.post(tap: .cghidEventTap)
        }
    }

    /// How many clicks a press makes: two downs of a button this close in time and place are one double click
    /// (mac-input.ts `CLICK_MS`, `CLICK_NEAR`); a release makes as many as its press.
    private func clicks(button: Int, down: Bool, x: Double, y: Double) -> Int {
        let at = now()
        guard down else { return press?.button == button ? press?.clicks ?? 1 : 1 }
        var count = 1
        if let last = press, last.button == button, at - last.at <= Self.clickInterval,
           abs(last.x - x) <= Self.clickNear, abs(last.y - y) <= Self.clickNear {
            count = last.clicks + 1
        }
        press = (at, x, y, button, count)
        return count
    }

    /// Text as key events that carry it, down and up: at most 20 UTF-16 units each (what a keyboard event carries), a
    /// surrogate pair not split (ScreenInput.swift "text").
    static func textEvents(_ value: String, source: CGEventSource?) -> [CGEvent] {
        let units = Array(value.utf16)
        var events: [CGEvent] = []
        var at = 0
        while at < units.count {
            var chunk = Array(units[at ..< min(at + 20, units.count)])
            if chunk.count == 20, UTF16.isLeadSurrogate(chunk[19]) { chunk.removeLast() }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.flags = []
                events.append(event)
            }
            at += chunk.count
        }
        return events
    }

    /// The flags a Mac's own keyboard gives a key on its function row or keypad (mac-input.ts `ARROWS`, `FN_KEYS`).
    static func keyFlags(_ code: CGKeyCode) -> CGEventFlags {
        if arrows.contains(code) { return [.maskNumericPad, .maskSecondaryFn] }
        if fnKeys.contains(code) { return .maskSecondaryFn }
        return []
    }

    private static let clickInterval: TimeInterval = 0.5
    private static let clickNear = 0.01
    private static let arrows: Set<CGKeyCode> = [0x7B, 0x7C, 0x7D, 0x7E]
    private static let fnKeys: Set<CGKeyCode> = [
        0x72, 0x73, 0x74, 0x75, 0x77, 0x79, 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
    ]

    /// Releases buttons that the viewer still held when the stream ended.
    func releaseAll() {
        for button in pressedButtons {
            postMouse(Self.buttonType(button, isDown: false), button: button, flags: [])
        }
        pressedButtons.removeAll()
    }

    private func postMouse(_ type: CGEventType, button: Int, flags: CGEventFlags, clickCount: Int = 1) {
        if let windows {
            windows.mouse(type, at: lastPoint, button: button, clicks: clickCount, flags: flags)
            return
        }
        let mouseButton = CGMouseButton(rawValue: UInt32(button)) ?? .left
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: lastPoint, mouseButton: mouseButton)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        pointer = lastPoint
    }

    private static func buttonType(_ button: Int, isDown: Bool) -> CGEventType {
        switch button {
        case 0: isDown ? .leftMouseDown : .leftMouseUp
        case 1: isDown ? .rightMouseDown : .rightMouseUp
        default: isDown ? .otherMouseDown : .otherMouseUp
        }
    }

    private static func draggedType(_ button: Int) -> CGEventType {
        switch button {
        case 0: .leftMouseDragged
        case 1: .rightMouseDragged
        default: .otherMouseDragged
        }
    }

    private static func flags(_ mods: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for mod in mods {
            switch mod {
            case "shift": flags.insert(.maskShift)
            case "ctrl": flags.insert(.maskControl)
            case "alt": flags.insert(.maskAlternate)
            case "meta": flags.insert(.maskCommand)
            default: break
            }
        }
        return flags
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    /// DOM `KeyboardEvent.code` to macOS virtual key code (Events.h kVK_*), as still.fail's mac-input.ts `KEYCODES` less its
    /// modifier keys and Caps Lock: modifiers travel as `mods` on each event here.
    static let keyCodes: [String: CGKeyCode] = [
        "KeyA": 0x00, "KeyS": 0x01, "KeyD": 0x02, "KeyF": 0x03, "KeyH": 0x04, "KeyG": 0x05, "KeyZ": 0x06, "KeyX": 0x07,
        "KeyC": 0x08, "KeyV": 0x09, "IntlBackslash": 0x0A, "KeyB": 0x0B, "KeyQ": 0x0C, "KeyW": 0x0D, "KeyE": 0x0E,
        "KeyR": 0x0F, "KeyY": 0x10, "KeyT": 0x11, "Digit1": 0x12, "Digit2": 0x13, "Digit3": 0x14, "Digit4": 0x15,
        "Digit6": 0x16, "Digit5": 0x17, "Equal": 0x18, "Digit9": 0x19, "Digit7": 0x1A, "Minus": 0x1B, "Digit8": 0x1C,
        "Digit0": 0x1D, "BracketRight": 0x1E, "KeyO": 0x1F, "KeyU": 0x20, "BracketLeft": 0x21, "KeyI": 0x22,
        "KeyP": 0x23, "Enter": 0x24, "KeyL": 0x25, "KeyJ": 0x26, "Quote": 0x27, "KeyK": 0x28, "Semicolon": 0x29,
        "Backslash": 0x2A, "Comma": 0x2B, "Slash": 0x2C, "KeyN": 0x2D, "KeyM": 0x2E, "Period": 0x2F, "Tab": 0x30,
        "Space": 0x31, "Backquote": 0x32, "Backspace": 0x33, "Escape": 0x35, "F17": 0x40,
        "NumpadDecimal": 0x41, "NumpadMultiply": 0x43, "NumpadAdd": 0x45, "NumLock": 0x47, "AudioVolumeUp": 0x48,
        "AudioVolumeDown": 0x49, "AudioVolumeMute": 0x4A, "NumpadDivide": 0x4B, "NumpadEnter": 0x4C,
        "NumpadSubtract": 0x4E, "F18": 0x4F, "F19": 0x50, "NumpadEqual": 0x51, "Numpad0": 0x52, "Numpad1": 0x53,
        "Numpad2": 0x54, "Numpad3": 0x55, "Numpad4": 0x56, "Numpad5": 0x57, "Numpad6": 0x58, "Numpad7": 0x59,
        "F20": 0x5A, "Numpad8": 0x5B, "Numpad9": 0x5C, "IntlYen": 0x5D, "IntlRo": 0x5E, "NumpadComma": 0x5F,
        "F5": 0x60, "F6": 0x61, "F7": 0x62, "F3": 0x63, "F8": 0x64, "F9": 0x65, "Lang2": 0x66, "F11": 0x67,
        "Lang1": 0x68, "F13": 0x69, "F16": 0x6A, "F14": 0x6B, "F10": 0x6D, "ContextMenu": 0x6E, "F12": 0x6F,
        "F15": 0x71, "Insert": 0x72, "Help": 0x72, "Home": 0x73, "PageUp": 0x74, "Delete": 0x75, "F4": 0x76,
        "End": 0x77, "F2": 0x78, "PageDown": 0x79, "F1": 0x7A, "ArrowLeft": 0x7B, "ArrowRight": 0x7C,
        "ArrowDown": 0x7D, "ArrowUp": 0x7E,
    ]
}

/// One of a stream's target windows, its frame in global top-left points.
struct RemoteInputWindow: Equatable {
    let pid: pid_t
    let number: Int
    let frame: CGRect
}

/// Posts to one window of a process, whatever covers it.
protocol RemoteWindowPoster {
    /// Before a first press: the window takes it, not raised.
    func prepare(_ window: RemoteInputWindow, at point: CGPoint, flags: CGEventFlags)
    func mouse(_ window: RemoteInputWindow, _ type: CGEventType, at point: CGPoint, button: Int, clicks: Int, flags: CGEventFlags)
    func scroll(_ window: RemoteInputWindow, at point: CGPoint, dx: Int32, dy: Int32, flags: CGEventFlags)
    func key(_ window: RemoteInputWindow, _ code: CGKeyCode, down: Bool, flags: CGEventFlags)
    func text(_ window: RemoteInputWindow, _ text: String)
}

/// An app's stream: input goes to the target window under the picture's point, whatever covers it on the real screen.
/// The target is not raised and the person's pointer stays. A point on no target window goes nowhere. These events do
/// not pass the session event tap, so a foreground computer-use session does not take them for an intervention.
final class WindowInputSink {
    private let windows: () -> [RemoteInputWindow]
    private let poster: RemoteWindowPoster
    /// The window each held button went down on: a drag stays with it, wherever the pointer goes.
    private var held: [Int: RemoteInputWindow] = [:]
    /// The window that takes the keys: the last one pressed, or else the front one.
    private var keyWindow: RemoteInputWindow?

    init(windows: @escaping () -> [RemoteInputWindow], poster: RemoteWindowPoster = SkyLightWindowPoster()) {
        self.windows = windows
        self.poster = poster
    }

    private func window(at point: CGPoint) -> RemoteInputWindow? {
        windows().first { $0.frame.contains(point) }
    }

    func mouse(_ type: CGEventType, at point: CGPoint, button: Int, clicks: Int, flags: CGEventFlags) {
        let target: RemoteInputWindow? = switch type {
        // (a press that went nowhere has no release)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: held.removeValue(forKey: button)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: held[button]
        default: window(at: point)
        }
        guard let target else { return }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            held[button] = target
            keyWindow = target
            if clicks <= 1 { poster.prepare(target, at: point, flags: flags) }
        }
        poster.mouse(target, type, at: point, button: button, clicks: clicks, flags: flags)
    }

    func scroll(at point: CGPoint, dx: Int32, dy: Int32, flags: CGEventFlags) {
        guard let target = window(at: point) else { return }
        poster.scroll(target, at: point, dx: dx, dy: dy, flags: flags)
    }

    func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let keyWindow = takingKeys() else { return }
        poster.key(keyWindow, code, down: down, flags: flags)
    }

    /// Text goes where the keys do.
    func text(_ text: String) {
        guard let keyWindow = takingKeys() else { return }
        poster.text(keyWindow, text)
    }

    private func takingKeys() -> RemoteInputWindow? {
        let current = windows()
        if keyWindow == nil || !current.contains(where: { $0.number == keyWindow?.number }) {
            keyWindow = current.first
            if let keyWindow { poster.prepare(keyWindow, at: CGPoint(x: keyWindow.frame.midX, y: keyWindow.frame.midY), flags: []) }
        }
        return keyWindow
    }
}

/// Computer Use's background route (CUBackground): per-process events, addressed to a window.
struct SkyLightWindowPoster: RemoteWindowPoster {
    private func input(_ window: RemoteInputWindow, flags: CGEventFlags) -> RemoteWindowInput {
        RemoteWindowInput(pid: window.pid, windowNumber: window.number, windowFrame: window.frame, flags: flags)
    }

    func prepare(_ window: RemoteInputWindow, at point: CGPoint, flags: CGEventFlags) {
        input(window, flags: flags).focus(at: point)
    }

    func mouse(_ window: RemoteInputWindow, _ type: CGEventType, at point: CGPoint, button: Int, clicks: Int, flags: CGEventFlags) {
        input(window, flags: flags).postMouse(type, at: point, button: button, clicks: clicks)
    }

    func scroll(_ window: RemoteInputWindow, at point: CGPoint, dx: Int32, dy: Int32, flags: CGEventFlags) {
        input(window, flags: flags).postScroll(at: point, dx: dx, dy: dy)
    }

    func key(_ window: RemoteInputWindow, _ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        input(window, flags: flags).postKey(code, down: down)
    }

    func text(_ window: RemoteInputWindow, _ text: String) {
        input(window, flags: []).postEvents(RemoteInputInjector.textEvents(text, source: nil))
    }
}
