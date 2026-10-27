import Foundation
import XCTest
@testable import Comma

/// A message attachment over the 10 MB a whole read allows, downloaded by the client core the app carries into its
/// download directory and opened from there, against a fake Comma API.
@MainActor
final class AttachmentDownloadCoreTests: XCTestCase {
    private var directory: URL?
    private var runtime: CoreRuntime?

    override func tearDown() async throws {
        await runtime?.core.closed()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// The parts the core read itself (a file of a Task a station hosts) take their place as a download does.
    func testPartsTheCoreReadTakeTheirPlaceAsADownloadDoes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.directory = directory
        let downloads = HostDownloads(root: directory.appendingPathComponent("downloads", isDirectory: true))
        let bytes = Data((0 ..< 70_000).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        let id = try downloads.create("account/key/shot.png")
        XCTAssertEqual(try downloads.append(id, bytes.prefix(40_000))["received"] as? Int64, 40_000)
        XCTAssertEqual(try downloads.append(id, bytes.suffix(30_000))["received"] as? Int64, 70_000)
        let saved = try downloads.finish(id)
        XCTAssertEqual(saved["size"] as? Int64, Int64(bytes.count))
        XCTAssertEqual((saved["sha256"] as? String)?.count, 64)
        let file = try XCTUnwrap(downloads.file("account/key/shot.png"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["shot.png"])
        XCTAssertThrowsError(try downloads.create("../outside.png"))
        // Given up part way, nothing of it stays.
        let givenUp = try downloads.create("account/key/b.bin")
        _ = try downloads.append(givenUp, bytes)
        downloads.close(givenUp)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["shot.png"])
    }

    func testAnAttachmentOver10MBDownloadsWholeIntoTheDownloadDirectory() async throws {
        let video = Data((0 ..< 12_000_000).map { UInt8(truncatingIfNeeded: $0) })
        let server = FakeServer()
        server.on("GET", "/v1/comma/auth/session", json: [
            "expires_at": 4_102_444_800, "session_id": "download-session",
            "user": ["email": "download@example.com", "id": "download-user", "status": "active"],
        ])
        server.on("GET", "/v1/comma/groups/g/conversations/c/messages/m/attachments/1") { _ in (200, video) }
        let custody = try SessionCustody(record: MemoryRecord(), apiOrigin: server.origin)
        custody.adoptEarlier(StoredBearer(token: "download-bearer", audience: custody.audience,
                                          sessionId: "download-session", userId: "download-user",
                                          email: "download@example.com", expiresAtEpochSeconds: 4_102_444_800))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.directory = directory
        let downloads = directory.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let runtime = try CoreRuntime.make(custody: custody, dataDirectory: directory.appendingPathComponent("core"),
                                           downloadRoot: downloads, configuration: server.configuration)
        self.runtime = runtime
        let store = CommaStore(configuration: AppConfiguration(baseURL: URL(string: server.origin)!,
                                                               credentialService: "AttachmentDownloadCoreTests"),
                               runtime: runtime, workspacePreferences: UserDefaults(suiteName: UUID().uuidString)!)
        await store.start()
        // The kept account shows while the core checks it; requests go out once its lifecycle confirms the session.
        let phases = runtime.core.subscribe(["topic": "session"]) { value in
            ((value as? NSDictionary)?["lifecycle"] as? NSDictionary)?["phase"] as? String
        }
        for await phase in phases {
            if case .value("signed_in") = phase { break }
        }

        let path = try await AttachmentDownload.path(
            core: runtime.core,
            source: ["source": "attachment", "group": "g", "conversation": "c", "message": "m", "index": 1],
            name: "clip.mp4")

        let file = try XCTUnwrap(store.downloadedFile(path))
        XCTAssertEqual(file.lastPathComponent, "clip.mp4")
        XCTAssertTrue(file.path.hasPrefix(downloads.standardizedFileURL.path))
        XCTAssertEqual(try Data(contentsOf: file), video)
        let read = try XCTUnwrap(server.requests("GET", "/v1/comma/groups/g/conversations/c/messages/m/attachments/1").first)
        XCTAssertEqual(read.authorization, "Bearer download-bearer")
    }
}
