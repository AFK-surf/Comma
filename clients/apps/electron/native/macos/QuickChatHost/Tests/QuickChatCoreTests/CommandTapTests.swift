import Testing
@testable import QuickChatCore

struct CommandTapTests {
    private let quiet = CommandTap.Activity(keyDowns: 10, mouseDowns: 4, scrolls: 7)

    /// Feeds (event, time, activity) and returns each completed tap with its time.
    private func taps(_ events: [(CommandTap.Event, Double, CommandTap.Activity)]) -> [(CommandTap.Tap, Double)] {
        var tap = CommandTap()
        return events.compactMap { event, time, activity in
            tap.handle(event, at: time, activity: activity).map { ($0, time) }
        }
    }

    /// Two quick ⌘ taps whose second press starts `gap` after the first release.
    private func pair(gap: Double, between: CommandTap.Activity? = nil) -> [(CommandTap.Event, Double, CommandTap.Activity)] {
        let second = between ?? quiet
        return [
            (.commandDown, 0, quiet), (.commandUp, 0.1, quiet),
            (.commandDown, 0.1 + gap, second), (.commandUp, 0.2 + gap, second),
        ]
    }

    @Test func aQuickPressAndReleaseIsATap() {
        #expect(taps([(.commandDown, 0, quiet), (.commandUp, 0.15, quiet)]).map(\.0) == [.single])
        // macOS repeats some releases: still one tap.
        #expect(taps([(.commandDown, 0, quiet), (.commandUp, 0.15, quiet), (.commandUp, 0.15, quiet)]).map(\.0) == [.single])
    }

    @Test func aLongPressIsNotATap() {
        #expect(taps([(.commandDown, 0, quiet), (.commandUp, 1.8, quiet)]).isEmpty)
    }

    @Test func twoQuickTapsAreADoubleTap() {
        let result = taps(pair(gap: 0.2))
        #expect(result.map(\.0) == [.single, .double])
        #expect(result.last?.1 == 0.4)
        // A repeated release between the taps changes nothing.
        var events = pair(gap: 0.2)
        events.insert((.commandUp, 0.1, quiet), at: 2)
        #expect(taps(events).map(\.0) == [.single, .double])
    }

    @Test func tapsTooFarApartAreTwoSingleTaps() {
        #expect(taps(pair(gap: 0.6)).map(\.0) == [.single, .single])
    }

    @Test func aThirdTapStartsANewPair() {
        var events = pair(gap: 0.1)
        events += [(.commandDown, 0.4, quiet), (.commandUp, 0.5, quiet), (.commandDown, 0.6, quiet), (.commandUp, 0.7, quiet)]
        #expect(taps(events).map(\.0) == [.single, .double, .single, .double])
    }

    @Test func anythingBetweenTheTapsBreaksThePair() {
        // A key, click or scroll between them changes the session's counters.
        #expect(taps(pair(gap: 0.2, between: CommandTap.Activity(keyDowns: 11, mouseDowns: 4, scrolls: 7))).map(\.0)
            == [.single, .single])
        // Shift between them.
        var events = pair(gap: 0.2)
        events.insert((.otherModifier, 0.15, quiet), at: 2)
        #expect(taps(events).map(\.0) == [.single, .single])
    }

    @Test func chordsAreNotTaps() {
        // ⌘C, a ⌘-click and ⌘-scroll change the session's counters.
        for activity in [
            CommandTap.Activity(keyDowns: 11, mouseDowns: 4, scrolls: 7),
            CommandTap.Activity(keyDowns: 10, mouseDowns: 5, scrolls: 7),
            CommandTap.Activity(keyDowns: 10, mouseDowns: 4, scrolls: 8),
        ] {
            #expect(taps([(.commandDown, 0, quiet), (.commandUp, 0.15, activity)]).isEmpty)
            // Nor do they complete a double tap.
            #expect(taps([
                (.commandDown, 0, quiet), (.commandUp, 0.1, quiet),
                (.commandDown, 0.2, quiet), (.commandUp, 0.3, activity),
            ]).map(\.0) == [.single])
        }
        // ⌘ with Shift, and both ⌘ keys.
        for event in [CommandTap.Event.otherModifier, .commandDown] {
            #expect(taps([(.commandDown, 0, quiet), (event, 0.05, quiet), (.commandUp, 0.15, quiet)]).isEmpty)
        }
    }
}
