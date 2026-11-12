import AppKit
import CoreGraphics
import CUBackground
@testable import CUStream
import Testing

private final class FakePoster: RemoteWindowPoster {
    var log: [String] = []
    func prepare(_ w: RemoteInputWindow, at p: CGPoint, flags _: CGEventFlags) {
        log.append("prepare \(w.number) \(Int(p.x)),\(Int(p.y))")
    }

    func mouse(_ w: RemoteInputWindow, _ type: CGEventType, at p: CGPoint, button: Int, clicks: Int, flags _: CGEventFlags) {
        log.append("mouse \(w.number) \(type.rawValue) \(Int(p.x)),\(Int(p.y)) b\(button) c\(clicks)")
    }

    func scroll(_ w: RemoteInputWindow, at _: CGPoint, dx _: Int32, dy _: Int32, flags _: CGEventFlags) {
        log.append("scroll \(w.number)")
    }

    func key(_ w: RemoteInputWindow, _ code: CGKeyCode, down: Bool, flags _: CGEventFlags) {
        log.append("key \(w.number) \(code) \(down)")
    }

    func text(_ w: RemoteInputWindow, _ text: String) {
        log.append("text \(w.number) \(text)")
    }
}

private let front = RemoteInputWindow(pid: 7, number: 11, frame: CGRect(x: 100, y: 100, width: 100, height: 100))
private let back = RemoteInputWindow(pid: 7, number: 22, frame: CGRect(x: 150, y: 100, width: 200, height: 100))

private func injector(now: @escaping () -> TimeInterval = { 0 }) -> (RemoteInputInjector, FakePoster) {
    let poster = FakePoster()
    return (RemoteInputInjector(windows: WindowInputSink(windows: { [front, back] }, poster: poster), now: now), poster)
}

private func screen(_ x: Double, _ y: Double) -> CGPoint? {
    CGPoint(x: x, y: y)
}

@Test
func anAppStreamsPressGoesToTheFrontmostTargetWindowAtThePoint() {
    let (input, poster) = injector()
    input.handle(["type": "down", "x": 160, "y": 110, "button": 0, "clicks": 1], mapPoint: screen)
    input.handle(["type": "up", "x": 160, "y": 110, "button": 0, "clicks": 1], mapPoint: screen)
    #expect(poster.log == [
        "prepare 11 160,110",
        "mouse 11 \(CGEventType.leftMouseDown.rawValue) 160,110 b0 c1",
        "mouse 11 \(CGEventType.leftMouseUp.rawValue) 160,110 b0 c1",
    ])
}

@Test
func aPointOnNoTargetWindowGoesNowhere() {
    let (input, poster) = injector()
    input.handle(["type": "move", "x": 5, "y": 5], mapPoint: screen)
    input.handle(["type": "down", "x": 5, "y": 5, "button": 0], mapPoint: screen)
    input.handle(["type": "scroll", "x": 5, "y": 5, "dx": 1, "dy": 1], mapPoint: screen)
    #expect(poster.log.isEmpty)
}

@Test
func aDragStaysWithTheWindowItStartedOn() {
    let (input, poster) = injector()
    input.handle(["type": "down", "x": 120, "y": 110, "button": 0, "clicks": 1], mapPoint: screen)
    input.handle(["type": "move", "x": 300, "y": 110], mapPoint: screen)
    input.handle(["type": "up", "x": 300, "y": 110, "button": 0, "clicks": 1], mapPoint: screen)
    #expect(poster.log.dropFirst(2) == [
        "mouse 11 \(CGEventType.leftMouseDragged.rawValue) 300,110 b0 c1",
        "mouse 11 \(CGEventType.leftMouseUp.rawValue) 300,110 b0 c1",
    ])
}

@Test
func keysGoToTheLastPressedWindowOrElseTheFrontOne() {
    let (fresh, first) = injector()
    fresh.handle(["type": "keydown", "code": "Digit7"], mapPoint: screen)
    #expect(first.log == ["prepare 11 150,150", "key 11 26 true"])

    let (pressed, second) = injector()
    pressed.handle(["type": "down", "x": 300, "y": 110, "button": 0, "clicks": 1], mapPoint: screen)
    pressed.handle(["type": "keydown", "code": "KeyA"], mapPoint: screen)
    #expect(second.log.last == "key 22 0 true")
}

@Test
func anAppStreamSendsToWindowsAndADisplayStreamStaysGlobal() {
    let app = ScreenStreamSession(channel: ScreenChannel(fd: -1), options: ["target": "app", "apps": ["Calculator"], "control": true])
    #expect(app.sendsToWindows)
    let desktop = ScreenStreamSession(channel: ScreenChannel(fd: -1), options: ["target": "display", "control": true])
    #expect(!desktop.sendsToWindows)
}

