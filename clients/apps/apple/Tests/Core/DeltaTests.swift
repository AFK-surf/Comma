import Foundation
import XCTest
@testable import Comma

/// A topic's deltas applied as the core sends them (the core's `collections.ts` makes them), as Android's
/// `DeltaTest` checks its own.
final class DeltaTests: XCTestCase {
    private func json(_ text: String) -> Any { try! JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) }
    private func apply(_ value: String, _ ops: String) -> Any? { Delta.apply(json(value), json(ops) as! NSArray) }
    private func same(_ expected: String, _ actual: Any?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual as? NSObject, json(expected) as? NSObject, file: file, line: line)
    }

    /// The cases the core's own test (core-kernel `delta-cases.test.ts`) makes the ops of: each applies to its value after.
    func testAppliesEveryCaseTheCoreMakes() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../packages/core-kernel/test/fixtures/delta-cases.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [NSDictionary])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let applied = Delta.apply(c["old"] as Any, try XCTUnwrap(c["ops"] as? NSArray))
            XCTAssertEqual(applied as? NSObject, c["next"] as? NSObject, c["name"] as? String ?? "")
        }
    }

    func testSkipsAnOpWhosePathDoesNotFit() {
        same(#"{"a":1}"#, apply(#"{"a":1}"#, #"[{"path":["b","c"],"set":2},{"path":["a",0],"set":2}]"#))
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
