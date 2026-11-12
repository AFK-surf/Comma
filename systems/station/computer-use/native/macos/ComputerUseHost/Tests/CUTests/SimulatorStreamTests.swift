import CUStream
import Foundation
import Testing

@Test
func aLockedPortraitAppDoesNotUndoAPhysicalTurn() {
    var turn = DeviceTurn()
    turn.booted("one")
    let first = turn.next(displayed: 0, cover: true)
    turn.turned(first)
    #expect(turn.displayed(observed: 0, cover: true) == 1)
    let second = turn.next(displayed: 1, cover: true)
    turn.turned(second)
    #expect(turn.displayed(observed: 0, cover: true) == 2)
    // A reopened view has the same physical turn despite the app's unchanged orientation.
    turn.booted("one")
    #expect(turn.displayed(observed: 0, cover: true) == 2)
    turn.booted("two")
    #expect(turn.displayed(observed: 0, cover: true) == 0)
}

@Test
func aDuosPanelsKeepTheirMountingAxisAcrossATurn() {
    var turn = DeviceTurn()
    // Physical portrait is Landscape Left on Duo's inner panel.
    let next = turn.next(displayed: 1, cover: false)
    #expect(next == 1)
    turn.turned(next)
    #expect(turn.displayed(observed: 2, cover: false) == 2)
    #expect(turn.displayed(observed: 0, cover: true) == 1)
    #expect(turn.displayed(observed: 2, cover: false) == 2)
}

private let enumerated = """
Device Name: primary
  UI Orientation: Landscape Left
Device Name: primary-1
  UI Orientation: Portrait Upside Down
"""

@Test
func aPanelStandsAsItsOwnBlockSays() {
    #expect(SimulatorStreamSession.turnOf(enumerated, panel: "primary") == 1)
    #expect(SimulatorStreamSession.turnOf(enumerated, panel: "primary-1") == 2)
}

@Test
func anOlderRuntimesOnePanelIsPurpleMain() {
    let said = "Device Name: PurpleMain\n  UI Orientation: Landscape Right\n"
    #expect(SimulatorStreamSession.turnOf(said, panel: "primary") == 3)
    // A foldable's inner panel is never taken for it.
    #expect(SimulatorStreamSession.turnOf(said, panel: "primary-1") == 0)
}

/// Each corner of the picture as shown lands on the framebuffer corner that its turn put there: a finger must land on
/// what the person pressed, whichever way the picture is turned.
@Test(arguments: [
    (1, (0.0, 0.0), (0.0, 1.0)), // the top left of a picture turned clockwise was the framebuffer's bottom left
    (1, (1.0, 0.0), (0.0, 0.0)),
    (2, (0.0, 0.0), (1.0, 1.0)),
    (2, (0.25, 0.75), (0.75, 0.25)),
    (3, (0.0, 0.0), (1.0, 0.0)),
    (3, (1.0, 0.0), (1.0, 1.0)),
    (0, (0.25, 0.75), (0.25, 0.75)),
])
func aFingerIsTurnedBack(turn: Int, shown: (Double, Double), framebuffer: (Double, Double)) {
    let (x, y) = SimulatorStreamSession.unturned(shown.0, shown.1, turn)
    #expect(x == framebuffer.0 && y == framebuffer.1)
}

/// `pasted`'s log as an iOS 27.2 simulator wrote it for a ⌘V into Settings' search field, of text `devicectl` put on the
/// pasteboard: CoreDevice's own reads as it wrote, then the app's request, refused (its prompt never shows on a simulator).
private let refusedLog = """
2026-11-07 03:47:07.797 Df pasted[32063:1e5797] [com.apple.Pasteboard:Pasteboard] Bundle ID (null) from team (null) is requesting item 0 from pasteboard named com.apple.UIKit.pboard.general with UUID 3C1E
2026-11-07 03:47:07.808 Df pasted[32063:1e5797] [com.apple.Pasteboard:Pasteboard] Bundle ID com.apple.Preferences from team None is requesting item 0 from pasteboard named com.apple.UIKit.pboard.general with UUID 3C1E
2026-11-07 03:47:07.808 Df pasted[32063:1e5797] [com.apple.Pasteboard:Pasteboard] UserHasNotYetAuthorizedItemAccess
2026-11-07 03:47:07.811 Df pasted[32063:1e5797] [com.apple.Pasteboard:Pasteboard] Paste requires user authorization. Prompting...
"""

@Test
func aRefusedPasteNamesTheAppThatAsked() {
    let asked = SimulatorStreamSession.pasteAsked(refusedLog)
    #expect(asked?.app == "com.apple.Preferences")
    #expect(asked?.refused == true)
}

@Test
func aPasteTheAppMayMakeIsNotRefused() {
    // The same app asking again once allowed: its last request has no prompt after it.
    let allowed = refusedLog + "\n2026-11-07 03:47:09.324 Df pasted[32063:1e5797] [com.apple.Pasteboard:Pasteboard] Bundle ID com.apple.Preferences from team None is requesting item 0 from pasteboard named com.apple.UIKit.pboard.general with UUID 3C1E\n2026-11-07 03:47:09.324 Df pasted[32063:1e5aa7] [com.apple.Pasteboard:Pasteboard] NotExempt\n"
    #expect(SimulatorStreamSession.pasteAsked(allowed)?.refused == false)
    // CoreDevice writing the pasteboard is no app asking.
    #expect(SimulatorStreamSession.pasteAsked(String(refusedLog.split(separator: "\n")[0])) == nil)
    #expect(SimulatorStreamSession.pasteAsked("") == nil)
}

