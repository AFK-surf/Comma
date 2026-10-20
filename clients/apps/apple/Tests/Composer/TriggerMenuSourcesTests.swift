import XCTest
import CommaCore
@testable import Comma

/// The composer's @ and / menus as the desktop builds them: which Tasks, agent commands and skills each lists, in
/// what order, and when a section shows that it is still searching.
final class TriggerMenuSourcesTests: XCTestCase {
    private let skills = [
        Skill(skillID: "pdf", name: "PDF", location: "/.runtime/skills/pdf/SKILL.md", source: "imported"),
        Skill(skillID: "frontend-design", name: "Frontend design", description: "Build polished interfaces",
              location: "/.runtime/skills/frontend-design/SKILL.md", source: "system"),
    ]

    private func task(_ id: String, title: String? = nil, section: String = "in_progress", updated: Double = 0) -> TaskSummary {
        .listed(id, title: title, section: section, updatedAt: updated)
    }

    private func sections(_ text: String, tasks: [TaskSummary] = [], tasksLoading: Bool = false, skills: [Skill]? = nil,
                          skillsLoading: Bool = false, isRouter: Bool = true, excluding: String? = nil) throws -> [TriggerMenuSection] {
        let match = try XCTUnwrap(ComposerTrigger.match(in: text, selection: nil))
        let input = TriggerMenuInput(tasks: tasks, tasksLoading: tasksLoading, skills: skills ?? self.skills,
                                     skillsLoading: skillsLoading, isRouter: isRouter, excludedTaskID: excluding, text: text)
        return TriggerMenuSources.sections(for: match, input: input)
    }

    private func ids(_ sections: [TriggerMenuSection]) -> [[String]] { sections.map { $0.items.map(\.id) } }

    func testMentionListsOpenTasksNewestFirstWithoutTheCurrentTask() throws {
        let tasks = [task("a", updated: 10), task("b", updated: 30), task("open", updated: 50), task("c", updated: 30), task("d")]
        let result = try sections("Ask @", tasks: tasks, excluding: "open")
        XCTAssertEqual(result.map(\.id), ["tasks"])
        XCTAssertEqual(ids(result), [["task:b", "task:c", "task:a", "task:d"]], "Ties keep the list's order")
        XCTAssertEqual(result.first?.items.first?.kind, .task(conversationID: "b", title: "Task b", bucket: .inProgress))
    }

    func testMentionFiltersByTitleAndID() throws {
        let tasks = [task("task29", title: "Ship 29"), task("x1", title: "Write notes"), task("abc", title: "Plan 290")]
        XCTAssertEqual(ids(try sections("@wri", tasks: tasks)), [["task:x1"]])
        XCTAssertEqual(ids(try sections("@29", tasks: tasks)), [["task:task29", "task:abc"]])
        XCTAssertEqual(ids(try sections("@task29", tasks: tasks)), [["task:task29"]], "The row id counts, as on the desktop")
        XCTAssertEqual(ids(try sections("@WRITE", tasks: tasks)), [["task:x1"]])
    }

    func testArchivedAndUntitledTasksAreSkipped() throws {
        let tasks = [task("archived", section: "archived"), task("blank", title: " \n "), task("ok")]
        XCTAssertEqual(ids(try sections("@", tasks: tasks)), [["task:ok"]])
    }

    func testNoMatchesGiveNoSections() throws {
        XCTAssertTrue(try sections("@zzz", tasks: [task("a")]).isEmpty)
        XCTAssertTrue(try sections("/zzz").isEmpty, "Settled sections with no match are dropped")
    }

    func testRouterSlashMenuStartsWithAgentCommands() throws {
        let result = try sections("/")
        XCTAssertEqual(result.map(\.id), ["salix-commands", "workspace-skills"])
        XCTAssertEqual(ids(result), [["salix-status", "salix-compact", "salix-help", "salix-ls", "salix-cat"],
                                     ["pdf", "frontend-design"]])
        let ls = try XCTUnwrap(result.first?.items.first { $0.id == "salix-ls" })
        XCTAssertEqual(ls.kind, .command(name: "ls", body: "ls /"))
        XCTAssertEqual(ls.label, "/ls")
        XCTAssertEqual(ids(try sections("/comp")), [["salix-compact"]])
        XCTAssertEqual(ids(try sections("/polish")), [["frontend-design"]], "A skill's description counts last")
    }

    func testTaskPaneHasNoAgentCommands() throws {
        let result = try sections("/", isRouter: false)
        XCTAssertEqual(result.map(\.id), ["workspace-skills"])
        XCTAssertEqual(result.first?.items.map(\.detail), [nil, "Build polished interfaces"],
                       "A skill without a description shows no detail, never its runtime path")
        XCTAssertEqual(ids(try sections("/skill.md", isRouter: false)), [["pdf"]], "The filter still reads it, as the desktop's does")
    }

    func testMiniskillsAreNotListed() throws {
        let miniskill = Skill(skillID: "taobao", name: "Taobao", location: "/.runtime/skills/taobao/SKILL.md",
                              activation: "per-message")
        XCTAssertEqual(ids(try sections("/", skills: skills + [miniskill], isRouter: false)), [["pdf", "frontend-design"]])
        XCTAssertTrue(try sections("/taobao", skills: skills + [miniskill], isRouter: false).isEmpty)
    }

    func testSkillAlreadyInDraftIsHidden() throws {
        XCTAssertEqual(ids(try sections("/pdf summarize /", isRouter: false)), [["frontend-design"]])
    }

    func testSkillBeingTypedStaysVisible() throws {
        XCTAssertEqual(ids(try sections("/pdf")), [["pdf"]])
    }

    func testSkillsLoadingShowsSearching() throws {
        let searching = try sections("/", skills: [], skillsLoading: true, isRouter: false)
        XCTAssertEqual(searching.map(\.id), ["workspace-skills"])
        XCTAssertEqual(searching.first?.loading, true)
        XCTAssertEqual(searching.first?.items.count, 0)
        XCTAssertEqual(try sections("/", skillsLoading: true, isRouter: false).first?.loading, false,
                       "A refresh behind a loaded catalog shows the catalog")
        XCTAssertEqual(try sections("@", tasksLoading: true).first?.loading, true)
    }
}
