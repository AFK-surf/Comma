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
}
