import SwiftUI
import XCTest
import CommaCore
@testable import Comma

/// A model picked from the router chat's @ menu (desktop #3785): the models the menu lists and how it filters them, the
/// efforts behind a model's row, the `[GPT 5.5 · high](comma:model/<id>?effort=high)` the pick sends and saves, and
/// the `@GPT 5.5 · high` a sent one reads as.
@MainActor
final class ModelMentionTests: XCTestCase {
    private let gpt = MentionModel(id: "gpt-5.5", name: "GPT 5.5", vendor: "openai", efforts: ["low", "medium", "high"])
    private let opus = MentionModel(id: "claude-opus-5", name: "Claude Opus 5", vendor: "anthropic", efforts: [])

    // MARK: Wire text

    func testTravelsAsADesktopLinkAndReadsAsItsName() throws {
        let plain = try XCTUnwrap(ModelMention(name: "GPT 5.5", modelID: "gpt-5.5"))
        XCTAssertEqual(plain.wireText, "[GPT 5.5](comma:model/gpt-5.5)")
        XCTAssertEqual(plain.displayText, "@GPT 5.5")
        let effortful = try XCTUnwrap(ModelMention(name: ModelMention.shownName("GPT 5.5", effort: "high"),
                                                   modelID: "gpt-5.5", effort: "high"))
        XCTAssertEqual(effortful.wireText, "[GPT 5.5 · high](comma:model/gpt-5.5?effort=high)")
        XCTAssertEqual(effortful.displayText, "@GPT 5.5 · high")
        XCTAssertEqual(ModelMention(name: "  GPT [5.5]\n beta ", modelID: "gpt-5.5")?.label, "GPT (5.5) beta",
                       "Brackets and whitespace as the desktop's label")
        XCTAssertEqual(ModelMention(name: " ", modelID: "org/model@v2:1")?.label, "org/model@v2:1", "A blank name falls back to the id")

        for id in ["", "-gpt", "gpt 5", "gpt(5)", "gpt\n"] { XCTAssertNil(ModelMention(name: "X", modelID: id), id) }
        for effort in ["", "High", "x-high", "high\n"] {
            XCTAssertNil(ModelMention(name: "X", modelID: "gpt", effort: effort), effort)
        }
    }

    func testSavedLinksReadBackAsPicks() throws {
        let saved = "Draft [GPT 5.5 · high](comma:model/gpt-5.5?effort=high) and [Opus](comma:model/claude-opus-5) [x](comma:model/-bad)"
        let projected = ModelMention.project(saved)
        XCTAssertEqual(projected.text, "Draft @GPT 5.5 · high and @Opus [x](comma:model/-bad)", "A link the pattern does not read stays")
        XCTAssertEqual(projected.models, [ModelMention(name: "GPT 5.5 · high", modelID: "gpt-5.5", effort: "high"),
                                          ModelMention(name: "Opus", modelID: "claude-opus-5")])
        XCTAssertEqual(ModelMention.serialize(projected.text, models: projected.models), saved)
        XCTAssertEqual(ModelMention.project("no mention").text, "no mention")
    }

    func testASentMentionReadsAsItsNameAndOpensNothing() throws {
        let text = MessageBubbles.inline("Review it [GPT 5.5 · high](comma:model/gpt-5.5?effort=high) and [docs](https://comma.surf)")
        XCTAssertEqual(String(text.characters), "Review it @GPT 5.5 · high and docs")
        let links = text.runs[\.link].compactMap { link, _ in link?.absoluteString }
        XCTAssertEqual(links, ["https://comma.surf"], "The model's link is gone; other links stay")
        let semibold = text.runs[AttributeScopes.SwiftUIAttributes.FontAttribute.self]
            .filter { $0.0 == CommaTheme.messageFont.weight(.semibold) }
            .map { String(text[$0.1].characters) }
        XCTAssertEqual(semibold, ["@GPT 5.5 · high"], "It stands out as a Task mention does")
        XCTAssertEqual(String(MessageBubbles.inline("[Opus](comma:model/claude-opus-5) go").characters), "@Opus go")

        let flight = OutgoingFlightController()
        flight.launch(id: "s1", text: "[GPT 5.5](comma:model/gpt-5.5) draft it", radius: 20)
        XCTAssertEqual(flight.flight.map { String($0.text.characters) }, "@GPT 5.5 draft it", "The send flight reads the same")
    }

