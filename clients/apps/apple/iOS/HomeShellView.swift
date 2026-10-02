import SwiftUI
import UIKit
import CommaCore

/// Home chat is the root and the task sidebar opens over it at full width. An open Task lives in a
/// bottom dock that behaves like a Telegram mini app: minimized, a bar with close, title and status sits
/// at the bottom edge and the app ends above it as a card over a black gap; dragging the bar follows the
/// finger up into a full sheet over the app.
/// Home and the Task keep their own panes, so neither reloads.
struct HomeShellView: View {
    @Bindable var store: CommaStore
    @ObservedObject var activity: TaskActivityCoordinator
    @State private var settingsOpen = false
    @State private var homeDismissRequest = 0
    @State private var keyboardVisible = false
    /// The Task sheet has finished rising. Until then Home keeps its full height under the rising sheet,
    /// so making room for the bar never shows as a jump while the sheet opens.
    @State private var dockSettled = false

    static let barHeight: CGFloat = TaskDockViewController.barHeight
    static let gap: CGFloat = 6

    var body: some View {
        let taskPane = store.task
        let docked = taskPane != nil
        let reservesBar = docked && dockSettled
        ZStack(alignment: .bottom) {
            // The keyboard's transparent corners reveal this canvas. Black belongs to the Task gap.
            (reservesBar && !keyboardVisible ? Color.black : CommaTheme.bgPrimary).ignoresSafeArea()
            HomeCardHost(bottomInset: reservesBar && !keyboardVisible ? Self.barHeight + Self.gap : 0,
                         rounded: reservesBar) {
                HomeShellContent(store: store, dismissRequest: homeDismissRequest,
                                 openSettings: { settingsOpen = true })
            }
                // Reach the screen edges so the navigation bar can merge into a system vertical bar.
                .ignoresSafeArea(.container)
            ZStack {
                if let pane = taskPane {
                    TaskDockHost(store: store, pane: pane, revealRequest: store.taskRevealRequest,
                                 onExpand: { homeDismissRequest += 1 },
                                 onSettled: { dockSettled = true },
                                 onDismissing: { dockSettled = false })
                        // Each opened Task gets its own dock, never one still fading out from a close.
                        .id(ObjectIdentifier(pane))
                        // The close button slides the sheet away itself; any other close (sign-out, a route) fades.
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                }
            }
            .ignoresSafeArea()
            .animation(CommaMotion.railFold, value: docked)
        }
        .onChange(of: docked) { _, docked in if !docked { dockSettled = false } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .sheet(isPresented: $settingsOpen) {
            AccountView(store: store, activity: activity)
        }
    }
}

/// The task sidebar and Home chat. The drawer state lives here, inside the card's hosting
/// controller: an animation started in `HomeShellView` would not cross into that controller.
private struct HomeShellContent: View {
    @Bindable var store: CommaStore
    let dismissRequest: Int
    let openSettings: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// 0 closed, 1 open. The sidebar follows the finger while dragging.
    @State private var drawerProgress: CGFloat = 0
    @State private var dragStart: CGFloat?
    /// The settled drawer state; a change plays the open/close haptic, a drag that springs back does not.
    @State private var drawerOpen = false

    var body: some View { shell(home: store.home) }