@Test
func aPanelComingUpMidSweepKeepsItsRequestedAngle() {
    var hinge = DeviceHinge()
    hinge.panelShown(cover: true)
    #expect(hinge.degrees == 0)
    // Half fold pressed: the sweep starts from the cover, and the inner panel comes up before it ends.
    #expect(hinge.asked(180).from == 0)
    hinge.panelShown(cover: false)
    #expect(hinge.degrees == 180)
}

@Test
func aPanelFollowsAHingeNotToldOtherwise() {
    var hinge = DeviceHinge()
    hinge.panelShown(cover: false)
    #expect(hinge.degrees == 180)
    hinge.panelShown(cover: true)
    #expect(hinge.degrees == 0)
    #expect(hinge.degrees == 0)
}

@Test
func anOlderRequestFailingLeavesANewerOnesHinge() {
    var hinge = DeviceHinge()
    let older = hinge.asked(130)
    let newer = hinge.asked(180)
    hinge.settled(newer.id)
    hinge.failed(older.id)
    #expect(hinge.degrees == 180)
}

@Test
func theNewestRequestFailingGoesBackToWhereItWas() {
    var hinge = DeviceHinge()
    let older = hinge.asked(130)
    let newer = hinge.asked(180)
    hinge.failed(newer.id)
    #expect(hinge.degrees == 130)
    hinge.failed(older.id)
    #expect(hinge.degrees == 0)
}

@Test
func aFailureBeforeANewerOneGoesBackPastBoth() {
    var hinge = DeviceHinge()
    let older = hinge.asked(130)
    let newer = hinge.asked(180)
    hinge.failed(older.id)
    #expect(hinge.degrees == 180)
    hinge.failed(newer.id)
    #expect(hinge.degrees == 0)
}

@Test
func aPanelReadOnOpeningDoesNotOverwriteASweep() {
    var hinge = DeviceHinge()
    let ask = hinge.asked(180)
    hinge.panelShown(cover: true, initial: true)
    #expect(hinge.degrees == 180)
    hinge.panelShown(cover: false)
    #expect(hinge.degrees == 180)
    hinge.settled(ask.id)
    #expect(hinge.degrees == 180)
}

@Test
func aCoverReadOnOpeningDoesNotEraseAHingeSetSince() {
    var hinge = DeviceHinge()
    hinge.settled(hinge.asked(180).id)
    hinge.panelShown(cover: true, initial: true)
    hinge.panelShown(cover: false)
    #expect(hinge.degrees == 180)
}

@Test
func aNewBootForgetsTheHinge() {
    var hinge = DeviceHinge()
    hinge.booted("first")
    hinge.settled(hinge.asked(180).id)
    hinge.booted("first")
    #expect(hinge.degrees == 180)
    hinge.booted("second")
    hinge.panelShown(cover: false, initial: true)
    #expect(hinge.degrees == 180)
}

@Test
func everyOpenViewOfADeviceIsHeard() {
    final class View {}
    let views = DeviceViews<View>()
    let panel = View()
    var preview: View? = View()
    let other = View()
    views.add("duo", panel)
    views.add("duo", preview!)
    views.add("another", other)
    // (in a pool: `allObjects` keeps what it gives until the pool drains)
    autoreleasepool {
        #expect(views.all("duo").count == 2)
        #expect(views.all("another").count == 1)
        #expect(views.all("none").isEmpty)
    }
    preview = nil
    #expect(views.all("duo").count == 1)
}

@Test
func aHeldPanelSettlesOnlyOnceItIsDrawnAndStill() {
    let start = ContinuousClock.now
    let at = { (ms: Int) in start + .milliseconds(ms) }
    let quiet = Duration.milliseconds(150)
    let flat = { (value: UInt8) in [UInt8](repeating: value, count: 144) }
    var look = PanelLook.Settling()
    // A panel not yet drawn is black, however long it stays so.
    for ms in stride(from: 0, through: 300, by: 16) { look.drew(flat(0), at: at(ms)) }
    #expect(!look.settled(at(600), quiet: quiet))
    // Fading in: each picture brighter than the one before, never settled while it goes on.
    for (step, ms) in stride(from: 316, through: 604, by: 16).enumerated() {
        look.drew(flat(UInt8(20 + 10 * step)), at: at(ms))
        #expect(!look.settled(at(ms + 16), quiet: quiet))
    }
    // Slow fades must accumulate their change, rather than pass because adjacent frames look alike.
    var slow = PanelLook.Settling()
    for (step, ms) in stride(from: 0, through: 1200, by: 16).enumerated() {
        slow.drew(flat(UInt8(20 + step)), at: at(ms))
        #expect(!slow.settled(at(ms + 16), quiet: quiet))
    }
    // Then about the same (a clock ticking in a corner): settled once that has gone on for `quiet`.
    var ticking = flat(200)
    for ms in stride(from: 620, through: 900, by: 16) {
        ticking[0] = UInt8(ms % 7)
        look.drew(ticking, at: at(ms))
    }
    #expect(look.settled(at(904), quiet: quiet))
    // A panel that draws nothing new after its last change settles once it has been still for `quiet`.
    var still = PanelLook.Settling()
    still.drew(flat(0), at: at(0))
    still.drew(flat(120), at: at(16))
    #expect(!still.settled(at(100), quiet: quiet))
    #expect(still.settled(at(170), quiet: quiet))
}