    // MARK: The models listed

    func testOnlyModelsAProfileServesAreListed() {
        let value: NSDictionary = [
            "catalog": ["models": []],
            "models": [
                ["id": "gpt-5.5", "name": "GPT 5.5", "vendor": "openai", "efforts": ["low", "high"], "serving": ["p1"]],
                ["id": "unserved", "name": "Nobody's", "vendor": "x", "efforts": [], "serving": []],
                ["id": "claude-opus-5", "name": "Claude Opus 5", "vendor": "anthropic", "efforts": [], "serving": ["p1", "p2"]],
                ["id": "broken", "name": "No serving field", "vendor": "x", "efforts": []],
            ],
            "error": false,
        ]
        XCTAssertEqual(MentionModelsModel.models(value),
                       [MentionModel(id: "gpt-5.5", name: "GPT 5.5", vendor: "openai", efforts: ["low", "high"]),
                        MentionModel(id: "claude-opus-5", name: "Claude Opus 5", vendor: "anthropic", efforts: [])])
        XCTAssertNil(MentionModelsModel.models(["catalog": NSNull(), "models": [], "error": false]), "Still reading")
        XCTAssertEqual(MentionModelsModel.models(["catalog": NSNull(), "models": [], "error": true]), [], "A failed read lists none")
    }

    /// The models are read once, for the Workspace, from the first time the router's @ menu asks.
    func testTheModelsTopicIsFollowedOncePerWorkspace() async throws {
        let harness = try StoreHarness()
        harness.core.serve("models") { _ in
            ["catalog": ["models": []], "error": false,
             "models": [["id": "gpt-5.5", "name": "GPT 5.5", "vendor": "openai", "efforts": [], "serving": ["p1"]]]]
        }
        let store = harness.store
        await harness.start()
        defer { store.suspend() }
        XCTAssertTrue(harness.core.topics("models").isEmpty, "Nothing is read before the menu opens")
        store.mentionModels.follow(store: store)
        store.mentionModels.follow(store: store)
        await until { !store.mentionModels.loading }
        XCTAssertEqual(store.mentionModels.catalog.map(\.id), ["gpt-5.5"])
        XCTAssertEqual(harness.core.topics("models").map { $0["prefer"] as? String }, ["w1"])
    }

    private func sections(_ text: String, models: [MentionModel]? = nil, modelsLoading: Bool = false,
                          isRouter: Bool = true) throws -> [TriggerMenuSection] {
        let match = try XCTUnwrap(ComposerTrigger.match(in: text, selection: nil))
        let tasks = [TaskSummary.listed("t1", title: "GPT rollout", section: "in_progress", updatedAt: 0)]
        let input = TriggerMenuInput(tasks: tasks, tasksLoading: false, skills: [], skillsLoading: false,
                                     models: models ?? [gpt, opus], modelsLoading: modelsLoading, isRouter: isRouter,
                                     excludedTaskID: nil, text: text)
        return TriggerMenuSources.sections(for: match, input: input)
    }

    func testTheRouterMenuListsModelsBeforeTasksFilteredByNameAndID() throws {
        let all = try sections("@")
        XCTAssertEqual(all.map(\.id), ["models", "tasks"])
        XCTAssertEqual(all.first?.items.map(\.id), ["model:gpt-5.5", "model:claude-opus-5"])
        XCTAssertEqual(all.first?.items.first?.kind, .model(gpt))
        XCTAssertEqual(try sections("@gpt").map { $0.items.map(\.id) }, [["model:gpt-5.5"], ["task:t1"]])
        XCTAssertEqual(try sections("@OPUS").map { $0.items.map(\.id) }, [["model:claude-opus-5"]])
        XCTAssertEqual(try sections("@claude-opus").map { $0.items.map(\.id) }, [["model:claude-opus-5"]], "The id counts")
        XCTAssertEqual(try sections("@", isRouter: false).map(\.id), ["tasks"], "A Task's own composer starts no Task")
        let reading = try sections("@", models: [], modelsLoading: true)
        XCTAssertEqual(reading.map(\.id), ["models", "tasks"])
        XCTAssertEqual(reading.first?.loading, true, "Searching while the first read is in flight")
        XCTAssertEqual(try sections("@", models: []).map(\.id), ["tasks"], "No model to list, no section")
    }

