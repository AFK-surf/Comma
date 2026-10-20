import SwiftUI
import CommaCore

/// What a pre-task can ask the app to do. A prompt is only staged in the router composer; the member sends it.
struct RoutineActions {
    let usePrompt: (String) -> Void
    let openTask: (String) -> Void
    let openURL: (URL) -> Void

    func perform(_ item: RecommendationItem) {
        if let task = item.linkedTaskID { openTask(task) } else if let action = item.action { perform(action) }
    }

    func perform(_ action: RecommendationAction) {
        switch action {
        case .openURL(let url, _): openURL(url)
        case .prompt(let prompt, _, let member): usePrompt(member ? Self.memberRequest(prompt) : prompt)
        }
    }

    /// A member row's prompt is their own task; the composer asks Comma for help with it in their voice.
    static func memberRequest(_ task: String) -> String {
        var words = task
        // "Decide whether…" follows "Help me" in lower case; "GitHub" or "PR" keep their case.
        if let first = words.first, first.isUppercase, words.dropFirst().prefix(while: \.isLetter).allSatisfy(\.isLowercase) {
            words = first.lowercased() + words.dropFirst()
        }
        return String(localized: "Help me \(words)")
    }
}

extension CommaStore {
    /// The pre-tasks a platform offers now. A row standing for a Task shows only while this phone knows the
    /// Task is still open.
    func preTasks(of platform: PlatformRoutine) -> [RecommendationItem] {
        platform.preTasks { id in
            // A Task this phone does not know counts as ended, as on the desktop.
            guard let task = taskSummary(id: id) else { return false }
            return task.bucket == .inProgress || task.status == "escalated"
        }
    }
}

/// What Home's routine sheet shows: one platform's pre-tasks, or the whole briefing.
enum RoutineSheetContent: Identifiable {
    case platform(PlatformRoutine)
    case briefing

    var id: String {
        switch self {
        case .platform(let platform): "platform-" + platform.id
        case .briefing: "briefing"
        }
    }
}

extension View {
    /// Presents a platform's pre-tasks or the whole briefing. The chosen pre-task acts once the sheet has gone,
    /// so the router chat or the Task it opens is never covered by a closing sheet.
    func preTaskSheet(_ content: Binding<RoutineSheetContent?>, store: CommaStore) -> some View {
        modifier(PreTaskPresenter(content: content, store: store))
    }
}

private struct PreTaskPresenter: ViewModifier {
    @Binding var content: RoutineSheetContent?
    let store: CommaStore
    @State private var chosen: (item: RecommendationItem, source: RecommendationSource?)?
    /// A Task named in the briefing's summary, opened once the sheet has gone.
    @State private var chosenTask: String?
    /// Counts prompts placed in the composer, each of which plays a light tap.
    @State private var inserts = 0
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .sheet(item: $content, onDismiss: performChosen) { shown in
                switch shown {
                case .platform(let platform): PreTaskSheet(platform: platform, store: store, choose: choose)
                case .briefing: RoutineSheet(store: store, choose: choose, openTask: chooseTask)
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: inserts)
    }

    private func choose(_ item: RecommendationItem, from source: RecommendationSource?) {
        chosen = (item, source)
        content = nil
    }

    private func chooseTask(_ id: String) {
        chosenTask = id
        content = nil
    }

    private func performChosen() {
        if let task = chosenTask {
            chosenTask = nil
            Task { await store.openTask(id: task) }
        }
        guard let (item, source) = chosen else { return }
        chosen = nil
        RoutineActions(usePrompt: { prompt in
                           inserts += 1
                           navigation.attachToRouter(ChatAttachedText(source: source?.appName, text: prompt), store: store)
                       },
                       openTask: { id in Task { await store.openTask(id: id) } },
                       openURL: { openURL($0) })
            .perform(item)
    }
}
