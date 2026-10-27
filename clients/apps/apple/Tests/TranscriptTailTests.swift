import CoreGraphics
import XCTest
@testable import Comma

/// What the transcript makes of its scroll geometry, on frames recorded on a phone from a 500-message Home whose
/// replies differ widely in height. Laying out, its lazy stack moved the offset with nobody scrolling; that turned
/// the follow off, and the next estimate left the offset past the content's end: a blank chat until a touch.
final class TranscriptTailTests: XCTestCase {
    private func tail(_ distance: CGFloat, content: CGFloat, inset: CGFloat = 94) -> TranscriptTail {
        TranscriptTail(distance: distance, container: 664, content: content, inset: inset)
    }

    /// The stack settling its estimates moves the offset in a frame of its own: the follow stays on.
    func testTheStackSettlingLeavesTheFollowOn() {
        let settled = tail(-94, content: 132_846)
        let moved = tail(13_188, content: 132_846)
        XCTAssertNil(moved.follows(after: settled, readerScrolling: false))
    }

    /// The reader's own scroll decides it: away from the end the follow stops, back at the end it resumes.
    func testTheReadersScrollDecidesTheFollow() {
        let atEnd = tail(-94, content: 102_372)
        let away = tail(70, content: 102_372)
        XCTAssertEqual(away.follows(after: atEnd, readerScrolling: true), false)
        XCTAssertEqual(tail(46, content: 102_372).follows(after: away, readerScrolling: true), true)
        // A frame where the content also changed is rows being built during the scroll, not the scroll.
        XCTAssertNil(tail(2_496, content: 128_226).follows(after: away, readerScrolling: true))
    }

    /// Content that shrank under the offset leaves it past the end, which brings the transcript back to its end;
    /// at rest at the end the visible rect reaches past the content by the bottom inset only.
    func testAnOffsetPastTheEndGoesBackToTheEnd() {
        XCTAssertTrue(tail(-2_975, content: 132_846).pastEnd(readerScrolling: false))
        XCTAssertTrue(tail(-1_055, content: 5_447, inset: 94).pastEnd(readerScrolling: false))
        XCTAssertFalse(tail(-94, content: 132_846).pastEnd(readerScrolling: false))
        XCTAssertFalse(tail(-443, content: 220_288, inset: 443).pastEnd(readerScrolling: false))
        // A reader pulling past the end is left to the scroll view's own bounce.
        XCTAssertFalse(tail(-300, content: 132_846).pastEnd(readerScrolling: true))
    }
}
