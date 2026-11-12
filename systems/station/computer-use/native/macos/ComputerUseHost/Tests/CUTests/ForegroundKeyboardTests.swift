import CoreGraphics
@testable import CUForeground
import Testing

@MainActor
struct ForegroundKeyboardTests {
    @Test
    func foregroundShortcutReleasesModifiersOnKeyUp() throws {
        let modifiers: CGEventFlags = [.maskCommand, .maskShift]
        let down = try ForegroundExecutor.makeKeyEvent(virtualKey: 0, isDown: true, flags: modifiers)
        let up = try ForegroundExecutor.makeKeyEvent(virtualKey: 0, isDown: false, flags: modifiers)
        #expect(down.flags == modifiers)
        #expect(up.flags.isEmpty)
        #expect(down.type == .keyDown)
        #expect(up.type == .keyUp)
    }

    @Test
    func foregroundUnicodeEventsHaveNoShortcutModifiers() throws {
        let text = "A🦊"
        for isDown in [true, false] {
            let event = try ForegroundExecutor.makeUnicodeKeyEvent(text, isDown: isDown)
            #expect(event.flags.isEmpty)
            #expect(event.getIntegerValueField(.eventSourceUserData) == COMPUTER_USE_EVENT_TAG)
            var units = [UniChar](repeating: 0, count: 16)
            var count = 0
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
            #expect(String(decoding: units.prefix(count), as: UTF16.self) == text)
        }
    }
}
