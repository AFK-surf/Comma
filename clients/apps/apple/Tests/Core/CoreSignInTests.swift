import Foundation
import XCTest
@testable import Comma

/**
 * The app's sign-in as it runs: `CommaStore` on the client core the app carries (Hermes running core.hbc), its requests
 * and databases in this process, and a fake Comma API in place of the server. The bearer the server issues stays in
 * `SessionCustody`: the core names it by reference, and the app adds it to the requests of the open session.
 */
@MainActor
final class CoreSignInTests: XCTestCase {
    private var runtimes: [CoreRuntime] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        for runtime in runtimes { await runtime.core.closed() }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        runtimes = []
        directories = []
    }

    private func start(_ server: FakeServer, custody: SessionCustody) async throws -> (CommaStore, CoreRuntime) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloads = directory.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        directories.append(directory)
        let runtime = try CoreRuntime.make(custody: custody, dataDirectory: directory.appendingPathComponent("core"),
                                           downloadRoot: downloads, configuration: server.configuration)
        runtimes.append(runtime)
        let store = CommaStore(configuration: AppConfiguration(baseURL: URL(string: server.origin)!, credentialService: "CoreSignInTests"),
                               runtime: runtime, workspacePreferences: UserDefaults(suiteName: UUID().uuidString)!)
        await store.start()
        return (store, runtime)
    }

    private func session(_ token: String? = nil) -> [String: Any] {
        var answer: [String: Any] = ["expires_at": 4_102_444_800, "session_id": "session-1",
                                     "user": ["email": "peng@example.com", "id": "user-1", "name": "Peng", "status": "active"]]
        if let token { answer["token"] = token }
        return answer
    }

    private func phase(_ core: any CoreAPI, _ wanted: String) async {
        _ = await core.first(["topic": "session"]) { value in SessionSnapshot(value).phase == wanted ? true : nil }
    }

    func testEmailCodeSignsInAndRequestsCarryTheBearerTheCoreNeverHolds() async throws {
        let server = FakeServer()
        server.on("POST", "/v1/comma/auth/email/login", json: ["challenge_id": "challenge-1"])
        server.on("POST", "/v1/comma/auth/email/verify", json: session("issued_secret"))
        server.on("POST", "/v1/comma/auth/logout", json: ["signed_out": true])
        let custody = try SessionCustody(record: MemoryRecord(), apiOrigin: server.origin)
        let (store, runtime) = try await start(server, custody: custody)
        await phase(runtime.core, "signed_out")

        let asked = await store.requestEmailCode(email: "peng@example.com")
        XCTAssertNil(asked)
        XCTAssertEqual(server.requests("POST", "/v1/comma/auth/email/login").first?.body["email"] as? String, "peng@example.com")
        await until { store.signIn?.challengeID != nil }
        let verified = await store.verify(code: "123456")
        XCTAssertNil(verified)
        await until { store.session != nil }

        XCTAssertEqual(store.session?.user.id, "user-1")
        XCTAssertEqual(custody.identity()?.userId, "user-1")
        let snapshot = await runtime.core.first(["topic": "session"]) { CoreJSON(value: $0) }
        let published = try JSONSerialization.data(withJSONObject: try XCTUnwrap(snapshot?.value))
        XCTAssertFalse(String(decoding: published, as: UTF8.self).contains("issued_secret"))
        // The member's profile is read with the session's bearer.
        let profile = await server.first("GET", "/v1/comma/me/profile")
        XCTAssertEqual(profile.authorization, "Bearer issued_secret")

        // Signing out ends the session on this iPhone at once; the core then revokes it with its bearer.
        await store.logout()
        XCTAssertNil(store.error)
        await until { store.session == nil }
        XCTAssertNil(custody.identity())
        let logout = await server.first("POST", "/v1/comma/auth/logout")
        XCTAssertEqual(logout.authorization, "Bearer issued_secret")
    }

    func testAKeptSessionIsCheckedAndShownAgainAtLaunch() async throws {
        let server = FakeServer()
        server.on("GET", "/v1/comma/auth/session", json: session())
        let custody = try SessionCustody(record: MemoryRecord(), apiOrigin: server.origin)
        custody.adoptEarlier(StoredBearer(token: "kept_secret", audience: custody.audience, sessionId: "session-1",
                                          userId: "user-1", email: "peng@example.com", expiresAtEpochSeconds: 4_102_444_800))
        let (store, runtime) = try await start(server, custody: custody)

        await phase(runtime.core, "signed_in")
        await until { store.session != nil }
        XCTAssertEqual(store.session?.id, "session-1")
        XCTAssertEqual(server.requests("GET", "/v1/comma/auth/session").first?.authorization, "Bearer kept_secret")
    }

    /// A probe the server refuses ends the kept session: the person signs in again.
    func testAKeptSessionTheServerRefusesSignsOut() async throws {
        let server = FakeServer()
        server.on("GET", "/v1/comma/auth/session", status: 401, json: ["error": "unauthorized"])
        let custody = try SessionCustody(record: MemoryRecord(), apiOrigin: server.origin)
        custody.adoptEarlier(StoredBearer(token: "kept_secret", audience: custody.audience, sessionId: "session-1",
                                          userId: "user-1", email: "peng@example.com", expiresAtEpochSeconds: 4_102_444_800))
        let (store, runtime) = try await start(server, custody: custody)

        await phase(runtime.core, "signed_out")
        XCTAssertNil(store.session)
        XCTAssertNil(custody.identity())
    }

    /// A file the member attaches to the draft is uploaded to the conversation's Group at once, with its bytes.
    func testAFileAttachedToTheDraftIsUploaded() async throws {
        let server = FakeServer()
        server.on("GET", "/v1/comma/auth/session", json: session())
        server.on("POST", "/v1/comma/groups/g1/files", json: ["path": "/uploads/1", "name": "notes.txt", "size": 5])
        let custody = try SessionCustody(record: MemoryRecord(), apiOrigin: server.origin)
        custody.adoptEarlier(StoredBearer(token: "kept_secret", audience: custody.audience, sessionId: "session-1",
                                          userId: "user-1", email: "peng@example.com", expiresAtEpochSeconds: 4_102_444_800))
        let (_, runtime) = try await start(server, custody: custody)
        await phase(runtime.core, "signed_in")
        let view: [String: Any] = ["workspace": "w1", "group": "g1", "conversation": "c1", "surface": "ios"]
        var topic = view
        topic["topic"] = "chatView"
        let shown = runtime.core.subscribe(topic) { CoreJSON(value: $0) }
        let watching = Task { for await _ in shown {} }
        defer { watching.cancel() }

        var attach = view
        let photo = Data("hello".utf8) + Data(repeating: 7, count: 400_000)
        attach["files"] = [["name": "Photo.jpg", "size": photo.count, "bytes": CoreBytes.json(photo)]]
        _ = try await runtime.core.call("chatView.attach", attach)
        let upload = await server.first("POST", "/v1/comma/groups/g1/files")
        XCTAssertEqual(upload.authorization, "Bearer kept_secret")
        XCTAssertTrue(String(decoding: upload.raw, as: UTF8.self).contains("hello"))
    }
}
