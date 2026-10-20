import Foundation
import Testing
@testable import CommaCore

/// The Workspace skills catalog and the desktop's `deriveMentionedSkills`.
@Suite("Workspace skills")
struct SkillTests {
    private func skill(_ id: String) -> Skill {
        Skill(skillID: id, name: id, location: "/.runtime/skills/\(id)/SKILL.md")
    }

    private let catalogJSON = """
    {"data":[
     {"skill_id":"frontend-design","name":"Frontend design","description":"Build polished interfaces",
      "location":"/.runtime/skills/frontend-design/SKILL.md","source":"system","activation":"regular","extra":{"x":1}},
     {"skill_id":"pdf","name":"PDF","description":null,"location":"/.runtime/skills/pdf/SKILL.md","source":"imported"},
     {"skill_id":"release-notes","name":"Release notes","location":"/.runtime/skills/release-notes/SKILL.md",
      "activation":"per-message"}
    ],"has_more":false}
    """

    @Test func decodesServerProjection() throws {
        let page = try JSONDecoder().decode(Page<Skill>.self, from: Data(catalogJSON.utf8))
        #expect(page.data.map(\.id) == ["frontend-design", "pdf", "release-notes"])
        #expect(page.data[0] == Skill(skillID: "frontend-design", name: "Frontend design", description: "Build polished interfaces",
                                      location: "/.runtime/skills/frontend-design/SKILL.md", source: "system", activation: "regular"))
        #expect(page.data[1].description == nil && page.data[1].source == "imported" && page.data[1].activation == nil)
        #expect(page.data[2].source == nil && page.data[2].activation == "per-message")
    }

    @Test func mentionedLocationsMatchDesktop() {
        let catalog = [skill("pdf"), skill("frontend-design"), skill("release-notes")]
        #expect(Skill.mentionedLocations(in: "/PDF then /frontend-design", catalog: catalog)
                == ["/.runtime/skills/pdf/SKILL.md", "/.runtime/skills/frontend-design/SKILL.md"])
        #expect(Skill.mentionedLocations(in: "a/pdf", catalog: catalog).isEmpty, "Inside a word")
        #expect(Skill.mentionedLocations(in: "/pdf and /pdf again\n/pdf", catalog: catalog) == ["/.runtime/skills/pdf/SKILL.md"])
        #expect(Skill.mentionedLocations(in: "/unknown /pdf-extra /pdf.", catalog: catalog) == ["/.runtime/skills/pdf/SKILL.md"],
                "Unknown ids are ignored and the id runs to the end of the token")
        #expect(Skill.mentionedLocations(in: "你好\u{3000}/release-notes", catalog: catalog) == ["/.runtime/skills/release-notes/SKILL.md"])
        #expect(Skill.mentionedLocations(in: "/pdf", catalog: []).isEmpty)
        #expect(Skill.mentionedLocations(in: "no skills", catalog: catalog).isEmpty)
        let many = (1...11).map { skill("s\($0)") }
        let all = many.map { "/" + $0.skillID }.joined(separator: " ")
        #expect(Skill.mentionedLocations(in: all, catalog: many) == many.prefix(Skill.maxMentions).map(\.location))
    }

    @Test func skillsReadTheWorkspaceCatalog() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response(catalogJSON)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        let skills = try await client.skills(workspace: workspace)
        #expect(skills.map(\.skillID) == ["frontend-design", "pdf", "release-notes"])
        let request = try #require(await transport.requests().last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v1/comma/workspaces/w1/skills")
        #expect(request.url?.query == nil)
    }

    @Test func skillsReportTheServerRefusal() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response("{\"error\":\"forbidden\"}", status: 403)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        await #expect(throws: CommaError.http(status: 403, code: "forbidden", retryAfter: nil)) {
            try await client.skills(workspace: workspace)
        }
    }
}
