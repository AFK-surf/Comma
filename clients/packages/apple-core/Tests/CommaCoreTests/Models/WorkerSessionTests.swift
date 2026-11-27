import XCTest
@testable import CommaCore

final class WorkerSessionTests: XCTestCase {
    func testDecodesWorkerSessionsWithIssueDetailAndWaitingState() throws {
        let json = """
        {
          "type": "task_participant_statuses",
          "group_id": "grp_1",
          "conversation_id": "cnv_1",
          "bound_worker": {
            "participant_id": "prt_lead",
            "actor_id": "agt_w",
            "name": "Lead"
          },
          "participants": [
            {
              "conversation_id": "cnv_1",
              "participant_id": "prt_lead",
              "state": "active",
              "status": "Working",
              "updated_at": 1720000001
            }
          ],
          "worker_sessions": [
            {
              "participant_id": "prt_lead",
              "actor_id": "agt_w",
              "slot": "lead",
              "label": "Lead",
              "model": "claude-opus-5",
              "runtime": "salix",
              "is_primary": true,
              "subscribed": true,
              "state": "active",
              "status": "Working",
              "updated_at": 1720000001
            },
            {
              "participant_id": "prt_rev",
              "actor_id": "agt_w",
              "slot": "reviewer",
              "label": "Reviewer",
              "model": "gpt-6.2-sol",
              "is_primary": false,
              "subscribed": true,
              "state": "waiting",
              "status": "Waiting",
              "updated_at": 1720000002,
              "issue": "rate_limit",
              "issue_detail": {
                "source": "openai",
                "profile_id": "prof_1",
                "profile_name": "Work",
                "reset_at": 1720003600,
                "credits": true,
                "trigger": "background"
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(ConversationEvent.self, from: json)
        XCTAssertEqual(event.type, "task_participant_statuses")
        XCTAssertEqual(event.workerSessions?.count, 2)
        XCTAssertEqual(event.workerSessions?[0].slot, "lead")
        XCTAssertEqual(event.workerSessions?[0].isPrimary, true)
        XCTAssertEqual(event.workerSessions?[1].state, "waiting")
        XCTAssertEqual(event.workerSessions?[1].issue, "rate_limit")
        XCTAssertEqual(event.workerSessions?[1].issueDetail?.source, "openai")
        XCTAssertEqual(event.workerSessions?[1].issueDetail?.profileID, "prof_1")
        XCTAssertEqual(event.workerSessions?[1].issueDetail?.credits, true)
        XCTAssertEqual(event.workerSessions?[1].issueDetail?.trigger, "background")
    }

    func testToleratesMalformedIssueDetailWithoutDroppingRoster() throws {
        let json = """
        {
          "type": "task_participant_statuses",
          "group_id": "grp_1",
          "conversation_id": "cnv_1",
          "participants": [
            {
              "conversation_id": "cnv_1",
              "participant_id": "prt_lead",
              "state": "error",
              "status": "Rate limited",
              "updated_at": 1720000001,
              "issue": "rate_limit",
              "issue_detail": { "reset_at": "not-a-number" }
            }
          ],
          "worker_sessions": [
            {
              "participant_id": "prt_lead",
              "slot": "lead",
              "label": "Lead",
              "is_primary": true,
              "state": "error",
              "status": "Rate limited",
              "issue": "rate_limit",
              "issue_detail": "unexpected-string"
            }
          ]
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(ConversationEvent.self, from: json)
        XCTAssertEqual(event.participants?.count, 1)
        XCTAssertNil(event.participants?[0].issueDetail)
        XCTAssertEqual(event.workerSessions?.count, 1)
        XCTAssertEqual(event.workerSessions?[0].slot, "lead")
        XCTAssertNil(event.workerSessions?[0].issueDetail)
    }
}
