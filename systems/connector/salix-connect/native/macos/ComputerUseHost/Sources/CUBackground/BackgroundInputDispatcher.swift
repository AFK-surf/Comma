import AppKit
import Carbon.HIToolbox
import CUShared
import Darwin
import Foundation

extension MouseButton {
    var cgButtonNumber: Int64 {
        switch self {
        case .left: 0
        case .right: 1
        case .middle: 2
        }
    }
}

struct BackgroundMouseDispatcher {
    let targetPID: pid_t
    let windowNumber: Int
    let windowLayer: Int
    let windowFrame: CGRect
    let modifierFlags: CGEventFlags

    func click(at windowLocalPoint: CGPoint, button: MouseButton = .left) throws {
        if button == .left, modifierFlags.isEmpty {
            try clickViaSkyLightPrimer(at: windowLocalPoint)
            return
        }

        let timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        let base = nextBackgroundSyntheticEventNumber()
        let (downType, upType) = eventTypes(for: button)

        let down = try buildMouseEvent(
            spec: MouseEventSpec(
                type: downType,
                windowLocalPoint: windowLocalPoint,
                clickCount: 1,
                pressure: 1,
                button: button
            ),
            timestamp: timestamp,
            eventNumber: Int(base)
        )
        postMouseEvent(down)

        let up = try buildMouseEvent(
            spec: MouseEventSpec(
                type: upType,
                windowLocalPoint: windowLocalPoint,
                clickCount: 1,
                pressure: 0,
                button: button
            ),
            timestamp: timestamp,
            eventNumber: Int(base + 1)
        )
        postMouseEvent(up)
    }

    /// Primitives for driving a drag externally (e.g. from DaemonCursor which owns timing).
    func startDrag(at windowLocalPoint: CGPoint, button: MouseButton = .left) throws -> DragHandle {
        let timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        let base = nextBackgroundSyntheticEventNumber()
        let (downType, _) = eventTypes(for: button)

        if windowNumber != 0 {
            _ = BackgroundSkyLight.focusWithoutRaise(
                targetPID: targetPID,
                windowID: CGWindowID(windowNumber)
            )
            usleep(50000)
        }

        let down = try buildMouseEvent(
            spec: MouseEventSpec(
                type: downType,
                windowLocalPoint: windowLocalPoint,
                clickCount: 1,
                pressure: 1,
                button: button
            ),
            timestamp: timestamp,
            eventNumber: Int(base)
        )
        postMouseEvent(down)

        return DragHandle(
            dispatcher: self,
            button: button,
            timestamp: timestamp,
            baseEventNumber: base,
            ordinal: 1
        )
    }

    fileprivate func postDragMove(
        handle: inout DragHandle,
        windowLocalPoint: CGPoint
    ) throws {
        let dragType: NSEvent.EventType = switch handle.button {
        case .left: .leftMouseDragged
        case .right: .rightMouseDragged
        case .middle: .otherMouseDragged
        }
        let event = try buildMouseEvent(
            spec: MouseEventSpec(
                type: dragType,
                windowLocalPoint: windowLocalPoint,
                clickCount: 1,
                pressure: 1,
                button: handle.button
            ),
            timestamp: handle.timestamp,
            eventNumber: Int(handle.baseEventNumber + Int64(handle.ordinal))
        )
        postMouseEvent(event)
        handle.ordinal += 1
    }

    fileprivate func postDragUp(
        handle: inout DragHandle,
        windowLocalPoint: CGPoint
    ) throws {
        let (_, upType) = eventTypes(for: handle.button)
        let event = try buildMouseEvent(
            spec: MouseEventSpec(
                type: upType,
                windowLocalPoint: windowLocalPoint,
                clickCount: 1,
                pressure: 0,
                button: handle.button
            ),
            timestamp: handle.timestamp,
            eventNumber: Int(handle.baseEventNumber + Int64(handle.ordinal))
        )
        postMouseEvent(event)
        handle.ordinal += 1
    }

