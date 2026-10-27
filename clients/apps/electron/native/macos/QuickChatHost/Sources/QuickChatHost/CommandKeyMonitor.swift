import AppKit
import QuickChatCore

/// Watches ⌘ in every app: a global monitor sees other apps' modifier
/// changes and a local one Quick Chat's own, while it holds the keyboard.
/// Neither needs a permission. A double tap opens Quick Chat; a tap
/// listens again after the words were edited.
@MainActor
final class CommandKeyMonitor {
    var onTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?

    private var tap = CommandTap()
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // macOS delivers some modifier releases twice.
        if let last, last.keyCode == event.keyCode, last.flags == flags.rawValue,
           last.timestamp == event.timestamp {
            return
        }
        last = (event.keyCode, flags.rawValue, event.timestamp)

        let input: CommandTap.Event
        if ![54, 55].contains(event.keyCode)
            || !flags.isDisjoint(with: [.shift, .option, .control, .function]) {
            input = .otherModifier
        } else {
            input = flags.contains(.command) ? .commandDown : .commandUp
        }
        switch tap.handle(input, at: event.timestamp, lastInput: Self.lastInput()) {
        case .single: onTap?()
        case .double: onDoubleTap?()
        case nil: break
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