    @ViewBuilder private func shell(home: ConversationPane?) -> some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                TaskSidebarView(store: store, openSettings: openSettings, openTask: open, goHome: nil)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
                    .toolbar(.hidden, for: .navigationBar)
            } detail: { chat(home: home) }
            .ignoresSafeArea(.container, edges: .horizontal)
        } else {
            compactShell(home: home)
        }
    }

    private func open(_ task: Conversation) {
        setDrawer(false)
        Task { await store.openTask(id: task.id) }
    }

    // MARK: Full-width sidebar

    private func compactShell(home: ConversationPane?) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                TaskSidebarView(store: store, openSettings: openSettings, openTask: open,
                                goHome: { setDrawer(false) })
                    .frame(width: width)
                    .offset(x: -width * 0.25 * (1 - drawerProgress))
                    .opacity(0.4 + 0.6 * drawerProgress)
                    .allowsHitTesting(drawerProgress > 0.5)
                    .accessibilityHidden(drawerProgress < 0.5)
                chat(home: home)
                    // The rounded mask reaches into the bottom safe area like the background below: a clip
                    // shape would stop at the layout frame and cut the transcript off above the Home
                    // indicator, leaving a bare strip under the composer.
                    .mask {
                        RoundedRectangle(cornerRadius: 28 * min(1, drawerProgress * 4), style: .continuous)
                            .ignoresSafeArea(.container, edges: .bottom)
                    }
                    // Paint the card's safe area outside the content clip without moving the input.
                    .background {
                        RoundedRectangle(cornerRadius: 28 * min(1, drawerProgress * 4), style: .continuous)
                            .fill(CommaTheme.bgPrimary)
                            .ignoresSafeArea(.container, edges: .bottom)
                    }
                    .shadow(color: .black.opacity(0.12 * drawerProgress), radius: 24, x: -4)
                    .offset(x: width * drawerProgress)
                    .allowsHitTesting(drawerProgress < 0.5)
                    .accessibilityHidden(drawerProgress > 0.5)
                    .ignoresSafeArea(.container, edges: [.top, .horizontal])
            }
            .background(CommaTheme.bgWindow.ignoresSafeArea())
            .sensoryFeedback(trigger: drawerOpen) { _, open in
                .impact(weight: open ? .medium : .light, intensity: 0.8)
            }
            // Edge swipes own their touches: a strip over the edge takes the drag before the task pages,
            // pull-to-refresh or the chat can see it. Opening starts at Home's left edge, closing at the
            // sidebar's right edge.
            .overlay(alignment: (dragStart ?? drawerProgress) > 0.5 ? .trailing : .leading) {
                DrawerEdgeGesture(
                    closing: (dragStart ?? drawerProgress) > 0.5,
                    onChanged: { translation in
                        if dragStart == nil { dragStart = drawerProgress }
                        guard let start = dragStart else { return }
                        drawerProgress = min(1, max(0, start + translation / max(1, width)))
                    },
                    onEnded: { velocity in
                        guard let start = dragStart else { return }
                        dragStart = nil
                        let projected = velocity.map { drawerProgress + $0 * 0.2 / max(1, width) } ?? start
                        setDrawer(projected > 0.5)
                    }
                )
                    .frame(width: Self.edgeWidth)
                    .ignoresSafeArea(.container, edges: .vertical)
            }
        }
    }

    private static let edgeWidth: CGFloat = 28

    private func setDrawer(_ open: Bool) {
        withAnimation(CommaMotion.railFold) { drawerProgress = open ? 1 : 0 }
        drawerOpen = open
    }

    // MARK: Home

    private func chat(home: ConversationPane?) -> some View {
        NavigationStack {
            HomeChatRoot(store: store, dismissRequest: dismissRequest,
                         showsTasksButton: horizontalSizeClass != .regular,
                         openTasks: { setDrawer(true) }, openSettings: openSettings)
        }
    }
}

/// A real hit-test surface keeps edge touches outside the sidebar's nested scroll views, even when
/// a vertical drag fails to become a drawer pan. The same view owns the entire touch sequence.
struct DrawerEdgeGesture: UIViewRepresentable {
    let closing: Bool
    let onChanged: (CGFloat) -> Void
    /// Horizontal release velocity, or nil when the gesture is cancelled.
    let onEnded: (CGFloat?) -> Void

    func makeUIView(context: Context) -> DrawerEdgeView { DrawerEdgeView() }

    func updateUIView(_ view: DrawerEdgeView, context: Context) {
        view.closing = closing
        view.onChanged = onChanged
        view.onEnded = onEnded
    }
}