    private func clickViaSkyLightPrimer(at windowLocalPoint: CGPoint) throws {
        let windowID = CGWindowID(max(0, windowNumber))
        if windowID != 0 {
            _ = BackgroundSkyLight.focusWithoutRaise(targetPID: targetPID, windowID: windowID)
            usleep(50000)
        }

        let screenPoint = axScreenPoint(
            fromWindowLocal: Point<WindowLocalSpace>(windowLocalPoint),
            windowFrame: windowFrame
        ).cgPoint
        let quartzPoint = quartzWindowPoint(
            fromWindowLocal: Point<WindowLocalSpace>(windowLocalPoint),
            windowHeight: windowFrame.height
        ).cgPoint
        let offscreen = CGPoint(x: -1, y: -1)
        let base = nextBackgroundSyntheticEventNumber()

        let move = try buildSkyLightMouseEvent(
            type: .mouseMoved,
            screenPoint: screenPoint,
            windowLocalPoint: quartzPoint,
            clickState: 0,
            pressure: 0,
            eventNumber: Int(base)
        )
        let primerDown = try buildSkyLightMouseEvent(
            type: .leftMouseDown,
            screenPoint: offscreen,
            windowLocalPoint: offscreen,
            clickState: 1,
            pressure: 1,
            eventNumber: Int(base + 1)
        )
        let primerUp = try buildSkyLightMouseEvent(
            type: .leftMouseUp,
            screenPoint: offscreen,
            windowLocalPoint: offscreen,
            clickState: 1,
            pressure: 0,
            eventNumber: Int(base + 2)
        )
        let targetDown = try buildSkyLightMouseEvent(
            type: .leftMouseDown,
            screenPoint: screenPoint,
            windowLocalPoint: quartzPoint,
            clickState: 1,
            pressure: 1,
            eventNumber: Int(base + 3)
        )
        let targetUp = try buildSkyLightMouseEvent(
            type: .leftMouseUp,
            screenPoint: screenPoint,
            windowLocalPoint: quartzPoint,
            clickState: 1,
            pressure: 0,
            eventNumber: Int(base + 4)
        )

        postMouseEvent(move)
        usleep(15000)
        postMouseEvent(primerDown)
        usleep(1000)
        postMouseEvent(primerUp)
        usleep(100_000)
        postMouseEvent(targetDown)
        usleep(1000)
        postMouseEvent(targetUp)
    }

    private func buildSkyLightMouseEvent(
        type: NSEvent.EventType,
        screenPoint: CGPoint,
        windowLocalPoint: CGPoint,
        clickState: Int,
        pressure: Float,
        eventNumber: Int
    ) throws -> CGEvent {
        guard let appKitEvent = NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickState,
            pressure: pressure
        ) else {
            throw UIElementError.synthesizedEventCreationFailed(type: "\(type.rawValue)")
        }

        guard let event = appKitEvent.cgEvent else {
            throw UIElementError.synthesizedEventCreationFailed(type: "\(type.rawValue)")
        }

