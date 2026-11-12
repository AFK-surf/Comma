import Darwin
import Foundation
import Testing
@testable import CUStream

// How long keys wait after a paste on a simulator (PasteBanner.swift): what the log said since the ⌘V, and the time
// since it, decide. The times are the real ones (Timing's defaults), given, not waited.

private let timing = PasteBanner.Timing()
private let adding = "2026-11-07 22:40:01.123 Df SpringBoard[812:4a2f] [com.apple.SpringBoard:KeyboardFocus] deferFromSBWindowScene: adding rule for <token: com.apple.DragUI.druid>"
private let invalidate = "2026-11-07 22:40:03.663 Df SpringBoard[812:4a2f] [com.apple.SpringBoard:KeyboardFocus] deferFromSBWindowScene: invalidate for <token: com.apple.DragUI.druid>"

/// A banner followed, as the session follows one: the stream's first line said.
private func followed() -> PasteBanner {
    let banner = PasteBanner()
    banner.read("Filtering the log data using \"…\"")
    return banner
}

private func decide(_ mark: PasteBanner.Mark, _ banner: PasteBanner, at ms: Int) -> PasteBanner.Outcome? {
    let now = banner.mark()
    let heard = PasteBanner.Heard(live: now.live, taken: now.taken, back: now.back)
    return PasteBanner.decide(mark, heard, waited: .milliseconds(ms), timing: timing)
}

/// The first paste after a boot: the banner comes up 0.3 s after the ⌘V and has the keys until 2.8 s. The old fixed
/// wait sent them at 2.6 s, while the banner had them, and they were lost; they now wait until it gives them back.
@Test
func keysWaitForALateBanner() {
    let banner = followed()
    let mark = banner.mark()
    #expect(decide(mark, banner, at: 300) == nil)
    banner.read(adding)
    #expect(decide(mark, banner, at: 2_600) == nil)
    #expect(decide(mark, banner, at: 2_790) == nil)
    banner.read(invalidate)
    #expect(decide(mark, banner, at: 2_800) == .back)
}

/// No banner (the paste refused, or the app took it without one): keys go after 1 s.
@Test
func keysGoWhenNoBannerComesUp() {
    let banner = followed()
    let mark = banner.mark()
    #expect(decide(mark, banner, at: 999) == nil)
    #expect(decide(mark, banner, at: 1_000) == .unseen)
}

/// A banner that never says it gave the keys back holds them at most 5 s.
@Test
func keysWaitAtMostTheCap() {
    let banner = followed()
    let mark = banner.mark()
    banner.read(adding)
    #expect(decide(mark, banner, at: 4_999) == nil)
    #expect(decide(mark, banner, at: 5_000) == .most)
}

/// A log not followed (it did not start), or no longer followed (its process ended): the fixed 2.6 s from the ⌘V.
/// The lines of a banner of an earlier paste do not end a later paste's wait.
@Test
func aLogNotFollowedWaitsTheFixedTime() {
    let unfollowed = PasteBanner()
    let mark = unfollowed.mark()
    #expect(!mark.live)
    #expect(decide(mark, unfollowed, at: 2_599) == nil)
    #expect(decide(mark, unfollowed, at: 2_600) == .fixed)

    let banner = followed()
    banner.read(adding)
    banner.read(invalidate)
    let later = banner.mark()
    #expect(decide(later, banner, at: 500) == nil)
    let lost = PasteBanner.Heard(live: false, taken: later.taken + 1, back: later.back)
    #expect(PasteBanner.decide(later, lost, waited: .milliseconds(2_599), timing: timing) == nil)
    #expect(PasteBanner.decide(later, lost, waited: .milliseconds(2_600), timing: timing) == .fixed)
}

/// The view ended while a paste waited: it goes on at once.
@Test
func theViewEndingEndsTheWait() async {
    let banner = followed()
    let mark = banner.mark()
    banner.read(adding)
    banner.end()
    #expect(await banner.passed(mark) == .ended)
}

/// The log's process (a script here, saying what `simctl spawn … log stream` says): its lines are read, a paste waits
/// for the banner it says, and the view's end ends the process (none left running).
@Test
func theFollowedLogIsReadAndEndsWithTheView() async {
    let script = """
        echo 'Filtering the log data using "…"'; echo '\(adding)'; echo '\(invalidate)'; exec sleep 600
        """
    let banner = PasteBanner()
    let (lines, line) = AsyncStream<String>.makeStream()
    let (ends, ended) = AsyncStream<Int32>.makeStream()
    banner.heardLine = { line.yield($0) }
    banner.processEnded = { ended.yield($0) }
    let mark = PasteBanner.Mark(taken: 0, back: 0, live: true, at: banner.mark().at)
    banner.follow(["/bin/sh", "-c", script])
    for await text in lines where text.contains("invalidate") { break }
    let heard = banner.mark()
    #expect(heard.live && heard.taken == 1 && heard.back == 1)
    #expect(PasteBanner.decide(mark, PasteBanner.Heard(live: heard.live, taken: heard.taken, back: heard.back), waited: .zero, timing: timing) == .back)
    banner.end()
    var pid: Int32 = 0
    for await ended in ends {
        pid = ended
        break
    }
    #expect(pid > 0)
    #expect(kill(pid, 0) != 0)
}
