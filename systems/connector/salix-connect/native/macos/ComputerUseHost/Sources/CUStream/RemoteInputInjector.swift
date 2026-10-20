import CoreGraphics
import Foundation

/// Posts a remote viewer's pointer and keyboard input as HID events.
///
/// Events are not tagged as agent input. A foreground computer-use session
/// therefore handles them as a user intervention and pauses the agent.
final class RemoteInputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var pressedButtons: Set<Int> = []
    private var lastPoint = CGPoint.zero

    func handle(_ event: [String: Any], mapPoint: (Double, Double) -> CGPoint?) {
        guard let type = event["type"] as? String else { return }
        let flags = Self.flags(event["mods"] as? [String] ?? [])
        if let x = Self.double(event["x"]), let y = Self.double(event["y"]), let point = mapPoint(x, y) {
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
                clickCount: Self.int(event["clicks"]) ?? 1
            )
        case "scroll":
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
            guard let code = event["code"] as? String, let keyCode = Self.keyCodes[code] else { return }
            let key = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: type == "keydown")
            key?.flags = flags
            key?.post(tap: .cghidEventTap)
        default:
            break
        }
    }

    /// Releases buttons that the viewer still held when the stream ended.
    func releaseAll() {
        for button in pressedButtons {
            postMouse(Self.buttonType(button, isDown: false), button: button, flags: [])
        }
        pressedButtons.removeAll()
    }

    private func postMouse(_ type: CGEventType, button: Int, flags: CGEventFlags, clickCount: Int = 1) {
        let mouseButton = CGMouseButton(rawValue: UInt32(button)) ?? .left
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: lastPoint, mouseButton: mouseButton)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
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

    /// DOM `KeyboardEvent.code` to macOS virtual key code. Modifier keys travel as `mods` on each event.
    private static let keyCodes: [String: CGKeyCode] = [
        "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5, "KeyZ": 6, "KeyX": 7,
        "KeyC": 8, "KeyV": 9, "KeyB": 11, "KeyQ": 12, "KeyW": 13, "KeyE": 14, "KeyR": 15, "KeyY": 16,
        "KeyT": 17, "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21, "Digit6": 22, "Digit5": 23,
        "Equal": 24, "Digit9": 25, "Digit7": 26, "Minus": 27, "Digit8": 28, "Digit0": 29,
        "BracketRight": 30, "KeyO": 31, "KeyU": 32, "BracketLeft": 33, "KeyI": 34, "KeyP": 35,
        "Enter": 36, "KeyL": 37, "KeyJ": 38, "Quote": 39, "KeyK": 40, "Semicolon": 41, "Backslash": 42,
        "Comma": 43, "Slash": 44, "KeyN": 45, "KeyM": 46, "Period": 47, "Tab": 48, "Space": 49,
        "Backquote": 50, "Backspace": 51, "Escape": 53, "F5": 96, "F6": 97, "F7": 98, "F3": 99, "F8": 100,
        "F9": 101, "F11": 103, "F10": 109, "F12": 111, "Home": 115, "PageUp": 116, "Delete": 117,
        "F4": 118, "End": 119, "F2": 120, "PageDown": 121, "F1": 122, "ArrowLeft": 123,
        "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126, "NumpadEnter": 76,
    ]
}