        event.location = screenPoint
        event.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.setIntegerValueField(buttonNumberField, value: MouseButton.left.cgButtonNumber)
        event.setIntegerValueField(mouseSubtypeField, value: 3)
        if windowNumber != 0 {
            event.setIntegerValueField(mouseWindowUnderPointerField, value: Int64(windowNumber))
            event.setIntegerValueField(mouseWindowUnderPointerThatCanHandleField, value: Int64(windowNumber))
        }
        _ = BackgroundSkyLight.setIntegerField(event, field: 40, value: Int64(targetPID))
        _ = BackgroundSkyLight.setWindowLocalPoint(event, windowLocalPoint)
        return event
    }

    private func buildMouseEvent(
        spec: MouseEventSpec,
        timestamp: CGEventTimestamp,
        eventNumber: Int
    ) throws -> CGEvent {
        guard let appKitEvent = NSEvent.mouseEvent(
            with: spec.type,
            location: spec.windowLocalPoint,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlags.rawValue)),
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: spec.clickCount,
            pressure: spec.pressure
        ) else {
            throw UIElementError.synthesizedEventCreationFailed(type: "\(spec.type.rawValue)")
        }

        guard let event = appKitEvent.cgEvent else {
            throw UIElementError.synthesizedEventCreationFailed(type: "\(spec.type.rawValue)")
        }

        event.flags = backgroundDispatchFlags(
            modifierFlags: modifierFlags,
            isTargetActive: false
        )
        // NSEvent.mouseEvent already set the global location from
        // windowNumber + windowLocalPoint. We re-pin it via
        // CGEventSetWindowLocation (Quartz window-local, top-origin) so
        // downstream apps that read that field get a consistent value.
        let quartzPoint = quartzWindowPoint(
            fromWindowLocal: Point<WindowLocalSpace>(spec.windowLocalPoint),
            windowHeight: windowFrame.height
        )
        cgEventWindowLocationSetter?(event, quartzPoint.cgPoint)
        event.timestamp = timestamp
        event.setIntegerValueField(buttonNumberField, value: spec.button.cgButtonNumber)
        event.setIntegerValueField(mouseSubtypeField, value: 3)
        event.setIntegerValueField(mouseWindowUnderPointerField, value: Int64(windowNumber))
        event.setIntegerValueField(mouseWindowUnderPointerThatCanHandleField, value: Int64(windowNumber))
        return event
    }

    private func postMouseEvent(_ event: CGEvent) {
        if !BackgroundSkyLight.postToPid(targetPID, event: event, attachAuthMessage: false) {
            event.postToPid(targetPID)
        }
    }

    private func eventTypes(for button: MouseButton) -> (down: NSEvent.EventType, up: NSEvent.EventType) {
        switch button {
        case .left:
            (.leftMouseDown, .leftMouseUp)
        case .right:
            (.rightMouseDown, .rightMouseUp)
        case .middle:
            (.otherMouseDown, .otherMouseUp)
        }
    }
}

struct DragHandle {
    fileprivate let dispatcher: BackgroundMouseDispatcher
    fileprivate let button: MouseButton
    fileprivate let timestamp: CGEventTimestamp
    fileprivate let baseEventNumber: Int64
    fileprivate var ordinal: Int

    mutating func move(to windowLocalPoint: CGPoint) throws {
        try dispatcher.postDragMove(handle: &self, windowLocalPoint: windowLocalPoint)
    }

    mutating func release(at windowLocalPoint: CGPoint) throws {
        try dispatcher.postDragUp(handle: &self, windowLocalPoint: windowLocalPoint)
    }
}

private struct MouseEventSpec {
    let type: NSEvent.EventType
    let windowLocalPoint: CGPoint
    let clickCount: Int
    let pressure: Float
    let button: MouseButton
}

/// Monotonic per-process counter for synthesized CGEvent numbers. The old
/// uptime-derived scheme collided when two events were synthesized within
/// the same microsecond, which some apps interpret as a spurious
/// double-click or drop entirely. A simple lock-guarded increment avoids
/// the race and is cheap (a handful of ns per event).
private final class SyntheticEventNumberSequence: @unchecked Sendable {
    static let shared = SyntheticEventNumberSequence()
    private let lock = NSLock()
    private var counter: Int64 = 0

    func next() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        counter &+= 1
        if counter <= 0 {
            counter = 1
        }
        return counter & 0x7FFF_FFFF
    }
}

private func nextBackgroundSyntheticEventNumber() -> Int64 {
    SyntheticEventNumberSequence.shared.next()
}

struct BackgroundKeyboardDispatcher {
    let targetPID: pid_t

    /// Post `text` as synthetic key events carrying Unicode strings.
    ///
    /// Why not AXUIElementSetAttributeValue(kAXValueAttribute,…)? That path
    /// mutates the DOM/AX value directly but bypasses the app's key-handling
    /// pipeline — React controlled inputs don't observe it, IMEs don't compose
    /// over it, undo stacks don't record it. keyboardSetUnicodeString fires a
    /// real NSEvent/TextInputEvent, which Blink/AppKit translate into proper
    /// `input` / `onChange` / `-insertText:` callbacks.
    ///
    /// We post one keyDown + keyUp pair per grapheme cluster. Chrome's
    /// RWHVMac ignores unicode strings attached to keyDown events whose
    /// virtualKey matches a shortcut (e.g. arrows, Enter), so we also keep
    /// virtualKey at 0 (kVK_ANSI_A) and let the Unicode payload override the
    /// displayed character.
    func typeText(_ text: String) throws {
        guard text.isEmpty == false else { return }

        // One event per grapheme cluster: Chrome/Blink coalesces events that
        // share a timestamp, so successive characters would collapse if we
        // reused a single nanosecond. `systemUptime * 1e9` gives us roughly
        // microsecond resolution from Swift, so we add an index offset to
        // guarantee monotonic, unique timestamps.
        var tickOffset: UInt64 = 0
        let baseTick = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)

