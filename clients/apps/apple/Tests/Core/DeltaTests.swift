import Foundation
import XCTest
@testable import Comma

/// A topic's deltas applied as the core sends them (the core's `delta.ts` and `collections.ts` make them), as
/// Android's `DeltaTest` checks its own.
final class DeltaTests: XCTestCase {
    private func json(_ text: String) -> Any { try! JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) }
    private func apply(_ value: String, _ ops: String) -> Any? { Delta.apply(json(value), json(ops) as! NSArray) }
    private func same(_ expected: String, _ actual: Any?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual as? NSObject, json(expected) as? NSObject, file: file, line: line)
    }

    func testSetsAppendsAndRemovesAtAPath() {
        same(#"{"a":{"b":2},"list":[1,2,3],"n":null}"#, apply(#"{"a":{"b":1,"c":1},"list":[1]}"#, """
            [{"path":["a","b"],"set":2},{"path":["a","c"],"remove":true},
             {"path":["list"],"append":[2,3]},{"path":["n"],"set":null}]
            """))
    }

    func testExtendsAStringByTheTextItGained() {
        same(#"{"draft":{"text":"Hello there"}}"#,
             apply(#"{"draft":{"text":"Hel"}}"#, #"[{"path":["draft","text"],"extend":"lo there"}]"#))
        // Not a string there: skipped.
        same(#"{"n":1}"#, apply(#"{"n":1}"#, #"[{"path":["n"],"extend":"x"}]"#))
    }

    func testReplacesTheWholeValue() {
        same(#"{"x":1}"#, apply(#"{"a":1}"#, #"[{"path":[],"set":{"x":1}}]"#))
    }

    func testSkipsAnOpWhosePathDoesNotFit() {
        same(#"{"a":1}"#, apply(#"{"a":1}"#, #"[{"path":["b","c"],"set":2},{"path":["a",0],"set":2}]"#))
    }

    func testPutsPatchesMovesAndDropsItemsByTheirKey() {
        let start = #"{"items":[{"id":"a","n":1},{"id":"b","n":1},{"id":"c","n":1}]}"#
        same(#"{"items":[{"id":"z","n":9},{"id":"c","n":1},{"id":"a","n":2}]}"#, apply(start, """
            [{"path":["items"],"key":["id"],"drop":"b"},
             {"path":["items"],"key":["id"],"patch":"a","ops":[{"path":["n"],"set":2}]},
             {"path":["items"],"key":["id"],"move":"a","before":null},
             {"path":["items"],"key":["id"],"put":{"id":"z","n":9},"before":"c"}]
            """))
    }

    func testPutWithoutAPlaceReplacesTheItemWithItsKey() {
        same(#"{"items":[{"id":"a","n":5}]}"#,
             apply(#"{"items":[{"id":"a","n":1}]}"#, #"[{"path":["items"],"key":["id"],"put":{"id":"a","n":5}}]"#))
    }

    func testKeysOfSeveralFieldsAndNumbersMatch() {
        same(#"{"items":[{"s":"x","n":2}]}"#,
             apply(#"{"items":[{"s":"x","n":1},{"s":"x","n":2}]}"#, #"[{"path":["items"],"key":["s","n"],"drop":["x",1]}]"#))
    }

    /// Readers keep what they made of a part that did not change (`ChatViewReader`), so it must be the same object.
    func testLeavesTheValueAsItWasAndSharesWhatDidNotChange() throws {
        let before = json(#"{"list":[{"id":"a","n":1},{"id":"b","n":1}],"other":{"x":1}}"#) as! NSDictionary
        let copy = before.copy() as! NSDictionary
        let after = try XCTUnwrap(Delta.apply(before, json(#"[{"path":["list",1,"n"],"set":2}]"#) as! NSArray) as? NSDictionary)
        XCTAssertEqual(before, copy)
        let list = try XCTUnwrap(after["list"] as? NSArray), oldList = try XCTUnwrap(before["list"] as? NSArray)
        XCTAssertEqual((list[1] as? NSDictionary)?["n"] as? Int, 2)
        XCTAssertTrue(list[0] as AnyObject === oldList[0] as AnyObject)
        XCTAssertTrue(after["other"] as AnyObject === before["other"] as AnyObject)
    }
}
