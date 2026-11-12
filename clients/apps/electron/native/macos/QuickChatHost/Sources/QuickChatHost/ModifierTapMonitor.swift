import AppKit
import QuickChatCore

/// Watches the modifier Quick Chat opens with (⌘ unless the person chose
/// another) in every app: a global monitor sees other apps' modifier changes
/// and a local one Quick Chat's own, while it holds the keyboard. Neither
/// needs a permission. A double tap opens Quick Chat; a tap listens again
/// after the words were edited. With no modifier, a global shortcut Main
/// holds opens it, and nothing here fires.
///
/// A press with any other key held is a chord, not a tap. Key-down events need a
/// permission, the state of the keys does not, so it is read from the press
/// until the release or `ModifierTap.maximumPress`. The latest-input times alone
/// can lag a quick ⌘Tab's Tab (on a macOS 27.2 VM they move only every 0.5 s).
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
    private var keyWatch: Timer?
    private let systemInput: () -> TimeInterval
    private let keyHeld: () -> Bool

    init(
        systemInput: @escaping () -> TimeInterval = ModifierTapMonitor.lastSystemInput,
        keyHeld: @escaping () -> Bool = ModifierTapMonitor.anyKeyHeld
    ) {
        self.systemInput = systemInput
        self.keyHeld = keyHeld
    }

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

    /// Turns the press in progress into a chord if a key is held now.
    func checkKeys() {
        guard keyHeld() else { return }
        stopKeyWatch()
        _ = tap.handle(.otherModifier, at: 0, lastInput: 0)
    }

    private func startKeyWatch() {
        stopKeyWatch()
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if ProcessInfo.processInfo.systemUptime - started > ModifierTap.maximumPress {
                    self.stopKeyWatch()
                } else {
                    self.checkKeys()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keyWatch = timer
    }

    private func stopKeyWatch() {
        keyWatch?.invalidate()
        keyWatch = nil
    }

    func handle(_ event: NSEvent) {
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
        // The key of a chord can still be down at the release.
        if case .up = input { checkKeys() }
        switch tap.handle(input, at: event.timestamp, lastInput: systemInput()) {
        case .single: onTap?()
        case .double: onDoubleTap?()
        case nil: break
        }
        // Or down already at the press, when this runs late.
        if case .down = input { checkKeys(); startKeyWatch() } else { stopKeyWatch() }
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

    /// Whether any key but the modifiers is down.
    nonisolated private static func anyKeyHeld() -> Bool {
        let modifiers = 54...63
        return (0..<128).contains { key in
            !modifiers.contains(key) && CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key))
        }
    }

    /// When the latest key-down, click or scroll happened, in event timestamps
    /// (seconds since startup). The HID system's state sees keys the window
    /// server keeps for itself, such as ⌘Tab and ⌘Space; the session's state
    /// sees posted events too.
    nonisolated private static func lastSystemInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let states: [CGEventSourceStateID] = [.hidSystemState, .combinedSessionState]
        let since = states.flatMap { state in
            types.map { CGEventSource.secondsSinceLastEventType(state, eventType: $0) }
        }.min() ?? .infinity
        return ProcessInfo.processInfo.systemUptime - since
    }
}