final class DrawerEdgeView: UIView, UIGestureRecognizerDelegate {
    var closing = false
    var onChanged: (CGFloat) -> Void = { _ in }
    var onEnded: (CGFloat?) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y) && (closing ? velocity.x < 0 : velocity.x > 0)
    }

    @objc func handlePan(_ pan: UIPanGestureRecognizer) {
        // Window coordinates remain stable while SwiftUI updates the drawer's layout.
        switch pan.state {
        case .began, .changed: onChanged(pan.translation(in: window).x)
        case .ended: onEnded(pan.velocity(in: window).x)
        case .cancelled, .failed: onEnded(nil)
        default: break
        }
    }
}

/// UIKit animates the rendered card after one target layout. Animating SwiftUI padding instead
/// repeatedly resizes the transcript and makes its tail-following compete with the card's spring.
struct HomeCardHost<Content: View>: UIViewControllerRepresentable {
    let bottomInset: CGFloat
    let rounded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: Content

    init(bottomInset: CGFloat, rounded: Bool, @ViewBuilder content: () -> Content) {
        self.bottomInset = bottomInset
        self.rounded = rounded
        self.content = content()
    }

    func makeUIViewController(context: Context) -> HomeCardViewController<Content> {
        HomeCardViewController(content: content, environment: context.environment, bottomInset: bottomInset, rounded: rounded)
    }

    func updateUIViewController(_ controller: HomeCardViewController<Content>, context: Context) {
        controller.update(content: content, environment: context.environment, bottomInset: bottomInset, rounded: rounded,
                          animated: !reduceMotion, transaction: context.transaction)
    }
}

private struct HomeCardContent<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues
    var body: some View {
        content
            .environment(\.locale, environment.locale)
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.layoutDirection, environment.layoutDirection)
    }
}

final class HomeCardViewController<Content: View>: UIViewController {
    private let hosting: UIHostingController<HomeCardContent<Content>>
    private var bottomInset: CGFloat
    private var rounded: Bool
    private var animator: UIViewPropertyAnimator?
    private var laidOutSize: CGSize = .zero
    private var laidOutInsets: UIEdgeInsets = .zero

    init(content: Content, environment: EnvironmentValues, bottomInset: CGFloat, rounded: Bool) {
        hosting = UIHostingController(rootView: HomeCardContent(content: content, environment: environment))
        self.bottomInset = bottomInset
        self.rounded = rounded
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(hosting)
        hosting.view.backgroundColor = .clear
        hosting.view.layer.cornerCurve = .continuous
        hosting.view.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        hosting.view.clipsToBounds = true
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let insets = view.window?.safeAreaInsets ?? view.safeAreaInsets
        guard view.bounds.size != laidOutSize || insets != laidOutInsets else { return }
        laidOutSize = view.bounds.size
        laidOutInsets = insets
        settleCurrentAnimation()
        UIView.performWithoutAnimation { applyLayout() }
    }

    func update(content: Content, environment: EnvironmentValues, bottomInset nextInset: CGFloat,
                rounded nextRounded: Bool, animated: Bool, transaction: Transaction) {
        withTransaction(transaction) {
            hosting.rootView = HomeCardContent(content: content, environment: environment)
        }
        guard nextInset != bottomInset || nextRounded != rounded else { return }
        let changesDock = nextRounded != rounded
        bottomInset = nextInset
        rounded = nextRounded
        guard isViewLoaded, laidOutSize.width > 0 else { return }
        settleCurrentAnimation()
        // Keyboard resizing already follows the system animation; only Task open/close owns a spring.
        guard animated, changesDock else {
            applyLayout()
            return
        }
        let spring = UISpringTimingParameters(mass: 1, stiffness: 275, damping: 30, initialVelocity: .zero)
        let animation = UIViewPropertyAnimator(duration: 0, timingParameters: spring)
        animation.addAnimations { self.applyLayout(); self.hosting.view.layoutIfNeeded() }
        animation.addCompletion { [weak self] _ in self?.animator = nil }
        animator = animation
        animation.startAnimation()
    }

