import AppKit
import QuickChatCore

/// Watches the modifier Quick Chat opens with (⌘ unless the person chose
/// another) in every app: a global monitor sees other apps' modifier changes
/// and a local one Quick Chat's own, while it holds the keyboard. Neither
/// needs a permission. A double tap opens Quick Chat; a tap listens again
/// after the words were edited. With no modifier, a global shortcut Main
/// holds opens it, and nothing here fires.
@MainActor
final class ModifierTapMonitor {
    var onTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var modifier: TapModifier? = .meta {
        didSet {
            guard modifier != oldValue else { return }
            tap = ModifierTap()
        }
    }

    private var tap = ModifierTap()
    private var monitors: [Any] = []
    private var last: (keyCode: UInt16, flags: UInt, timestamp: TimeInterval)?

    func start() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        guard let modifier else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // macOS delivers some modifier releases twice.
        if let last, last.keyCode == event.keyCode, last.flags == flags.rawValue,
           last.timestamp == event.timestamp {
            return
        }
        last = (event.keyCode, flags.rawValue, event.timestamp)

        let (keyCodes, flag) = Self.keys(of: modifier)
        let others = NSEvent.ModifierFlags([.command, .shift, .option, .control, .function]).subtracting(flag)
        let input: ModifierTap.Event
        if !keyCodes.contains(event.keyCode) || !flags.isDisjoint(with: others) {
            input = .otherModifier
        } else {
            input = flags.contains(flag) ? .down : .up
        }
        switch tap.handle(input, at: event.timestamp, lastInput: Self.lastInput()) {
        case .single: onTap?()
        case .double: onDoubleTap?()
        case nil: break
        }
    }

    /// The left and right keys of a modifier, and its flag.
    private static func keys(of modifier: TapModifier) -> (keyCodes: Set<UInt16>, flag: NSEvent.ModifierFlags) {
        switch modifier {
        case .meta: ([54, 55], .command)
        case .shift: ([56, 60], .shift)
        case .alt: ([58, 61], .option)
        case .control: ([59, 62], .control)
        }
    }

    /// When the latest key-down, click or scroll happened, in event timestamps
    /// (seconds since startup). The HID system's state sees keys the window
    /// server keeps for itself, such as ⌘Tab and ⌘Space; the session's state
    /// sees posted events too.
    private static func lastInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let states: [CGEventSourceStateID] = [.hidSystemState, .combinedSessionState]
        let since = states.flatMap { state in
            types.map { CGEventSource.secondsSinceLastEventType(state, eventType: $0) }
        }.min() ?? .infinity
        return ProcessInfo.processInfo.systemUptime - since
    }
}
