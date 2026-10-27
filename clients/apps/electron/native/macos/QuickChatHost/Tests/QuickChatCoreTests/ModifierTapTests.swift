import Testing
@testable import QuickChatCore

struct ModifierTapTests {
    /// The latest key, click or scroll before any of the events below.
    private let quiet = -5.0

    /// Feeds (event, time, last input) and returns each completed tap with its time.
    private func taps(_ events: [(ModifierTap.Event, Double, Double)]) -> [(ModifierTap.Tap, Double)] {
        var tap = ModifierTap()
        return events.compactMap { event, time, lastInput in
            tap.handle(event, at: time, lastInput: lastInput).map { ($0, time) }
        }
    }

    /// Two quick ⌘ taps whose second press starts `gap` after the first release.
    private func pair(gap: Double, secondSees lastInput: Double? = nil) -> [(ModifierTap.Event, Double, Double)] {
        let second = lastInput ?? quiet
        return [
            (.down, 0, quiet), (.up, 0.1, quiet),
            (.down, 0.1 + gap, second), (.up, 0.2 + gap, second),
        ]
    }

    @Test func aQuickPressAndReleaseIsATap() {
        #expect(taps([(.down, 0, quiet), (.up, 0.15, quiet)]).map(\.0) == [.single])
        // macOS repeats some releases: still one tap.
        #expect(taps([(.down, 0, quiet), (.up, 0.15, quiet), (.up, 0.15, quiet)]).map(\.0) == [.single])
        // A key typed just before ⌘ went down.
        #expect(taps([(.down, 0, -0.01), (.up, 0.15, -0.01)]).map(\.0) == [.single])
    }

    @Test func aLongPressIsNotATap() {
        #expect(taps([(.down, 0, quiet), (.up, 1.8, quiet)]).isEmpty)
    }

    @Test func twoQuickTapsAreADoubleTap() {
        let result = taps(pair(gap: 0.2))
        #expect(result.map(\.0) == [.single, .double])
        #expect(result.last?.1 == 0.4)
        // A repeated release between the taps changes nothing.
        var events = pair(gap: 0.2)
        events.insert((.up, 0.1, quiet), at: 2)
        #expect(taps(events).map(\.0) == [.single, .double])
    }

    @Test func tapsTooFarApartAreTwoSingleTaps() {
        #expect(taps(pair(gap: 0.6)).map(\.0) == [.single, .single])
    }

    @Test func aThirdTapStartsANewPair() {
        var events = pair(gap: 0.1)
        events += [(.down, 0.4, quiet), (.up, 0.5, quiet), (.down, 0.6, quiet), (.up, 0.7, quiet)]
        #expect(taps(events).map(\.0) == [.single, .double, .single, .double])
    }

    @Test func anythingBetweenTheTapsBreaksThePair() {
        // A key, click or scroll between them.
        #expect(taps(pair(gap: 0.2, secondSees: 0.2)).map(\.0) == [.single, .single])
        // Shift between them.
        var events = pair(gap: 0.2)
        events.insert((.otherModifier, 0.15, quiet), at: 2)
        #expect(taps(events).map(\.0) == [.single, .single])
    }

    @Test func chordsAreNotTaps() {
        // ⌘C, ⌘Tab, a ⌘-click or ⌘-scroll: input after the press.
        #expect(taps([(.down, 0, quiet), (.up, 0.15, 0.08)]).isEmpty)
        // Nor do they complete a double tap.
        #expect(taps([
            (.down, 0, quiet), (.up, 0.1, quiet),
            (.down, 0.2, quiet), (.up, 0.3, 0.25),
        ]).map(\.0) == [.single])
        // ⌘ with Shift, and both ⌘ keys.
        for event in [ModifierTap.Event.otherModifier, .down] {
            #expect(taps([(.down, 0, quiet), (event, 0.05, quiet), (.up, 0.15, quiet)]).isEmpty)
        }
    }

    @Test func aChordSeenLateIsStillAChord() {
        // ⌘V then ⌘V, each V a few milliseconds after ⌘: the monitor handles
        // each ⌘-down after its V went down, so only the timestamps tell.
        #expect(taps([
            (.down, 0, 0.005), (.up, 0.1, 0.005),
            (.down, 0.2, 0.205), (.up, 0.3, 0.205),
        ]).isEmpty)
    }
}
