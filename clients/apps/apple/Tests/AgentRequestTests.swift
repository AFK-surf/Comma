import XCTest
@testable import Comma

/// An Agent's request cards: what the core's `agentRequests` value reads as, and where each card sits among the
/// messages shown, by the same rule as the desktop and Android apps.
final class AgentRequestTests: XCTestCase {
    private func messages(_ list: [(id: String, user: Bool)]) -> [ChatItem] {
        let server: [[String: Any]] = list.map { message in
            ["messageId": message.id, "role": message.user ? "user" : "assistant",
             "actorType": message.user ? "user" : "agent", "text": message.id]
        }
        let state: [String: Any] = ["status": "ready", "serverMessages": server, "pending": [], "messages": []]
        let value = try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: ["revision": 1, "state": state]))
        return ChatViewReader().read(value).timeline.compactMap { if case .message(_, let item) = $0 { item } else { nil } }
    }

    private func request(_ id: String, source: String?, status: AgentRequest.Status = .pending,
                         outcome: AgentRequest.Outcome? = nil, createdAt: Double = 1) -> AgentRequest {
        AgentRequest(id: id, status: status, outcome: outcome, createdAt: createdAt, sourceMessageID: source,
                     provider: "github", reason: "An app keeps its code in GitHub.")
    }

    func testACardSitsUnderTheReplyToItsMessageAndAWaitingOneOnTheNewestTurn() {
        let shown = messages([("m1", true), ("m2", false), ("m3", false), ("m4", true)])
        let answered = request("cap-1", source: "m1", status: .completed, outcome: .connected)
        let waiting = request("cap-2", source: "m4", createdAt: 2)
        let placed = AgentRequestPlacement(requests: [waiting, answered], messages: shown)
        XCTAssertEqual(placed.byMessage, ["m2": [answered]])
        XCTAssertEqual(placed.waiting, [waiting])
    }

    func testAFinishedRequestWhoseTurnIsNotLoadedShowsNowhere() {
        let shown = messages([("m5", true), ("m6", false)])
        let older = request("cap-1", source: "m0", status: .completed, outcome: .declined)
        let unsourced = request("cap-2", source: nil, status: .expired)
        let waiting = request("cap-3", source: nil)
        let placed = AgentRequestPlacement(requests: [older, unsourced, waiting], messages: shown)
        XCTAssertEqual(placed.byMessage, [:])
        XCTAssertEqual(placed.waiting, [waiting])
    }

    func testTheCoreValueReadsItsConnectRequestsOnly() {
        let value: NSDictionary = ["requests": [
            ["id": "cap-1", "type": "oauth_authorization", "status": "pending", "expiresAt": 2_000_000, "sourceMessageId": "m1",
             "oauth": ["provider": "github", "reason": "An app keeps its code in GitHub.",
                       "authorizationUrl": "https://github.com/login/oauth/authorize?state=s"]],
            ["id": "cap-2", "type": "oauth_authorization", "status": "pending",
             "oauth": ["provider": "github", "reason": "", "authorizationUrl": "http://example.com/authorize"]],
            ["id": "cap-x", "type": "location", "status": "pending"],
        ]]
        let read = AgentRequest.list(value)
        XCTAssertEqual(read.map(\.id), ["cap-1", "cap-2"])
        XCTAssertEqual(read[0].authorizationURL?.absoluteString, "https://github.com/login/oauth/authorize?state=s")
        // Only an https page opens in the browser.
        XCTAssertNil(read[1].authorizationURL)
        XCTAssertEqual(read[0].providerName, "GitHub")
        XCTAssertTrue(read[0].isOpen(at: 1_999_999))
        XCTAssertFalse(read[0].isOpen(at: 2_000_000))
    }
}
