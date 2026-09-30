import CoreGraphics
import CUShared
import Foundation

/// Marker stamped on every CGEvent the foreground agent posts. The
/// intervention detector reads `eventSourceUserData` and skips events
/// carrying this tag so the agent's own clicks/typing don't look like
/// user interventions to itself. It keeps the legacy
/// `COMPUTER_USE_EVENT_TAG` value so other components can recognize events
/// posted by the agent.
public let COMPUTER_USE_EVENT_TAG: Int64 = 0x434F_4D50_5544_534B // "COMPUDSK"

/// Watches the global event tap for user mouse / keyboard activity and
/// flips a `StateMachine` to `.paused` when it sees any. Foreground only
/// (background mode actively expects user concurrency). Also surfaces the
/// "press ESC while paused to end the session" shortcut from legacy
/// ComputerUse — the observe-exit notice asks the user to do exactly that.
///
/// Port of legacy `InterventionDetector.swift`, minus the CoordinateConverter
/// dependency (foreground mode doesn't need the display/x/y mapping; paused
/// point is captured as a raw CGPoint).
@MainActor
public final class InterventionDetector {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    public weak var stateMachine: StateMachine?
    public var onIntervention: ((InterventionType) -> Void)?
    public var onExitRequested: (() -> Void)?

    public init() {}

    public func start() {
        let created = tryCreateEventTap()
        ForegroundModeRuntime.diagnostics.notice("event_tap_created=\(created)")
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func eventMask(for eventTypes: [CGEventType]) -> CGEventMask {
        eventTypes.reduce(into: CGEventMask(0)) { mask, eventType in
            mask |= (CGEventMask(1) << eventType.rawValue)
        }
    }

    private func tryCreateEventTap() -> Bool {
        let mask = eventMask(for: [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .keyDown,
            .scrollWheel,
        ])

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let detector = Unmanaged<InterventionDetector>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated {
                    detector.handleCGEvent(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        guard let sm = stateMachine, !sm.isIdle else { return }

        // Skip events the agent itself posted.
        if event.getIntegerValueField(.eventSourceUserData) == COMPUTER_USE_EVENT_TAG {
            return
        }

        // ESC during the paused (observing) state exits the session — the
        // ObserveExitNotice asks the user to do exactly this. Matches
        // legacy `InterventionDetector.onExitRequested` behaviour.
        let escapeKeyCode: Int64 = 53
        if
            type == .keyDown,
            sm.isPaused,
            event.getIntegerValueField(.keyboardEventKeycode) == escapeKeyCode
        {
            onExitRequested?()
            return
        }

        guard sm.isActive else { return }

        ForegroundModeRuntime.diagnostics.notice("intervention event_type=\(type.rawValue) source_pid=\(event.getIntegerValueField(.eventSourceUnixProcessID)) source_state=\(event.getIntegerValueField(.eventSourceStateID)) tag=\(event.getIntegerValueField(.eventSourceUserData)) x=\(event.location.x) y=\(event.location.y)")
        let interventionType: InterventionType = (type == .keyDown) ? .keyboard : .mouse
        let pausedScreenPoint = event.location

        sm.transitionToPaused(
            PausedInterventionContext(
                type: interventionType,
                cursor: PausedCursorLocation(display: 0, x: 0, y: 0),
                screenPoint: pausedScreenPoint
            )
        )
        onIntervention?(interventionType)
    }
}