    func testEffortsStandBehindAModelsRow() throws {
        let rows = try XCTUnwrap(try sections("@").first?.items)
        XCTAssertEqual(rows.map { $0.effortsBehind?.id }, ["gpt-5.5", nil], "Only a model with efforts has a second level")
        let efforts = TriggerMenuSources.effortSections(for: gpt)
        XCTAssertEqual(efforts.map(\.id), ["model:gpt-5.5/efforts"])
        XCTAssertEqual(efforts.first?.items.map(\.id),
                       ["model:gpt-5.5:default", "model:gpt-5.5:low", "model:gpt-5.5:medium", "model:gpt-5.5:high"])
        XCTAssertEqual(efforts.first?.items.map(\.label), [String(localized: "Default"), "low", "medium", "high"])
        XCTAssertEqual(efforts.first?.items.last?.kind, .effort(gpt, effort: "high"))
    }

    // MARK: Picking

    private func pane() throws -> ConversationPane {
        ConversationPane(kind: .router, workspace: Workspace(id: "w1", groupID: "g1", name: "W"), conversationID: "router",
                         store: try StoreHarness().store)
    }

    private func type(_ text: String, into pane: ConversationPane, model: TriggerMenuModel) {
        let old = pane.draftText
        model.textBinding(for: pane).wrappedValue = text
        model.selectionBinding(for: pane).wrappedValue = TextSelection(insertionPoint: text.endIndex)
        model.textDidChange(from: old, to: text, pane: pane)
    }

    private func row(_ model: MentionModel) throws -> TriggerMenuItem {
        try XCTUnwrap(try sections("@").first?.items.first { $0.kind == .model(model) })
    }

    func testAPickedModelReadsAsItsPillAndGoesAsItsLink() throws {
        let pane = try pane(), menu = TriggerMenuModel()
        type("Draft the notes @gp", into: pane, model: menu)
        menu.choose(try row(gpt), pane: pane)
        XCTAssertEqual(pane.draftText, "Draft the notes @GPT 5.5 ")
        XCTAssertEqual(pane.outgoingDraft, "Draft the notes [GPT 5.5](comma:model/gpt-5.5) ", "A row picks the default effort")
        XCTAssertEqual(pane.pickRanges(in: pane.draftText).map { String(pane.draftText[$0]) }, ["@GPT 5.5"])

        type(pane.draftText + "then @op", into: pane, model: menu)
        menu.choose(try row(opus), pane: pane)
        XCTAssertEqual(pane.outgoingDraft,
                       "Draft the notes [GPT 5.5](comma:model/gpt-5.5) then [Claude Opus 5](comma:model/claude-opus-5) ")
    }

    func testAnEffortPickedBehindTheRowTravelsWithIt() throws {
        let pane = try pane(), menu = TriggerMenuModel()
        type("Review it @gpt", into: pane, model: menu)
        XCTAssertNil(menu.effortsShown(in: pane.draftText))
        menu.showEfforts(of: try row(opus), in: pane.draftText)
        XCTAssertNil(menu.effortsShown(in: pane.draftText), "A model without efforts has nothing behind it")
        menu.showEfforts(of: try row(gpt), in: pane.draftText)
        XCTAssertEqual(menu.effortsShown(in: pane.draftText), "gpt-5.5")
        menu.closeEfforts()
        XCTAssertNil(menu.effortsShown(in: pane.draftText), "Back shows the list again")
        menu.showEfforts(of: try row(gpt), in: pane.draftText)
        type("Review it @gpt-", into: pane, model: menu)
        XCTAssertNil(menu.effortsShown(in: pane.draftText), "Typing returns to the list")
        type("Review it @gpt", into: pane, model: menu)
        XCTAssertNil(menu.effortsShown(in: pane.draftText))

        menu.showEfforts(of: try row(gpt), in: pane.draftText)
        let high = try XCTUnwrap(TriggerMenuSources.effortSections(for: gpt).first?.items.last)
        menu.choose(high, pane: pane)
        XCTAssertEqual(pane.draftText, "Review it @GPT 5.5 · high ")
        XCTAssertEqual(pane.outgoingDraft, "Review it [GPT 5.5 · high](comma:model/gpt-5.5?effort=high) ")
        XCTAssertNil(menu.match(in: pane.draftText), "The pick closes the menu")

        type(pane.draftText + "@gpt", into: pane, model: menu)
        menu.showEfforts(of: try row(gpt), in: pane.draftText)
        let preset = try XCTUnwrap(TriggerMenuSources.effortSections(for: gpt).first?.items.first)
        menu.choose(preset, pane: pane)
        XCTAssertEqual(pane.outgoingDraft,
                       "Review it [GPT 5.5 · high](comma:model/gpt-5.5?effort=high) [GPT 5.5](comma:model/gpt-5.5) ",
                       "Default goes without an effort")
    }

