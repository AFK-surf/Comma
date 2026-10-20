import Foundation
import CommaCore

/// What the menus list, copied out of the store and the pane once per pass, so the rows are a pure function of
/// it and the open trigger.
struct TriggerMenuInput: Equatable {
    let tasks: [TaskSummary]
    let tasksLoading: Bool
    let skills: [Skill]
    let skillsLoading: Bool
    /// The models the router chat's @ menu starts a Task with (`MentionModelsModel`); a Task pane lists none.
    var models: [MentionModel] = []
    var modelsLoading = false
    /// The router chat offers the agent commands, as the desktop's `user_chat` does; a Task pane does not.
    let isRouter: Bool
    /// The open Task, which its own composer does not offer.
    let excludedTaskID: String?
    let text: String
}

/// One row: a Task to mention, a model to start a Task with, a skill, or an agent command.
struct TriggerMenuItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case task(conversationID: String, title: String, bucket: TaskBucket)
        /// A model's row in the list, which picks its default effort; the efforts it takes are behind it.
        case model(MentionModel)
        /// One of the choices behind a model's row: its default (nil) or a thinking effort it takes.
        case effort(MentionModel, effort: String?)
        case skill(Skill)
        case command(name: String, body: String)
    }

    let kind: Kind
    /// The desktop's row id: `task:<id>`, `model:<id>` (behind it `model:<id>:<effort>` and `model:<id>:default`),
    /// the skill id, or `salix-<command>`.
    let id: String
    let label: String
    /// The muted text after the label: a skill's description, a command's purpose.
    let detail: String?
    var candidate: ComposerMenuCandidate

    /// A row without a glyph: an agent command, or a choice behind a model's row.
    var isBare: Bool {
        switch kind {
        case .command, .effort: true
        default: false
        }
    }

    /// The model whose efforts stand behind this row, for a model's row that has any.
    var effortsBehind: MentionModel? {
        if case .model(let model) = kind, !model.efforts.isEmpty { model } else { nil }
    }
}

struct TriggerMenuSection: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let items: [TriggerMenuItem]
    /// Still loading with nothing to show yet: the section stays, with a Searching row.
    let loading: Bool
}

/// The desktop's two menus (Composer.tsx registrations): @ lists, in the router chat, the models to start a Task
/// with, then open Tasks, newest first; / lists the agent commands in the router chat, then the workspace skills.
/// Each section is ranked by the desktop filter; a settled section with no match is dropped, a loading one stays.
enum TriggerMenuSources {
    static func sections(for match: ComposerTriggerMatch, input: TriggerMenuInput) -> [TriggerMenuSection] {
        let all: [TriggerMenuSection]
        switch match.trigger {
        case .mention:
            let tasks = TriggerMenuSection(id: "tasks", title: "Tasks", items: tasks(input),
                                           loading: input.tasksLoading && input.tasks.isEmpty)
            all = input.isRouter ? [TriggerMenuSection(id: "models", title: "Start a Task with", items: modelItems(input),
                                                       loading: input.modelsLoading && input.models.isEmpty), tasks]
                : [tasks]
        case .skill:
            let skills = TriggerMenuSection(id: "workspace-skills", title: "Skills", items: skillItems(input, match: match),
                                            loading: input.skillsLoading && input.skills.isEmpty)
            all = input.isRouter ? [TriggerMenuSection(id: "salix-commands", title: "Agent commands",
                                                       items: commandItems, loading: false), skills] : [skills]
        }
        return all.compactMap { section in
            let items = ComposerMenuFilter.filter(section.items, query: match.query) { $0.candidate }
            guard !items.isEmpty || section.loading else { return nil }
            return TriggerMenuSection(id: section.id, title: section.title, items: items, loading: section.loading)
        }
    }

    /// What stands behind a model's row: its default effort, then each it takes, as the desktop's second level lists
    /// them. Nothing filters them: the query found the row.
    static func effortSections(for model: MentionModel) -> [TriggerMenuSection] {
        let items = ([nil] + model.efforts.map(Optional.some)).map { effort in
            let id = "model:\(model.id):\(effort ?? "default")"
            let label = effort ?? String(localized: "Default")
            return TriggerMenuItem(kind: .effort(model, effort: effort), id: id, label: label, detail: nil,
                                   candidate: ComposerMenuCandidate(id: id, label: label))
        }
        return [TriggerMenuSection(id: "model:\(model.id)/efforts", title: "Thinking effort", items: items, loading: false)]
    }

