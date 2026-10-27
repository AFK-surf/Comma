import XCTest
@testable import Comma

/// The transcript lays out only the newest rows of a long conversation, about a budget's height of them, and more
/// above as the reader scrolls up.
final class TranscriptWindowTests: XCTestCase {
    /// Rows of `lines` lines of text each.
    private func rows(_ ids: Range<Int>, lines: Int = 1) -> [ChatRow] {
        let text = Array(repeating: "A line of a reply.", count: lines).joined(separator: "\n")
        return ids.map { index in
            let pending = ChatPending(clientRequestID: "m\(index)", text: text, attachedTexts: [], files: [],
                                      replyToMessageID: nil, failed: false, error: nil, billing: false)
            return ChatRow(id: "m\(index)", relationshipID: "m\(index)", content: .pending(pending), isUser: true,
                           actorRole: nil, threadRoot: "m\(index)")
        }
    }

    private func extent(_ rows: ArraySlice<ChatRow>) -> CGFloat { rows.reduce(0) { $0 + TranscriptWindow.extent(of: $1) } }

    func testOpensOnTheNewestBudgetOfRows() {
        let window = TranscriptWindow()
        let short = rows(0..<500)
        let shown = window.range(in: short)
        XCTAssertEqual(shown.upperBound, 500, "It reaches the newest row")
        XCTAssertGreaterThanOrEqual(extent(short[shown]), TranscriptWindow.budget, "The newest rows fill the budget")
        XCTAssertLessThan(extent(short[(shown.lowerBound + 1)...]), TranscriptWindow.budget, "and no more")
        XCTAssertLessThan(window.range(in: rows(0..<500, lines: 100)).count, 10, "Long rows fill it with few")
        XCTAssertEqual(window.range(in: rows(0..<10)), 0..<10, "A short conversation shows every row")
    }

    func testKeepsItsRowsAsHistoryLoadsAboveAndGrowsWhereTheReaderGoes() {
        var window = TranscriptWindow()
        let kept = rows(0..<500)
        // Opened on the newest 24 messages; the rest of the kept history loads above them.
        window.pin(rows(476..<500))
        let full = TranscriptWindow().range(in: kept)
        XCTAssertEqual(window.range(in: kept), full, "Rows loading above join the window only to fill a budget")
        XCTAssertEqual(window.range(in: rows(476..<520)), 0..<44, "Rows arriving below join it")

        XCTAssertTrue(window.expandUp(kept))
        let grown = window.range(in: kept)
        XCTAssertGreaterThanOrEqual(extent(kept[grown.lowerBound..<full.lowerBound]), TranscriptWindow.budget,
                                    "Resting near the top takes in a budget more")
        XCTAssertFalse(window.shed(kept, above: false), "Two budgets stay whole")

        // A row far above: the window moves to it, away from the end, and grows back down to the end.
        XCTAssertTrue(window.reveal("m100", in: kept))
        let moved = window.range(in: kept)
        XCTAssertEqual(moved.lowerBound, 96, "A revealed row shows with a few rows above it")
        XCTAssertFalse(window.live)
        XCTAssertLessThan(extent(kept[moved]), TranscriptWindow.budget * 2, "It lays out no more than the rows near it")
        XCTAssertFalse(window.reveal("m110", in: kept), "A row already shown leaves the window as it is")
        XCTAssertEqual(window.range(in: rows(0..<520)), moved, "Rows arriving below a window away from the end stay out")
        while window.expandDown(kept) { if window.live { break } }
        XCTAssertTrue(window.live, "Resting near the bottom takes in rows down to the end")
        XCTAssertTrue(window.shed(kept, above: true), "Past the limit, rows leave the far side")
        XCTAssertEqual(window.range(in: kept).upperBound, 500)
        XCTAssertLessThanOrEqual(extent(kept[window.range(in: kept)]), TranscriptWindow.budget * 2 + 56)

        window.reset(kept)
        XCTAssertEqual(window.range(in: kept), TranscriptWindow().range(in: kept), "Back to the newest rows")
    }
}