    func testBackspaceAtTheEndOfAModelTakesItWhole() throws {
        let pane = try pane(), menu = TriggerMenuModel()
        type("ask @", into: pane, model: menu)
        menu.choose(try row(gpt), pane: pane)
        type("ask @GPT 5.5", into: pane, model: menu)
        XCTAssertEqual(pane.draftText, "ask @GPT 5.5", "Deleting the space after it is an ordinary edit")
        type("ask @GPT 5.", into: pane, model: menu)
        XCTAssertEqual(pane.draftText, "ask ")
        XCTAssertTrue(pane.draftModels.isEmpty)
        XCTAssertEqual(pane.outgoingDraft, "ask ")
    }

    /// A Task and a model whose names start alike: the longer one picked is read first, whichever kind it is.
    func testTasksAndModelsAreMatchedTogether() throws {
        let pane = try pane()
        let task = try XCTUnwrap(TaskMention(title: "GPT 5.5 review", conversationID: "t1"))
        let model = try XCTUnwrap(ModelMention(name: "GPT 5.5", modelID: "gpt-5.5"))
        pane.draftText = "\(model.displayText) see \(task.displayText) now"
        pane.draftMentions = [task]
        pane.draftModels = [model]
        XCTAssertEqual(pane.outgoingDraft, "[GPT 5.5](comma:model/gpt-5.5) see [GPT 5.5 review](comma:task/t1) now")
        pane.draftText = "\(task.displayText) then \(model.displayText)"
        XCTAssertEqual(pane.outgoingDraft, "[GPT 5.5 review](comma:task/t1) then [GPT 5.5](comma:model/gpt-5.5)")
    }

    // MARK: Sending and saving

    func testSendCarriesTheLinkAndASavedDraftComesBackAsThePick() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await harness.start()
        defer { store.suspend() }
        let router = try XCTUnwrap(store.router.pane)
        await until { router.state.loaded }
        let model = try XCTUnwrap(ModelMention(name: "GPT 5.5 · high", modelID: "gpt-5.5", effort: "high"))
        router.draftText = "\(model.displayText) draft the launch notes"
        router.draftModels = [model]
        let attempt = try XCTUnwrap(router.enqueueSend())
        await router.deliver(attempt)
        XCTAssertEqual(harness.core.calls("chatView.send").last?["text"] as? String,
                       "[GPT 5.5 · high](comma:model/gpt-5.5?effort=high) draft the launch notes")
        XCTAssertTrue(router.draftModels.isEmpty)

        harness.core.serve("chatView") { _ in nil }
        await store.openTask(id: "task")
        let pane = try XCTUnwrap(store.task)
        harness.core.publish("chatView", matching: ["conversation": "task"], [
            "revision": 1,
            "state": ["status": "ready", "draft": "Try [GPT 5.5](comma:model/gpt-5.5) and [Fix](comma:task/cnv1_fix)",
                      "conversation": ["id": "task"]],
        ])
        await until { pane.state.loaded }
        XCTAssertEqual(pane.draftText, "Try @GPT 5.5 and @Fix")
        XCTAssertEqual(pane.draftModels.map(\.modelID), ["gpt-5.5"])
        XCTAssertEqual(pane.outgoingDraft, "Try [GPT 5.5](comma:model/gpt-5.5) and [Fix](comma:task/cnv1_fix)")
    }
}