    /// The menu's name for VoiceOver, in the desktop's words.
    static func label(for trigger: ComposerTrigger, isRouter: Bool) -> LocalizedStringResource {
        switch trigger {
        case .mention: "Mentions"
        case .skill: isRouter ? "Commands and skills" : "Skills"
        }
    }

    /// The desktop's agent commands: each reads `/body` in the field and goes as its control text, which the agent
    /// runs instead of replying.
    static let commands: [(name: String, body: String, description: LocalizedStringResource)] = [
        ("status", "status", "Show model and context usage"),
        ("compact", "compact", "Summarize session context"),
        ("help", "help", "Show supported commands"),
        ("ls", "ls /", "List workspace files (requires VFS access)"),
        ("cat", "cat " + AgentCommand.placeholderPath, "Read a file — edit the path first (requires VFS access)"),
    ]

    /// Open, unarchived, titled Tasks other than the open one, most recently updated first.
    private static func tasks(_ input: TriggerMenuInput) -> [TriggerMenuItem] {
        let open = input.tasks.enumerated().filter { _, task in
            !task.isArchived && task.id != input.excludedTaskID
                && !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let newest = open.sorted { a, b in
            let (left, right) = (a.element.updatedAt, b.element.updatedAt)
            return left != right ? left > right : a.offset < b.offset
        }
        return newest.map { _, task in
            TriggerMenuItem(kind: .task(conversationID: task.id, title: task.title, bucket: task.bucket),
                            id: "task:" + task.id, label: task.title, detail: nil,
                            candidate: ComposerMenuCandidate(id: "task:" + task.id, label: task.title))
        }
    }

    /// The models the Workspace can run, in the core's order; the filter reads the name and the id, as the desktop's
    /// does.
    private static func modelItems(_ input: TriggerMenuInput) -> [TriggerMenuItem] {
        input.models.map { model in
            TriggerMenuItem(kind: .model(model), id: "model:" + model.id, label: model.name, detail: nil,
                            candidate: ComposerMenuCandidate(id: "model:" + model.id, label: model.name, keywords: [model.id]))
        }
    }

    /// Skills not picked elsewhere in the draft. The one being typed stays listed, unlike on the desktop, so a
    /// fully typed id still shows the row it would pick. A skill without a description shows no detail: the desktop
    /// shows its location instead, an internal path that means nothing on a phone. The filter still reads the
    /// location as the desktop's does, so a query finds the same rows. Miniskills (`per-message`) attach
    /// automatically per message and are not listed.
    private static func skillItems(_ input: TriggerMenuInput, match: ComposerTriggerMatch) -> [TriggerMenuItem] {
        var rest = input.text
        if let typed = ComposerTrigger.validated(match.range, in: rest) { rest.removeSubrange(typed) }
        let mentioned = Set(Skill.mentionedLocations(in: rest, catalog: input.skills))
        return input.skills.filter { $0.activation != "per-message" && !mentioned.contains($0.location) }.map { skill in
            let detail = skill.description.flatMap { $0.isEmpty ? nil : $0 }
            return TriggerMenuItem(kind: .skill(skill), id: skill.skillID, label: skill.name, detail: detail,
                                   candidate: ComposerMenuCandidate(id: skill.skillID, label: skill.name,
                                                                    searchText: skill.skillID,
                                                                    description: detail ?? skill.location))
        }
    }

    private static var commandItems: [TriggerMenuItem] {
        commands.map { command in
            let detail = String(localized: command.description)
            return TriggerMenuItem(kind: .command(name: command.name, body: command.body), id: "salix-" + command.name,
                                   label: "/" + command.name, detail: detail,
                                   candidate: ComposerMenuCandidate(id: "salix-" + command.name, label: "/" + command.name,
                                                                    searchText: "salix-command " + command.name,
                                                                    description: detail))
        }
    }
}