        for cluster in text {
            let units: [UniChar] = Array(String(cluster).utf16)
            let downTick = CGEventTimestamp(baseTick &+ tickOffset)
            let upTick = CGEventTimestamp(baseTick &+ tickOffset &+ 1)
            tickOffset &+= 2

            try units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress, buffer.count > 0 else { return }
                guard
                    let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                    let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                else {
                    throw ComputerUseError.invalidArgument("keyboard event creation failed")
                }

                // Keyboard stays on the public per-pid route; the Chromium
                // trust workaround is specific to synthesized mouse events.
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                down.timestamp = downTick
                down.postToPid(targetPID)

                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                up.timestamp = upTick
                up.postToPid(targetPID)
            }

            // Brief pause between grapheme clusters so Blink's input event
            // pipeline sees them as distinct keystrokes rather than a burst.
            // 500µs is below human perception but enough to avoid coalescing
            // of high-plane surrogate pairs.
            usleep(500)
        }
    }

    func press(keyCombination: String) throws {
        let combo = try KeyCombination.parse(keyCombination)
        let timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)

        for modifier in combo.modifiers {
            let event = try buildKeyEvent(
                keyCode: modifier.virtualKey,
                flags: modifier.flags,
                isDown: true,
                timestamp: timestamp
            )
            event.postToPid(targetPID)
        }

        let combinedFlags = combo.modifiers.reduce(into: CGEventFlags()) { partial, modifier in
            partial.formUnion(modifier.flags)
        }

        let down = try buildKeyEvent(
            keyCode: combo.keyCode,
            flags: combinedFlags,
            isDown: true,
            timestamp: timestamp
        )
        down.postToPid(targetPID)

        let up = try buildKeyEvent(
            keyCode: combo.keyCode,
            flags: combinedFlags,
            isDown: false,
            timestamp: timestamp
        )
        up.postToPid(targetPID)

        // Peel off modifiers in reverse. Each modifier-up event must show the
        // flags state *after* it is released — i.e. with every modifier
        // released so far already subtracted, not just the current one.
        var remainingFlags = combinedFlags
        for modifier in combo.modifiers.reversed() {
            remainingFlags.subtract(modifier.flags)
            let event = try buildKeyEvent(
                keyCode: modifier.virtualKey,
                flags: remainingFlags,
                isDown: false,
                timestamp: timestamp
            )
            event.postToPid(targetPID)
        }
    }

    private func buildKeyEvent(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isDown: Bool,
        timestamp: CGEventTimestamp
    ) throws -> CGEvent {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: isDown
        ) else {
            throw ComputerUseError.invalidArgument("keyboard event creation failed")
        }

        event.flags = flags
        event.timestamp = timestamp
        return event
    }
}

private struct KeyCombination {
    let modifiers: [KeyModifier]
    let keyCode: CGKeyCode

    static func parse(_ raw: String) throws -> KeyCombination {
        let segments = raw
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        guard let final = segments.last, final.isEmpty == false else {
            throw ComputerUseError.unsupportedKey(raw)
        }

        let modifiers = try segments.dropLast().map(KeyModifier.init(token:))
        let keyCode = try keyCode(for: final)
        return KeyCombination(modifiers: modifiers, keyCode: keyCode)
    }

    private static func keyCode(for token: String) throws -> CGKeyCode {
        if token.count == 1, let scalar = token.unicodeScalars.first {
            switch scalar {
            case "a" ... "z":
                return alphaKeyCodes[String(scalar)]!
            case "0" ... "9":
                return digitKeyCodes[String(scalar)]!
            default:
                break
            }
        }

        guard let keyCode = namedKeyCodes[token] else {
            throw ComputerUseError.unsupportedKey(token)
        }
        return keyCode
    }
}

