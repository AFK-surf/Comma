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
        switch tap.handle(input, at: event.timestamp, activity: Self.activity()) {
        case .single: onTap?()
        case .double: onDoubleTap?()
        case nil: break
        }
    }

    /// Key-down, mouse-down and scroll counts for the login session.
    private static func activity() -> CommandTap.Activity {
        let state = CGEventSourceStateID.combinedSessionState
        let clicks = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].reduce(UInt32(0)) {
            $0 &+ CGEventSource.counterForEventType(state, eventType: $1)
        }
        return CommandTap.Activity(
            keyDowns: CGEventSource.counterForEventType(state, eventType: .keyDown),
            mouseDowns: clicks,
            scrolls: CGEventSource.counterForEventType(state, eventType: .scrollWheel)
        )
    }
}
