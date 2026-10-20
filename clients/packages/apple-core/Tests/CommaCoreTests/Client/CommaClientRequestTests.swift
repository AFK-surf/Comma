import Foundation
import Testing
@testable import CommaCore

private func encodedQuery(_ request: URLRequest?) -> String? {
    request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
}

@Suite("Request encoding and refused input")
struct CommaClientRequestTests {
    func signedIn(_ responses: [HTTPResponse] = []) async throws -> (CommaClient, FixtureTransport) {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON)] + responses)
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        return (client, transport)
    }

    /// The server reads a bare '+' in a query as a space, so every query sends it as %2B.
    @Test func aPlusInAnyQueryArrivesAsAPlus() async throws {
        let (client, transport) = try await signedIn([response(#"{"data":[]}"#), response("{}")])
        _ = try await client.searchTasks(workspace: workspace, query: "C++ & notes=1")
        #expect(encodedQuery(await transport.requests().last) == "q=C%2B%2B%20%26%20notes%3D1&limit=20")
        _ = try? await client.recommendations(workspace: workspace, timeZone: try #require(TimeZone(identifier: "Etc/GMT+8")))
        #expect(encodedQuery(await transport.requests().last) == "timezone=Etc/GMT%2B8")
        let decoded = await transport.requests().last.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }
        #expect(decoded == [URLQueryItem(name: "timezone", value: "Etc/GMT+8")])
    }

    @Test func attachmentsWithALineBreakAreRefusedBeforeAnyRequest() async throws {
        let (client, transport) = try await signedIn()
        func file(name: String, path: String) -> ContentBlock {
            ContentBlock(type: "workspace_file", fields: ["name": .string(name), "path": .string(path), "size": .number(4)])
        }
        // "\r\n" is one Character in Swift, so only a check of its scalars finds it. The Unicode line and paragraph
        // separators and NEL start a new line too.
        for attachment in [file(name: "a\r\nb.md", path: "/files/a.md"), file(name: "a.md", path: "/files/a\r\nb.md"),
                           file(name: "a\nb.md", path: "/files/a.md"), file(name: "a.md", path: "/files/a\rb.md"),
                           file(name: "a\u{2028}b.md", path: "/files/a.md"), file(name: "a.md", path: "/files/a\u{2029}b.md"),
                           file(name: "a\u{85}b.md", path: "/files/a.md")] {
            await #expect(throws: CommaError.invalidInput("The uploaded file reference is invalid.")) {
                _ = try await client.send(target: target, text: "Read this", requestID: "r1", attachments: [attachment])
            }
        }
        await #expect(throws: CommaError.invalidInput("Skill locations are invalid.")) {
            _ = try await client.send(target: target, text: "Use it", requestID: "r2", skills: ["/skills/a\r\n/SKILL.md"])
        }
        await #expect(throws: CommaError.invalidInput("Skill locations are invalid.")) {
            _ = try await client.send(target: target, text: "Use it", requestID: "r3", skills: ["/skills/a\u{2028}/SKILL.md"])
        }
        for (name, type) in [("a\r\nb.pdf", "application/pdf"), ("a\rb.pdf", "application/pdf"), ("a\u{2028}b.pdf", "application/pdf"),
                             ("a.pdf", "application/pdf\r\nX-Evil: 1")] {
            await #expect(throws: CommaError.invalidInput("Files must be at most 10 MB with a valid name.")) {
                _ = try await client.uploadFile(workspace: workspace, filename: name, contentType: type, data: Data("pdf".utf8))
            }
        }
        #expect(await transport.requests().count == 1, "Only the session check went out")
    }

    @Test func anUploadAnswerWithALineBreakIsRefused() async throws {
        let (client, _) = try await signedIn([response(#"{"path":"/files/a\r\nb.pdf","name":"a.pdf","size":3}"#)])
        await #expect(throws: CommaError.invalidResponse) {
            _ = try await client.uploadFile(workspace: workspace, filename: "a.pdf", contentType: "application/pdf", data: Data("pdf".utf8))
        }
    }
}