// What the app receives: AppKit reads the same event's window, point and button.
@Test
func theEventAddressesTheWindowAndItsPointNotTheScreen() throws {
    let input = RemoteWindowInput(
        pid: getpid(), windowNumber: 1234, windowFrame: CGRect(x: 510, y: 497, width: 230, height: 408), flags: .maskShift
    )
    let down = try #require(input.mouseEvent(.rightMouseDown, at: CGPoint(x: 543, y: 708), button: 1, clicks: 2))
    #expect(down.location == CGPoint(x: 543, y: 708))
    #expect(down.flags.contains(.maskShift))
    #expect(down.getIntegerValueField(.mouseEventClickState) == 2)
    #expect(down.getIntegerValueField(CGEventField(rawValue: 3)!) == 1)
    #expect(down.getIntegerValueField(CGEventField(rawValue: 91)!) == 1234)
    let seen = try #require(NSEvent(cgEvent: down))
    #expect(seen.windowNumber == 1234)
    #expect(seen.clickCount == 2)
}

@Test
func textGoesWhereTheKeysGo() {
    let (input, poster) = injector()
    input.handle(["type": "down", "x": 300, "y": 110, "button": 0], mapPoint: screen)
    input.handle(["type": "text", "text": "你好，世界"], mapPoint: screen)
    #expect(poster.log.last == "text 22 你好，世界")
}

// still.fail mac-input.ts: a key of no known place types what it says, unless ⌘ or ⌃ is held.
@Test
func aKeyOfAnotherLayoutTypesItsCharacter() {
    let (input, poster) = injector()
    input.handle(["type": "keydown", "code": "", "key": "é"], mapPoint: screen)
    input.handle(["type": "keyup", "code": "", "key": "é"], mapPoint: screen)
    input.handle(["type": "keydown", "code": "", "key": "ß", "mods": ["meta"]], mapPoint: screen)
    input.handle(["type": "keydown", "code": "", "key": "Unidentified"], mapPoint: screen)
    #expect(poster.log == ["prepare 11 150,150", "text 11 é"])
}

@Test
func arrowsAndFunctionKeysCarryTheFlagsAMacKeyboardGivesThem() {
    #expect(RemoteInputInjector.keyFlags(RemoteInputInjector.keyCodes["ArrowUp"]!) == [.maskNumericPad, .maskSecondaryFn])
    #expect(RemoteInputInjector.keyFlags(RemoteInputInjector.keyCodes["F5"]!) == .maskSecondaryFn)
    #expect(RemoteInputInjector.keyFlags(RemoteInputInjector.keyCodes["Home"]!) == .maskSecondaryFn)
    #expect(RemoteInputInjector.keyFlags(RemoteInputInjector.keyCodes["KeyA"]!) == [])
    #expect(RemoteInputInjector.keyCodes["Numpad5"] == 0x57)
}

// still.fail mac-input.ts: two presses of a button close in time and place are a double click; its release says so too.
@Test
func clicksAreCountedByTimeAndPlace() {
    var clock: TimeInterval = 10
    let (input, poster) = injector(now: { clock })
    let click = { (x: Double) in
        input.handle(["type": "down", "x": x, "y": 110, "button": 0, "clicks": 1], mapPoint: { _, _ in CGPoint(x: 160, y: 110) })
        input.handle(["type": "up", "x": x, "y": 110, "button": 0, "clicks": 1], mapPoint: { _, _ in CGPoint(x: 160, y: 110) })
    }
    click(0.5)
    clock += 0.2
    click(0.505)
    clock += 0.2
    click(0.505)
    clock += 0.8
    click(0.505)
    clock += 0.1
    click(0.6)
    let counts = poster.log.filter { $0.hasPrefix("mouse") }.map { $0.split(separator: " ").last! }
    #expect(counts == ["c1", "c1", "c2", "c2", "c3", "c3", "c1", "c1", "c1", "c1"])
}

// ScreenInput.swift "text": at most 20 UTF-16 units an event, a surrogate pair kept whole.
@Test
func textIsCarriedTwentyUnitsAnEventWithoutSplittingAPair() throws {
    let text = String(repeating: "a", count: 19) + "😀" + "中文"
    let events = RemoteInputInjector.textEvents(text, source: nil)
    #expect(events.count == 4)
    var carried = ""
    for event in events where event.getIntegerValueField(.keyboardEventAutorepeat) == 0 && event.type == .keyDown {
        var length = 0
        var units = [UniChar](repeating: 0, count: 32)
        event.keyboardGetUnicodeString(maxStringLength: 32, actualStringLength: &length, unicodeString: &units)
        carried += String(utf16CodeUnits: units, count: length)
    }
    #expect(carried == text)
}
