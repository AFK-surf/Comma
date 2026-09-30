import AppKit

@MainActor
public final class NotchController {
    public static let automationIdentifier = NotchWindowMetadata.automationIdentifier

    public var hasActivity: Bool {
        runtimeModel.scene.hasActivity
    }

    private var configuration: NotchConfiguration
    private let runtimeModel: NotchRuntimeModel
    private let windowManager = NotchWindowManager()
    private let interactionMonitor = NotchInteractionMonitor()

    private var screenObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?
    private var screensDidWakeObserver: NSObjectProtocol?
    private var pendingSettledScreenRefreshes: [DispatchWorkItem] = []
    private var hasStarted = false

    private static let settledScreenRefreshDelays: [TimeInterval] = [0.12, 0.35, 0.9]

    public init(configuration: NotchConfiguration = .init()) {
        self.configuration = configuration
        runtimeModel = NotchRuntimeModel(configuration: configuration)
        runtimeModel.onLayoutInvalidated = { [weak windowManager, weak runtimeModel] in
            guard let windowManager, let runtimeModel else { return }
            Task { @MainActor in
                windowManager.syncWindow(with: runtimeModel)
            }
        }
    }

    @MainActor
    deinit {
        stop()
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true

        interactionMonitor.onMouseDown = { [weak self] point in
            self?.runtimeModel.handleMouseDown(at: point)
        }
        interactionMonitor.onMouseMoved = { [weak self] point in
            self?.runtimeModel.handleMouseMoved(at: point)
        }
        interactionMonitor.start()

        observeScreenChanges()
        refreshScreenAndSyncWindow()
    }

    public func stop() {
        guard hasStarted else { return }
        hasStarted = false

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil

        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
        }
        activeSpaceObserver = nil

        if let didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(didWakeObserver)
        }
        didWakeObserver = nil

        if let screensDidWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screensDidWakeObserver)
        }
        screensDidWakeObserver = nil

        cancelSettledScreenRefreshes()

        interactionMonitor.onMouseDown = nil
        interactionMonitor.onMouseMoved = nil
        interactionMonitor.stop()
        windowManager.close()
    }

    public func update(scene: NotchScene) {
        runtimeModel.updateScene(scene)
        if hasStarted {
            refreshScreenAndSyncWindow()
        }
    }

    public func update(configuration: NotchConfiguration) {
        self.configuration = configuration
        runtimeModel.configuration = configuration

        guard hasStarted else { return }

        refreshScreenAndSyncWindow()
    }

    public func open() {
        runtimeModel.open()
        windowManager.syncWindow(with: runtimeModel)
    }

    public func close() {
        runtimeModel.close()
        windowManager.syncWindow(with: runtimeModel)
    }

    public func toggle() {
        runtimeModel.toggle()
        windowManager.syncWindow(with: runtimeModel)
    }

    /// Request a one-shot "absorb" scale pulse of the notch shell. The pulse is a
    /// view-level animation, so no window geometry sync is needed.
    public func pulse() {
        runtimeModel.pulse()
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshScreenAfterGeometryChange()
            }
        }

        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter

        activeSpaceObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshScreenAfterGeometryChange()
            }
        }

        didWakeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshScreenAfterGeometryChange()
            }
        }

        screensDidWakeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshScreenAfterGeometryChange()
            }
        }
    }

    private func refreshScreenAfterGeometryChange() {
        refreshScreenAndSyncWindow()
        scheduleSettledScreenRefreshes()
    }

    private func refreshScreenAndSyncWindow() {
        guard hasStarted else { return }
        refreshScreen()
        windowManager.syncWindow(with: runtimeModel)
    }

    private func scheduleSettledScreenRefreshes() {
        cancelSettledScreenRefreshes()

        pendingSettledScreenRefreshes = Self.settledScreenRefreshDelays.map { delay in
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshScreenAndSyncWindow()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return workItem
        }
    }

    private func cancelSettledScreenRefreshes() {
        pendingSettledScreenRefreshes.forEach { $0.cancel() }
        pendingSettledScreenRefreshes.removeAll()
    }

    private func refreshScreen() {
        guard let screen = preferredScreen() else { return }
        runtimeModel.updateScreen(
            screen,
            fallbackSize: configuration.fallbackNotchSize,
            isFullScreen: screen.notchKitHasFullScreenWindow
        )
    }

    private func preferredScreen() -> NSScreen? {
        switch configuration.screenSelectionPolicy {
        case .builtInFirst:
            if let builtIn = NSScreen.builtInNotchDisplay, builtIn.notchKitSize != .zero {
                return builtIn
            }
            return NSScreen.main ?? NSScreen.screens.first
        case .screenUnderPointer:
            return NSScreen.screenUnderPointer ?? NSScreen.main ?? NSScreen.screens.first
        case .mainScreen:
            return NSScreen.main ?? NSScreen.screens.first
        }
    }
}
