import AppKit
import Testing

@testable import QuickChatHost

@MainActor
struct ModifierTapMonitorTests {
    /// Two ⌘ taps with the system reporting no input; `heldFrom` is the point
    /// (of down 1, up 1, down 2, up 2, numbered 0 to 3) from which a key is held,
    /// and `released` the one where it is let go. Returns the taps seen.
    private func taps(
        heldFrom: Int? = nil, released: Int = .max, betweenChecks: Bool = false
    ) throws -> (single: Int, double: Int) {
        var held = false
        var result = (single: 0, double: 0)
        let monitor = ModifierTapMonitor(systemInput: { -.infinity }, keyHeld: { held })
        monitor.onTap = { result.single += 1 }
        monitor.onDoubleTap = { result.double += 1 }
        for (step, (down, time)) in [(true, 0.0), (false, 0.1), (true, 0.2), (false, 0.3)].enumerated() {
            if step == released { held = false }
            if step == heldFrom { held = true }
            monitor.handle(try #require(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: down ? .command : [],
                timestamp: time, windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55
            )))
            if betweenChecks, step == heldFrom {
                monitor.checkKeys()
                held = false
            }
        }
        return result
    }

    @Test func twoTapsOpen() throws {
        let result = try taps()
        #expect(result.single == 1 && result.double == 1)
    }

    @Test func aKeyHeldAtThePressMakesAChord() throws {
        let result = try taps(heldFrom: 0, released: 1)
        #expect(result.single == 1 && result.double == 0)
    }

    @Test func aKeyHeldAtTheReleaseMakesAChord() throws {
        let result = try taps(heldFrom: 1, released: 2)
        #expect(result.single == 1 && result.double == 0)
    }

    @Test func aKeySeenWhileWatchingMakesAChord() throws {
        // Down and up again between ⌘'s press and release, as ⌘Tab's Tab.
        let result = try taps(heldFrom: 2, betweenChecks: true)
        #expect(result.single == 1 && result.double == 0)
    }
}