    private func settleCurrentAnimation() {
        guard let animator else { return }
        animator.stopAnimation(false)
        animator.finishAnimation(at: .current)
        self.animator = nil
    }

    private func applyLayout() {
        // With a dock, the card ends above both the bar and the Home indicator. Without it, the
        // hosting controller supplies the ordinary container/keyboard safe area to the chat.
        let reserved = bottomInset > 0 ? bottomInset + laidOutInsets.bottom : 0
        hosting.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width,
                                    height: max(0, view.bounds.height - reserved))
        hosting.view.layer.cornerRadius = rounded ? 32 : 0
    }
}

/// Home's navigation root. It reads the Home pane itself, so it updates when Home finishes loading
/// even though a NavigationStack keeps the root view it was first given.
struct HomeChatRoot: View {
    let store: CommaStore
    let dismissRequest: Int
    @FocusState private var composerFocused: Bool
    let showsTasksButton: Bool
    let openTasks: () -> Void
    let openSettings: () -> Void

    var body: some View {
        Group {
            if let home = store.home {
                PhoneConversationView(store: store, pane: home, composerFocus: $composerFocused)
            } else {
                // The desktop shows the animated mark while a conversation loads.
                CommaLogoAnimation(ink: CommaTheme.textPlaceholder, aperture: CommaTheme.bgPrimary)
                    .frame(width: 32, height: 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(CommaTheme.bgPrimary)
            }
        }
        .onChange(of: store.taskRevealRequest) { _, _ in composerFocused = false }
        .onChange(of: dismissRequest) { _, _ in composerFocused = false }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if showsTasksButton {
                    Button(action: openTasks) {
                        Image(systemName: "checklist").font(.system(size: 17, weight: .medium))
                            .foregroundStyle(CommaTheme.textPrimary)
                    }
                    .accessibilityLabel("Tasks")
                    .accessibilityIdentifier("openTasks")
                }
            }
            .horizontalBarOnly()
            ToolbarItem(placement: .principal) { HomeTitle(home: store.home) }
            if #available(iOS 27.0, *) {
                ToolbarOverflowMenu {
                    Button("Settings", systemImage: "gearshape", action: openSettings)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                            Button("Settings", systemImage: "gearshape", action: openSettings)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .tint(CommaTheme.textPrimary)
                }
            }
        }
    }
}

/// The Comma mark and name. While Home is thinking or streaming a reply, the mark plays the
/// desktop `CommaLogoAnimation` instead of standing still.
struct HomeTitle: View {
    let home: ConversationPane?

    var body: some View {
        let thinking = home.map { $0.replyActivity != nil || $0.assistantDraft != nil } ?? false
        // The mark alone; the name stays as the accessibility label.
        ZStack {
            if thinking {
                CommaLogoAnimation(ink: CommaTheme.textPrimary, aperture: CommaTheme.bgPrimary)
                    .transition(.opacity)
            } else {
                CommaMark(size: 26).foregroundStyle(CommaTheme.textPrimary).transition(.opacity)
            }
        }
        .frame(width: 26, height: 26)
        .animation(CommaMotion.stateChange, value: thinking)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Comma"))
        .accessibilityValue(thinking ? Text("Thinking") : Text(""))
    }
}

// MARK: - Sidebar

/// The task sidebar: one swipeable page of tasks per status, and a glass footer with the account,
/// the status switcher filling the remaining width, and Home.
struct TaskSidebarView: View {
    @Bindable var store: CommaStore
    let openSettings: () -> Void
    let openTask: (Conversation) -> Void
    /// Closes the full-width sidebar; nil where Home is always beside it (split view).
    let goHome: (() -> Void)?
    @State private var bucket: TaskBucket = .inProgress
    @State private var page: TaskBucket? = .inProgress
    @State private var choseInitialBucket = false
    @State private var query = ""
    @State private var results: [Conversation]?
    @State private var searchError: String?
    @State private var renaming: Conversation?
    @State private var sharing: Conversation?
    @State private var archivedOpen = false
    @State private var routinesOpen = false
    @FocusState private var searchFocused: Bool
    @Environment(\.openURL) private var openURL

