import Foundation
import XCTest
@testable import Comma

/// The gate, told snapshots as a core that started from `SessionCustody.resume` publishes them (Android's
/// `SessionCustodyTest` checks its own the same way).
final class SessionCustodyTests: XCTestCase {
    private let origin = "https://api.example.com"
    private let session = "session-1"

    private func custody() throws -> SessionCustody {
        let custody = try SessionCustody(record: MemoryRecord(), apiOrigin: origin)
        XCTAssertTrue(custody.adoptEarlier(StoredBearer(token: "bearer", audience: custody.audience, sessionId: session,
                                                        userId: "user-1", email: "user@example.com",
                                                        expiresAtEpochSeconds: 4_102_444_800)))
        return custody
    }

    private func signedIn(_ authority: String, revision: Int, generation: Int) -> [String: Any] {
        ["authority": ["authorityInstanceId": authority, "kind": "swiftui_keychain"], "phase": "signed_in",
         "revision": revision, "generation": generation, "session": ["sessionId": session]]
    }

    func testTheFirstCoreContinuesTheAppsAuthorityAndItsLeaseOpens() throws {
        let custody = try custody()
        // Before any snapshot: the app's authority, from the start.
        let resumed = custody.resume()
        XCTAssertEqual(resumed["authorityInstanceId"] as? String, custody.authorityInstanceId)
        XCTAssertEqual(resumed["generation"] as? Int64, 0)
        XCTAssertEqual(resumed["revision"] as? Int64, 0)
        XCTAssertTrue(resumed["sessionId"] is NSNull)

        let lease = SessionLease(audience: custody.audience, authorityInstanceId: custody.authorityInstanceId,
                                 generation: 1, sessionId: session)
        custody.gate(signedIn(custody.authorityInstanceId, revision: 1, generation: 1), lease: lease)
        XCTAssertEqual(custody.acquire(lease)?.token, "bearer")

        let next = custody.resume()
        XCTAssertEqual(next["authorityInstanceId"] as? String, custody.authorityInstanceId)
        XCTAssertEqual(next["generation"] as? Int64, 1)
        XCTAssertEqual(next["revision"] as? Int64, 1)
        XCTAssertEqual(next["sessionId"] as? String, session)
    }

    func testASnapshotOfAnotherAuthorityOpensNothing() throws {
        let custody = try custody()
        let lease = SessionLease(audience: custody.audience, authorityInstanceId: "another", generation: 1, sessionId: session)
        custody.gate(signedIn("another", revision: 1, generation: 1), lease: lease)
        XCTAssertNil(custody.acquire(lease))
        XCTAssertNil(custody.current())
        XCTAssertNotNil(custody.identity())
    }

    /// A 401 shuts the gate, and the generation it was seen at never opens again.
    func testARevokedGenerationStaysShut() throws {
        let custody = try custody()
        let authority = custody.authorityInstanceId
        let lease = SessionLease(audience: custody.audience, authorityInstanceId: authority, generation: 1, sessionId: session)
        custody.gate(signedIn(authority, revision: 1, generation: 1), lease: lease)
        let leased = try XCTUnwrap(custody.acquire(lease))
        XCTAssertTrue(custody.revoke(leased))
        XCTAssertNil(custody.current())
        custody.gate(signedIn(authority, revision: 2, generation: 1), lease: lease)
        XCTAssertNil(custody.acquire(lease))
    }

    /// Another account is kept beside the one in use, read again from the record, and switched to without signing in.
    func testAnotherAccountIsKeptAndSwitchedToWithoutSigningInAgain() throws {
        let record = MemoryRecord()
        let custody = try SessionCustody(record: record, apiOrigin: origin)
        XCTAssertTrue(custody.adoptEarlier(StoredBearer(token: "bearer-1", audience: custody.audience, sessionId: session,
                                                        userId: "user-1", email: "one@example.com",
                                                        expiresAtEpochSeconds: 4_102_444_800)))
        let kept = try XCTUnwrap(try custody.change(["kind": "keep"]) as? [String: Any])
        XCTAssertTrue(kept["active"] is NSNull)

        let answer: [String: Any] = ["token": "bearer-2", "session_id": "session-2", "expires_at": 4_102_444_800,
                                     "user": ["id": "user-2", "email": "two@example.com"]]
        let body = custody.keepBearer(try JSONSerialization.data(withJSONObject: answer), request: 1)
        let issued = try XCTUnwrap((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["credential"] as? String)
        let committed = try XCTUnwrap(try custody.change(["kind": "commit", "issued": issued, "supersede": [String]()]) as? [String: Any])
        XCTAssertEqual((committed["active"] as? [String: Any])?["userId"] as? String, "user-2")
        XCTAssertEqual((committed["pending"] as? [Any])?.count, 0)

        let again = try SessionCustody(record: record, apiOrigin: origin)
        let stored = again.vault()
        let ref = try XCTUnwrap(((stored["kept"] as? [[String: Any]])?.first)?["ref"] as? String)
        let switched = try XCTUnwrap(try again.change(["kind": "activate", "kept": ref]) as? [String: Any])
        let active = try XCTUnwrap(switched["active"] as? [String: Any])
        XCTAssertEqual(active["userId"] as? String, "user-1")
        XCTAssertEqual(again.tokenFor(try XCTUnwrap(active["ref"] as? String)), "bearer-1")
        let other = try XCTUnwrap(((switched["kept"] as? [[String: Any]])?.first)?["ref"] as? String)

        let forgotten = try XCTUnwrap(try again.change(["kind": "forget", "kept": other]) as? [String: Any])
        XCTAssertNil(forgotten["kept"])
        XCTAssertEqual((forgotten["pending"] as? [Any])?.count, 1)
    }
}