private struct KeyModifier {
    let flags: CGEventFlags
    let virtualKey: CGKeyCode

    init(token: String) throws {
        switch token {
        case "shift":
            flags = .maskShift
            virtualKey = CGKeyCode(kVK_Shift)
        case "control", "ctrl":
            flags = .maskControl
            virtualKey = CGKeyCode(kVK_Control)
        case "option", "alt":
            flags = .maskAlternate
            virtualKey = CGKeyCode(kVK_Option)
        case "command", "cmd", "super", "meta":
            flags = .maskCommand
            virtualKey = CGKeyCode(kVK_Command)
        default:
            throw ComputerUseError.unsupportedKey(token)
        }
    }
}

private let alphaKeyCodes: [String: CGKeyCode] = [
    "a": CGKeyCode(kVK_ANSI_A),
    "b": CGKeyCode(kVK_ANSI_B),
    "c": CGKeyCode(kVK_ANSI_C),
    "d": CGKeyCode(kVK_ANSI_D),
    "e": CGKeyCode(kVK_ANSI_E),
    "f": CGKeyCode(kVK_ANSI_F),
    "g": CGKeyCode(kVK_ANSI_G),
    "h": CGKeyCode(kVK_ANSI_H),
    "i": CGKeyCode(kVK_ANSI_I),
    "j": CGKeyCode(kVK_ANSI_J),
    "k": CGKeyCode(kVK_ANSI_K),
    "l": CGKeyCode(kVK_ANSI_L),
    "m": CGKeyCode(kVK_ANSI_M),
    "n": CGKeyCode(kVK_ANSI_N),
    "o": CGKeyCode(kVK_ANSI_O),
    "p": CGKeyCode(kVK_ANSI_P),
    "q": CGKeyCode(kVK_ANSI_Q),
    "r": CGKeyCode(kVK_ANSI_R),
    "s": CGKeyCode(kVK_ANSI_S),
    "t": CGKeyCode(kVK_ANSI_T),
    "u": CGKeyCode(kVK_ANSI_U),
    "v": CGKeyCode(kVK_ANSI_V),
    "w": CGKeyCode(kVK_ANSI_W),
    "x": CGKeyCode(kVK_ANSI_X),
    "y": CGKeyCode(kVK_ANSI_Y),
    "z": CGKeyCode(kVK_ANSI_Z),
]

private let digitKeyCodes: [String: CGKeyCode] = [
    "0": CGKeyCode(kVK_ANSI_0),
    "1": CGKeyCode(kVK_ANSI_1),
    "2": CGKeyCode(kVK_ANSI_2),
    "3": CGKeyCode(kVK_ANSI_3),
    "4": CGKeyCode(kVK_ANSI_4),
    "5": CGKeyCode(kVK_ANSI_5),
    "6": CGKeyCode(kVK_ANSI_6),
    "7": CGKeyCode(kVK_ANSI_7),
    "8": CGKeyCode(kVK_ANSI_8),
    "9": CGKeyCode(kVK_ANSI_9),
]

private let namedKeyCodes: [String: CGKeyCode] = [
    "space": CGKeyCode(kVK_Space),
    "tab": CGKeyCode(kVK_Tab),
    "return": CGKeyCode(kVK_Return),
    "enter": CGKeyCode(kVK_Return),
    "escape": CGKeyCode(kVK_Escape),
    "esc": CGKeyCode(kVK_Escape),
    "delete": CGKeyCode(kVK_Delete),
    "backspace": CGKeyCode(kVK_Delete),
    "forward-delete": CGKeyCode(kVK_ForwardDelete),
    "left": CGKeyCode(kVK_LeftArrow),
    "right": CGKeyCode(kVK_RightArrow),
    "up": CGKeyCode(kVK_UpArrow),
    "down": CGKeyCode(kVK_DownArrow),
    "home": CGKeyCode(kVK_Home),
    "end": CGKeyCode(kVK_End),
    "pageup": CGKeyCode(kVK_PageUp),
    "pagedown": CGKeyCode(kVK_PageDown),
]
