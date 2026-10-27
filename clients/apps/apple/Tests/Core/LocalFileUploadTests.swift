import Foundation
import XCTest
@testable import Comma

/// A file picked from Files uploads from disk as it is read, past the 10 MB a whole read allows, on the client core the
/// app carries and a fake Comma API.
@MainActor
final class LocalFileUploadTests: XCTestCase {
    private var directory: URL?
    private var runtime: CoreRuntime?

    override func tearDown() async throws {
        await runtime?.core.closed()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// A part of a picked file, as a station takes one (`localFiles.read`): from where it is asked, up to where it ends.
    func testAPartOfAPickedFileIsReadFromWhereItIsAsked() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Data((0 ..< 300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let picked = directory.appendingPathComponent("notes.bin")
        try bytes.write(to: picked)
        let files = HostLocalFiles(root: directory.appendingPathComponent("kept", isDirectory: true))
        let keeping = try await files.keep(picked)
        let kept = try XCTUnwrap(keeping)
        XCTAssertEqual(try files.read(kept.ref, offset: 100_000, length: 100_000), bytes.subdata(in: 100_000 ..< 200_000))
        XCTAssertEqual(try files.read(kept.ref, offset: 250_000, length: 100_000), bytes.subdata(in: 250_000 ..< 300_000))
        XCTAssertNil(try files.read("lfi1_none", offset: 0, length: 1))
    }

    func testAPickedFileOver10MBUploadsFromDisk() async throws {
        let bytes = Data((0 ..< 12_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let server = FakeServer()
        server.on("GET", "/v1/comma/auth/session", json: [
            "expires_at": 4_102_444_800, "session_id": "upload-session",
            "user": ["email": "upload@example.com", "id": "upload-user", "status": "active"],
        ])
        server.on("PUT", "/v1/comma/groups/g1/files", json: [
            "path": "/uploads/archive.zip", "name": "archive.zip", "size": bytes.count,
        ])
        let custody = try SessionCustody(record: MemoryRecord(), apiOrigin: server.origin)
        custody.adoptEarlier(StoredBearer(token: "upload-bearer", audience: custody.audience, sessionId: "upload-session",
                                          userId: "upload-user", email: "upload@example.com",
                                          expiresAtEpochSeconds: 4_102_444_800))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.directory = directory
        let downloads = directory.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let picked = directory.appendingPathComponent("archive.zip")
        try bytes.write(to: picked)
        let runtime = try CoreRuntime.make(custody: custody, dataDirectory: directory.appendingPathComponent("core"),
                                           downloadRoot: downloads, configuration: server.configuration)
        self.runtime = runtime
        let store = CommaStore(configuration: AppConfiguration(baseURL: URL(string: server.origin)!,
                                                               credentialService: "LocalFileUploadTests"),
                               runtime: runtime, workspacePreferences: UserDefaults(suiteName: UUID().uuidString)!)
        await store.start()
        _ = await runtime.core.first(["topic": "session"]) { value in
            SessionSnapshot(value).phase == "signed_in" ? true : nil
        }
        let view: [String: Any] = ["workspace": "w1", "group": "g1", "conversation": "c1", "surface": "ios"]
        var topic = view
        topic["topic"] = "chatView"
        let shown = runtime.core.subscribe(topic) { CoreJSON(value: $0) }
        let watching = Task { for await _ in shown {} }
        defer { watching.cancel() }

        let keeping = try await store.localFiles?.keep(picked)
        let kept = try XCTUnwrap(keeping)
        XCTAssertEqual(kept.size, Int64(bytes.count))
        var attach = view
        attach["files"] = [["localFileRef": kept.ref, "mediaType": "application/zip", "name": kept.name,
                            "size": kept.size]]
        _ = try await runtime.core.call("chatView.attachLocalFiles", attach)

        let upload = await server.first("PUT", "/v1/comma/groups/g1/files")
        XCTAssertEqual(upload.authorization, "Bearer upload-bearer")
        XCTAssertEqual(upload.raw, bytes)
    }
}
