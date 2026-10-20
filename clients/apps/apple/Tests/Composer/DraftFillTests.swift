import SwiftUI
import XCTest
import CommaCore
@testable import Comma

/// A pre-task's prompt landing in the composer: the pane notes it once for the fill wave, the caret goes after it,
/// and the wave's shape and schedule follow the desktop's `draftFillMotion.ts` (a crest at rest at both ends, the
/// line reflowing around grown glyphs).
@MainActor
final class DraftFillTests: XCTestCase {
    private func pane() throws -> ConversationPane {
        ConversationPane(kind: .router, workspace: Workspace(id: "w1", groupID: "g1", name: "W"), conversationID: "router",
                         store: try StoreHarness().store)
    }

    func testOnlyAPreTaskFillIsNoted() throws {
        let pane = try pane()
        pane.appendDraft("Typed or restored")
        XCTAssertNil(pane.draftFill, "Other inserts play nothing")
        pane.fillDraft("Summarize the #launch thread")
        let fill = try XCTUnwrap(pane.draftFill)
        XCTAssertEqual(pane.draftText, "Typed or restored\n\nSummarize the #launch thread")
        XCTAssertEqual(fill.inserted, "Summarize the #launch thread")
        XCTAssertTrue(fill.applies(to: pane.draftText))
        XCTAssertFalse(fill.applies(to: pane.draftText + "!"), "Typing after the fill ends it")
        XCTAssertFalse(fill.applies(to: pane.draftText, now: fill.at + .seconds(5)), "A fill never shown goes stale")
        pane.fillDraft("")
        XCTAssertNil(pane.draftFill, "Nothing to reveal")
    }

    func testFillLeavesTheCaretAfterTheFilledText() throws {
        let pane = try pane(), model = TriggerMenuModel()
        pane.fillDraft("Reply to Ada")
        XCTAssertNil(model.selectionBinding(for: pane).wrappedValue, "Text from outside the field drops the caret")
        model.placeCaretAtEnd(of: pane)
        let selection = try XCTUnwrap(model.selectionBinding(for: pane).wrappedValue)
        guard case .selection(let range) = selection.indices else { return XCTFail("A caret") }
        XCTAssertEqual(range, pane.draftText.endIndex..<pane.draftText.endIndex)
    }

    func testCrestRestsAtBothEndsAndCrossesEveryGlyph() {
        let wave = DraftFillWave(first: 0.3, last: 20)
        for position in [0.3, 5, 12.5, 20] {
            XCTAssertEqual(wave.strength(at: position, progress: 0), 0, accuracy: 1e-9, "The first frame is at rest")
            XCTAssertEqual(wave.strength(at: position, progress: 1), 0, accuracy: 1e-9, "The last frame is at rest")
            // The crest's centre passes every glyph once.
            let peak = stride(from: 0.0, through: 1, by: 0.001).map { wave.strength(at: position, progress: $0) }.max()
            XCTAssertEqual(peak ?? 0, 1, accuracy: 1e-3)
        }
        XCTAssertLessThan(wave.crest(at: 0.25), wave.crest(at: 0.5), "Left to right")
        XCTAssertEqual(DraftFillWave.bell(0), 1)
        XCTAssertEqual(DraftFillWave.bell(1), 0, accuracy: 1e-12)
        XCTAssertEqual(DraftFillWave.bell(-3), 0, accuracy: 1e-12)
    }

    func testGrownGlyphsPushTheRestOfTheLine() {
        let glyphs = [DraftFillWave.Glyph(center: 5, width: 10), .init(center: 15, width: 10), .init(center: 25, width: 10)]
        XCTAssertEqual(DraftFillWave.shifts(glyphs, strengths: [0, 0, 0]), [0, 0, 0], "At rest nothing moves")
        let shifts = DraftFillWave.shifts(glyphs, strengths: [1, 0.5, 0])
        let grow = DraftFillWave.grow
        // Each glyph grows about its centre and sits after the grown glyphs to its left.
        XCTAssertEqual(shifts[0], 10 * grow / 2, accuracy: 1e-9)
        XCTAssertEqual(shifts[1], 10 * grow + 10 * grow * 0.5 / 2, accuracy: 1e-9)
        XCTAssertEqual(shifts[2], 10 * grow * 1.5, accuracy: 1e-9)
    }

    func testReducedMotionOnlyFadesTheTint() {
        XCTAssertEqual(DraftFillWave.fade(at: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(DraftFillWave.fade(at: 0.5), DraftFillWave.fadePeak, accuracy: 1e-12)
        XCTAssertEqual(DraftFillWave.fade(at: 1), 0, accuracy: 1e-12)
    }
}
