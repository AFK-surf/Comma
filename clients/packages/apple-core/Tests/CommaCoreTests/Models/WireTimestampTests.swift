import Foundation
import Testing
@testable import CommaCore

/// The API sends Unix seconds or milliseconds for the same field; every model reads them through one bound.
@Suite("Wire timestamps")
struct WireTimestampTests {
    @Test(arguments: [
        (9_999_999_999, 9_999_999_999),       // the last value read as seconds: November 2286
        (10_000_000_000, 10_000_000),          // the first value read as milliseconds: 26 April 1970
        (1_788_177_000, 1_788_177_000),        // the desktop's own examples, in seconds and milliseconds
        (1_788_177_000_000, 1_788_177_000),
        (1_788_177_000_123, 1_788_177_000.123),
        (0, 0),
    ] as [(Double, Double)])
    func secondsAndMillisecondsReadAsTheSameInstant(wire: Double, seconds: Double) {
        #expect(Date(wireTimestamp: wire).timeIntervalSince1970 == seconds)
    }

    @Test func aTaskChangedWhenLastUpdatedElseWhenCreated() {
        func task(updated: Double?, created: Double?) -> Conversation {
            Conversation(id: "t", groupID: "g", title: "t", status: "completed", kind: "agent_task",
                         updatedAt: updated, createdAt: created)
        }
        let instant = Date(timeIntervalSince1970: 1_788_177_000)
        #expect(task(updated: 1_788_177_000_000, created: 1_700_000_000).updatedDate == instant)
        #expect(task(updated: nil, created: 1_788_177_000).updatedDate == instant)
        #expect(task(updated: nil, created: nil).updatedDate == nil)
        #expect(task(updated: 0, created: nil).updatedDate == nil, "Zero is no time at all")
    }

    @Test func aDeviceWasLastActiveWhenLastSeenElseWhenItSignedIn() throws {
        let page = try JSONDecoder().decode(Page<AuthSessionRecord>.self, from: Data(#"""
        {"data":[{"id":"a","authenticated_at":1700000000,"last_seen_at":1788177000000},
                 {"id":"b","authenticated_at":1788177000},
                 {"id":"c"}]}
        """#.utf8))
        let instant = Date(timeIntervalSince1970: 1_788_177_000)
        #expect(page.data.map(\.lastActiveDate) == [instant, instant, nil])
    }

    @Test func workerStepsAndRecommendationsReadTheSameBound() throws {
        let records = try JSONDecoder().decode([WorkerHistoryRecord].self, from: Data(#"""
        [{"id":"1","kind":"user","content":"a","created_at":1788177000},
         {"id":"2","kind":"user","content":"b","created_at":1788177000000},
         {"id":"3","kind":"user","content":"c","created_at":"2026-08-31T11:50:00Z"}]
        """#.utf8))
        let instant = Date(timeIntervalSince1970: 1_788_177_000)
        #expect(records.map(\.startedAt) == [instant, instant, instant])
        let feed = try RecommendationFeed(envelope: .object(["state": .string("fresh"),
                                                             "snapshot": .object(["generatedAt": .number(1_788_177_000_000)])]))
        #expect(feed.generatedAt == instant)
    }
}