    static let buckets: [TaskBucket] = [.backlog, .inProgress, .needsReview, .done, .cancelled]

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 8)
            searchField.padding(.horizontal, 16).padding(.top, 10)
            if searching {
                searchResults
            } else {
                RoutinesStrip(store: store, actions: routineActions, openAll: { routinesOpen = true })
                    .padding(.horizontal, 16).padding(.top, 14)
                HStack(alignment: .firstTextBaseline) {
                    Text("Tasks").font(.system(size: 14, weight: .medium)).foregroundStyle(CommaTheme.textSecondary)
                    Spacer()
                    Text(bucket.label).font(.system(size: 13)).foregroundStyle(CommaTheme.textQuaternary)
                        .contentTransition(.opacity)
                        .animation(CommaMotion.stateChange, value: bucket)
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 6)
                pages
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        }
        .background(CommaTheme.bgWindow.ignoresSafeArea())
        .taskActionSheets(store: store, renaming: $renaming, sharing: $sharing)
        .sheet(isPresented: $archivedOpen) {
            ArchivedTasksView(store: store, openTask: openTask)
        }
        .sheet(isPresented: $routinesOpen) {
            RoutinesView(store: store, actions: routineActions)
        }
        .task(id: query) { await search() }
        .task { await store.loadProfile() }
        .onChange(of: store.workspace?.id) { _, _ in query = ""; results = nil }
        .onAppear(perform: chooseInitialBucket)
        .onChange(of: store.tasks.count) { _, _ in chooseInitialBucket() }
        .onChange(of: page) { _, value in
            if let value, value != bucket { bucket = value }
        }
    }

    private func select(_ next: TaskBucket) {
        guard next != bucket else { return }
        bucket = next
        withAnimation(CommaMotion.spatialMove) { page = next }
    }

    /// Open on the bucket that most likely needs the reader: review first, then running work.
    private func chooseInitialBucket() {
        guard !choseInitialBucket, !store.tasks.isEmpty else { return }
        choseInitialBucket = true
        let present = Set(store.tasks.map(\.bucket))
        let initial = [.needsReview, .inProgress, .backlog, .done, .cancelled].first(where: present.contains) ?? TaskBucket.inProgress
        bucket = initial
        page = initial
    }

    private var header: some View {
        HStack(spacing: 8) {
            CommaMark(size: 22).foregroundStyle(CommaTheme.textPrimary)
            if store.workspaces.count > 1 {
                Menu {
                    ForEach(store.workspaces) { workspace in
                        Button {
                            Task { await store.chooseWorkspace(workspace) }
                        } label: {
                            if workspace.id == store.workspace?.id { Label(workspace.name, systemImage: "checkmark") }
                            else { Text(workspace.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.workspace?.name ?? "Workspace").lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CommaTheme.textQuaternary)
                    }
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(CommaTheme.textPrimary)
                }
            } else {
                Text(store.workspace?.name.isEmpty == false ? store.workspace!.name : "Comma")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(CommaTheme.textPrimary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { archivedOpen = true } label: {
                Image(systemName: "archivebox").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(CommaTheme.textSecondary).frame(width: 36, height: 36)
            }
            .accessibilityLabel("Archived tasks")
            .accessibilityIdentifier("openArchivedTasks")
        }
        .frame(height: 36)
    }

    // MARK: Routines

    /// A Routine prompt goes into the Home composer for the member to send; a Task opens in its sheet.
    private var routineActions: RoutineActions {
        RoutineActions(
            usePrompt: { prompt in
                guard let home = store.home else { return }
                home.draftText = home.draftText.isEmpty ? prompt : home.draftText + "\n\n" + prompt
                goHome?()
            },
            openTask: { id in
                goHome?()
                Task { await store.openTask(id: id) }
            },
            openURL: { openURL($0) })
    }

    // MARK: Search

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(CommaTheme.textQuaternary)
            TextField("Search tasks", text: $query)
                .font(.system(size: 15))
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityIdentifier("searchTasks")
            if !query.isEmpty {
                Button { query = ""; searchFocused = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(CommaTheme.textPlaceholder)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(CommaTheme.sidebarItem.opacity(0.6), in: Capsule())
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if let searchError {
                    Text(searchError).font(.system(size: 14)).foregroundStyle(CommaTheme.errorPrimary).padding(.top, 40)
                } else if let results {
                    if results.isEmpty {
                        Text("No matching tasks").font(.system(size: 14)).foregroundStyle(CommaTheme.textQuaternary).padding(.top, 80)
                    }
                    ForEach(results) { task in row(task) }
                } else {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .scrollDismissesKeyboard(.immediately)
        .frame(maxHeight: .infinity)
    }

    /// One bounded server search per settled query; typing cancels the previous one.
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { results = nil; searchError = nil; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let found = try await store.searchTasks(text)
            guard !Task.isCancelled else { return }
            results = found; searchError = nil
        } catch {
            guard !Task.isCancelled else { return }
            if case CommaError.cancelled = error { return }
            results = nil; searchError = error.localizedDescription
        }
    }

    private func row(_ task: Conversation) -> some View {
        Button { searchFocused = false; openTask(task) } label: {
            TaskListRow(task: task, selected: store.task?.taskID == task.id, pinned: store.pinnedTaskIDs.contains(task.id))
        }
        .buttonStyle(TaskRowButtonStyle())
        .accessibilityIdentifier("task-" + task.id)
        .contextMenu {
            TaskActionMenuItems(store: store, task: task, rename: { renaming = task }, share: { sharing = task })
        }
    }

    /// One page per status. Swiping pages and choosing in the switcher move the same selection.
    private var pages: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Self.buckets, id: \.self) { bucket in
                    taskPage(bucket).containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
    }

    private func taskPage(_ bucket: TaskBucket) -> some View {
        // Pinned Tasks lead their status page; otherwise the server's order stands.
        let inBucket = store.tasks.filter { $0.bucket == bucket }
        let tasks = inBucket.filter { store.pinnedTaskIDs.contains($0.id) } + inBucket.filter { !store.pinnedTaskIDs.contains($0.id) }
        return ScrollView {
            if tasks.isEmpty {
                Text(store.tasks.isEmpty
                     ? (store.loading ? "Loading tasks…" : "Tasks appear here when you ask Comma to work on something.")
                     : "No tasks in this status")
                    .font(.system(size: 14)).foregroundStyle(CommaTheme.textQuaternary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.top, 120)
                    .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(tasks) { task in
                        row(task)
                        .onAppear {
                            if task.id == store.tasks.last?.id, store.hasMoreTasks, !store.loadingMore {
                                Task { await store.loadMoreTasks() }
                            }
                        }
                    }
                    if store.loadingMore { ProgressView().padding(.vertical, 8) }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.refresh() }
    }

    /// Account, status and Home share one glass row; the status switcher takes all remaining width.
    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: openSettings) {
                UserAvatar(store: store, size: 34)
                    .padding(5)
                    .commaGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(TactileButtonStyle(scale: 0.92))
            .accessibilityLabel(Text("Settings"))
            StatusSwitcher(buckets: Self.buckets, selection: bucket, counts: counts, choose: select)
                .frame(maxWidth: .infinity)
            if let goHome {
                Button(action: goHome) {
                    Image(systemName: "house").font(.system(size: 18, weight: .medium))
                        .foregroundStyle(CommaTheme.textPrimary)
                        .frame(width: 44, height: 44)
                        .commaGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(TactileButtonStyle(scale: 0.9))
                .accessibilityLabel("Home")
            }
        }
        .commaGlassGroup(spacing: 10)
    }

    private var counts: [TaskBucket: Int] {
        Dictionary(grouping: store.tasks, by: \.bucket).mapValues(\.count)
    }
}

/// Plain list row: status icon on the title line, then running progress or the updated date.
struct TaskListRow: View {
    let task: Conversation
    var selected = false
    var pinned = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TaskStatusIcon(bucket: task.bucket).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(task.title).font(.system(size: 15, weight: .medium)).foregroundStyle(CommaTheme.textPrimary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CommaTheme.textPlaceholder)
                            .accessibilityLabel("Pinned")
                    }
                }
                if let progress = task.progressLabel {
                    ShimmerText(text: progress)
                } else {
                    Text(task.updatedLabel).font(.system(size: 13)).foregroundStyle(CommaTheme.textQuaternary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(selected ? CommaTheme.sidebarItem.opacity(0.7) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Rows have no resting surface; a press paints the item colour, like the desktop rail hover.
struct TaskRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(CommaTheme.sidebarItem.opacity(configuration.isPressed ? 0.7 : 0),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Status pill from the desktop rail footer. It fills the width it is given, split evenly per status.
/// Tap a status, or drag across the pill to scrub between them.
struct StatusSwitcher: View {
    let buckets: [TaskBucket]
    let selection: TaskBucket
    let counts: [TaskBucket: Int]
    let choose: (TaskBucket) -> Void
    @Namespace private var namespace
    @State private var width: CGFloat = 0
    private let inset: CGFloat = 3
    /// Matches the 44pt avatar and Home buttons beside it in the sidebar footer.
    static let height: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            ForEach(buckets, id: \.self) { bucket in
                Button { choose(bucket) } label: {
                    TaskStatusIcon(bucket: bucket, size: 18)
                        .frame(maxWidth: .infinity).frame(height: StatusSwitcher.height - 6)
                        .background {
                            if bucket == selection {
                                Capsule().fill(CommaTheme.cardPrimary)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .overlay(alignment: .top) {
                            if bucket == .needsReview, (counts[bucket] ?? 0) > 0 {
                                Circle().fill(CommaTheme.brandSolid).frame(width: 7, height: 7)
                                    .overlay(Circle().stroke(CommaTheme.bgTertiary, lineWidth: 1.5))
                                    .offset(x: 9, y: 5)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(TactileButtonStyle(scale: 0.92))
                .accessibilityLabel(Text(bucket.label))
                .accessibilityAddTraits(bucket == selection ? .isSelected : [])
            }
        }
        .padding(inset)
        .commaGlass(in: Capsule(), interactive: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 6).onChanged { value in
                let segment = max(1, (width - inset * 2) / CGFloat(buckets.count))
                let index = min(max(Int(((value.location.x - inset) / segment).rounded(.down)), 0), buckets.count - 1)
                if buckets[index] != selection { choose(buckets[index]) }
            }
        )
        .sensoryFeedback(.selection, trigger: selection)
        .animation(CommaMotion.spatialMove, value: selection)
    }
}

// The vertical bar (iPhone Duo's status column) ships in the iOS 27.1 SDK. Older SDKs build
// these items for the horizontal navigation bar only.
extension ToolbarContent {
    /// Keeps an item in the horizontal navigation bar when the system also shows a vertical bar.
    @ToolbarContentBuilder func horizontalBarOnly() -> some ToolbarContent {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) { axisBehavior(.horizontalOnly) } else { self }
        #else
        self
        #endif
    }

    /// Moves an item into the vertical bar when the system shows one.
    @ToolbarContentBuilder func verticalBarPreferred() -> some ToolbarContent {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) { axisBehavior(.verticalPreferred) } else { self }
        #else
        self
        #endif
    }
}
