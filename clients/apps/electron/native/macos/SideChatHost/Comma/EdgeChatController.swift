import AppKit
import Carbon
import QuartzCore

/// Owns only the physical edge gesture and reveal state. Electron renders the
/// side-chat window; this helper never creates an AppKit or SwiftUI window.
@MainActor
final class EdgeChatController {
    private enum Layout {
        static let defaultContentSize = CGSize(width: 364, height: 254)
        static let minimumContentSize = CGSize(width: 120, height: 40)
        static let minimumOpenXOffset: CGFloat = 4
        static let minimumWindowWidth: CGFloat = 1
    }

    private struct GeometrySettings: Equatable {
        static let defaults = GeometrySettings(
            bottomFeather: 26,
            bottomOffset: 12,
            closedExtraOffset: 16,
            contentOffsetX: -34,
            contentOffsetY: -35,
            contentWidth: 364,
            leftFeather: 39,
            openXOffset: 4,
            rightFeather: 120,
            solidOutsetBottom: 0,
            solidOutsetLeft: -46,
            solidOutsetRight: -108,
            solidOutsetTop: -23,
            topFeather: 53
        )

        let bottomFeather: CGFloat
        let bottomOffset: CGFloat
        let closedExtraOffset: CGFloat
        let contentOffsetX: CGFloat
        let contentOffsetY: CGFloat
        let contentWidth: CGFloat
        let leftFeather: CGFloat
        let openXOffset: CGFloat
        let rightFeather: CGFloat
        let solidOutsetBottom: CGFloat
        let solidOutsetLeft: CGFloat
        let solidOutsetRight: CGFloat
        let solidOutsetTop: CGFloat
        let topFeather: CGFloat

        init(
            bottomFeather: Double,
            bottomOffset: Double,
            closedExtraOffset: Double,
            contentOffsetX: Double,
            contentOffsetY: Double,
            contentWidth: Double,
            leftFeather: Double,
            openXOffset: Double,
            rightFeather: Double,
            solidOutsetBottom: Double,
            solidOutsetLeft: Double,
            solidOutsetRight: Double,
            solidOutsetTop: Double,
            topFeather: Double
        ) {
            self.bottomFeather = CGFloat(bottomFeather)
            self.bottomOffset = CGFloat(bottomOffset)
            self.closedExtraOffset = CGFloat(closedExtraOffset)
            self.contentOffsetX = CGFloat(contentOffsetX)
            self.contentOffsetY = CGFloat(contentOffsetY)
            self.contentWidth = CGFloat(contentWidth)
            self.leftFeather = CGFloat(leftFeather)
            self.openXOffset = CGFloat(openXOffset)
            self.rightFeather = CGFloat(rightFeather)
            self.solidOutsetBottom = CGFloat(solidOutsetBottom)
            self.solidOutsetLeft = CGFloat(solidOutsetLeft)
            self.solidOutsetRight = CGFloat(solidOutsetRight)
            self.solidOutsetTop = CGFloat(solidOutsetTop)
            self.topFeather = CGFloat(topFeather)
        }

        init(_ settings: CommaSideChatLayoutDebugSettings) {
            self.init(
                bottomFeather: settings.bottomFeather,
                bottomOffset: settings.bottomOffset,
                closedExtraOffset: settings.closedExtraOffset,
                contentOffsetX: settings.contentOffsetX,
                contentOffsetY: settings.contentOffsetY,
                contentWidth: settings.contentWidth,
                leftFeather: settings.leftFeather,
                openXOffset: settings.openXOffset,
                rightFeather: settings.rightFeather,
                solidOutsetBottom: settings.solidOutsetBottom,
                solidOutsetLeft: settings.solidOutsetLeft,
                solidOutsetRight: settings.solidOutsetRight,
                solidOutsetTop: settings.solidOutsetTop,
                topFeather: settings.topFeather
            )
        }

        var horizontalBackdropPadding: CGFloat {
            leftFeather + rightFeather + max(0, solidOutsetLeft) + max(0, solidOutsetRight)
        }

        var verticalBackdropPadding: CGFloat {
            topFeather + bottomFeather + max(0, solidOutsetTop) + max(0, solidOutsetBottom)
        }

        var contentOrigin: NSPoint {
            NSPoint(
                x: leftFeather + max(0, solidOutsetLeft) + contentOffsetX,
                y: bottomFeather + max(0, solidOutsetBottom) + contentOffsetY
            )
        }
    }

    private var contentSize = Layout.defaultContentSize
    private var geometrySettings = GeometrySettings.defaults
    private var frameEmitter: ((SideChatPresentation) -> Void)?
    private var hotKey: GlobalHotKey?
    private var hotKeyKeyCode = UInt32(kVK_ANSI_Z)
    private var hotKeyModifiers = UInt32(controlKey)
    /// The binding Main last saved, kept while Side Chat is off so turning it
    /// back on registers the same chord; nil means the shortcut is cleared.
    private var savedHotKey: (keyCode: UInt32, modifiers: UInt32)?
    private var isEnabled = true
    private var nextHotKeyID = UInt32(1)
    private var trackpadMonitor: TrackpadEdgeSwipeMonitor?
    private var notificationObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pendingInteractiveProgress: CGFloat?
    private var interactiveProgressGeneration = 0
    private var isInteractiveProgressScheduled = false
    private var forcedCloseEpoch = 0
    private var activeForcedCloseEpoch: Int?
    private var progressAnimationGeneration = 0
    private var progress: CGFloat = 0
    private var phase: SideChatPresentationPhase = .closed
    private var presentationRevision = 0

    func installPresentationEmitter(_ emitter: @escaping (SideChatPresentation) -> Void) {
        frameEmitter = emitter
    }

    func publishCurrentPresentation() {
        emitPresentation()
    }

    func start() {
        observeScreenChanges()

        // Main replays the saved binding, including an explicitly cleared one.

        startTrackpadMonitor()
        applyProgress(0, phase: .closed)
    }

    /// Off releases the edge gesture and the global shortcut, so neither the
    /// trackpad nor the chord reaches Side Chat, and closes a visible surface.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            startTrackpadMonitor()
            if let savedHotKey {
                _ = updateHotKey(keyCode: savedHotKey.keyCode, modifiers: savedHotKey.modifiers)
            }
            return
        }
        trackpadMonitor?.stop()
        trackpadMonitor = nil
        hotKey = nil
        forceClose()
    }

    private func startTrackpadMonitor() {
        guard trackpadMonitor == nil else { return }
        let monitor = TrackpadEdgeSwipeMonitor(
            onProgress: { [weak self] gestureProgress in
                self?.setInteractiveProgress(gestureProgress)
            },
            onComplete: { [weak self] shouldOpen in
                self?.finishInteractiveProgress(shouldOpen: shouldOpen)
            },
            onStatusChange: { _ in }
        )
        trackpadMonitor = monitor
        monitor.start()
        monitor.panelVisibility = progress
        if activeForcedCloseEpoch != nil { monitor.setInputEnabled(false) }
    }

    @discardableResult
    func updateHotKey(keyCode: UInt32?, modifiers: UInt32) -> Bool {
        guard let keyCode else {
            savedHotKey = nil
            hotKey = nil
            return true
        }
        guard isEnabled else {
            savedHotKey = (keyCode, modifiers)
            return true
        }
        if let hotKey,
           hotKey.isRegistered,
           hotKeyKeyCode == keyCode,
           hotKeyModifiers == modifiers {
            return true
        }

        let candidateID = nextHotKeyID
        nextHotKeyID &+= 1
        let candidate = GlobalHotKey(
            id: candidateID,
            keyCode: keyCode,
            modifiers: modifiers
        ) { [weak self] in
            self?.toggle()
        }
        guard candidate.isRegistered else { return false }

        hotKey = candidate
        hotKeyKeyCode = keyCode
        hotKeyModifiers = modifiers
        savedHotKey = (keyCode, modifiers)
        return true
    }

    func stop() {
        trackpadMonitor?.stop()
        trackpadMonitor = nil
        hotKey = nil

        pendingInteractiveProgress = nil
        interactiveProgressGeneration += 1
        forcedCloseEpoch += 1
        activeForcedCloseEpoch = nil
        progressAnimationGeneration += 1
        isInteractiveProgressScheduled = false

        for (center, observer) in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    func updateLayout(
        width: Double,
        height: Double,
        debugSettings: CommaSideChatLayoutDebugSettings
    ) {
        guard width.isFinite, height.isFinite else { return }
        guard width >= Layout.minimumContentSize.width,
              height >= Layout.minimumContentSize.height else { return }

        let nextGeometrySettings = GeometrySettings(debugSettings)
        let nextSize = CGSize(
            width: ceil(nextGeometrySettings.contentWidth),
            height: ceil(height)
        )
        let sizeChanged = abs(nextSize.width - contentSize.width) > 0.5
            || abs(nextSize.height - contentSize.height) > 0.5
        let geometryChanged = nextGeometrySettings != geometrySettings
        guard sizeChanged || geometryChanged else { return }

        contentSize = nextSize
        geometrySettings = nextGeometrySettings
        emitPresentation()
    }

    func toggle() {
        guard activeForcedCloseEpoch == nil else { return }
        phase.targetIsOpen ? close() : open()
    }

    func open() {
        guard isEnabled, activeForcedCloseEpoch == nil else { return }
        animate(to: 1, phase: .opening)
    }

    func close() {
        guard activeForcedCloseEpoch == nil else { return }
        animate(to: 0, phase: .closing)
    }

    /// Starts a close epoch that local hotkey, trackpad, and open requests
    /// cannot interrupt. The epoch remains active while the terminal closed
    /// presentation is synchronously emitted to the command server.
    func forceClose() {
        forcedCloseEpoch += 1
        let epoch = forcedCloseEpoch
        activeForcedCloseEpoch = epoch
        trackpadMonitor?.setInputEnabled(false)
        animate(to: 0, phase: .closing, forcedCloseEpoch: epoch)
    }

    private func animate(
        to targetProgress: CGFloat,
        phase transitionPhase: SideChatPresentationPhase,
        forcedCloseEpoch: Int? = nil
    ) {
        if let forcedCloseEpoch {
            guard forcedCloseEpoch == activeForcedCloseEpoch else { return }
        }

        let clampedTarget = min(max(targetProgress, 0), 1)
        progressAnimationGeneration += 1
        interactiveProgressGeneration += 1
        pendingInteractiveProgress = nil
        isInteractiveProgressScheduled = false

        guard abs(clampedTarget - progress) > 0.001 else {
            applyProgress(clampedTarget, phase: clampedTarget >= 0.998 ? .open : .closed)
            finishForcedClose(epoch: forcedCloseEpoch)
            return
        }

        let generation = progressAnimationGeneration
        animateProgress(
            from: progress,
            to: clampedTarget,
            phase: transitionPhase,
            generation: generation,
            forcedCloseEpoch: forcedCloseEpoch,
            startedAt: CACurrentMediaTime()
        )
    }

    private func animateProgress(
        from startProgress: CGFloat,
        to targetProgress: CGFloat,
        phase transitionPhase: SideChatPresentationPhase,
        generation: Int,
        forcedCloseEpoch: Int?,
        startedAt: CFTimeInterval
    ) {
        guard generation == progressAnimationGeneration else { return }
        if let forcedCloseEpoch {
            guard forcedCloseEpoch == activeForcedCloseEpoch else { return }
        }

        let duration: CFTimeInterval = 0.22
        let elapsed = CACurrentMediaTime() - startedAt
        let linearProgress = min(max(elapsed / duration, 0), 1)
        let easedProgress = 1 - pow(1 - linearProgress, 3)
        let currentProgress = startProgress + (targetProgress - startProgress) * CGFloat(easedProgress)

        guard linearProgress < 1 else {
            applyProgress(targetProgress, phase: targetProgress >= 0.998 ? .open : .closed)
            finishForcedClose(epoch: forcedCloseEpoch)
            return
        }

        applyProgress(currentProgress, phase: transitionPhase)
        DispatchQueue.main.asyncAfter(deadline: .now() + (1.0 / 60.0)) { [weak self] in
            self?.animateProgress(
                from: startProgress,
                to: targetProgress,
                phase: transitionPhase,
                generation: generation,
                forcedCloseEpoch: forcedCloseEpoch,
                startedAt: startedAt
            )
        }
    }

    func setInteractiveProgress(_ nextProgress: CGFloat) {
        guard isEnabled, activeForcedCloseEpoch == nil else { return }
        progressAnimationGeneration += 1
        pendingInteractiveProgress = nextProgress
        guard !isInteractiveProgressScheduled else { return }

        isInteractiveProgressScheduled = true
        let generation = interactiveProgressGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + (1.0 / 60.0)) { [weak self] in
            guard let self, generation == self.interactiveProgressGeneration else { return }
            self.isInteractiveProgressScheduled = false

            guard let nextProgress = self.pendingInteractiveProgress else { return }
            self.pendingInteractiveProgress = nil
            self.applyProgress(nextProgress, phase: .interactive)
        }
    }

    func finishInteractiveProgress(shouldOpen: Bool) {
        guard activeForcedCloseEpoch == nil else { return }
        let finalPendingProgress = pendingInteractiveProgress
        interactiveProgressGeneration += 1
        pendingInteractiveProgress = nil
        isInteractiveProgressScheduled = false
        if let finalPendingProgress {
            applyProgress(finalPendingProgress, phase: .interactive)
        }
        shouldOpen ? open() : close()
    }

    private func finishForcedClose(epoch: Int?) {
        guard let epoch, activeForcedCloseEpoch == epoch else { return }
        trackpadMonitor?.setInputEnabled(true)
        activeForcedCloseEpoch = nil
    }

    private func applyProgress(_ nextProgress: CGFloat, phase nextPhase: SideChatPresentationPhase) {
        progress = min(max(nextProgress, 0), 1)
        phase = nextPhase
        trackpadMonitor?.panelVisibility = progress
        emitPresentation()
    }

    private func emitPresentation() {
        guard let frameEmitter else { return }

        presentationRevision += 1
        let geometry = presentationGeometry()
        let offsetX = progress >= 1
            ? 0
            : -(1 - progress) * (geometry.windowFrame.width + geometrySettings.closedExtraOffset)
        frameEmitter(SideChatPresentation(
            availableContentHeight: geometry.availableContentHeight,
            revision: presentationRevision,
            phase: phase,
            progress: Double(progress),
            offsetX: Double(offsetX),
            displayID: geometry.displayID,
            screenFrame: SideChatPresentationRect(geometry.screenFrame),
            contentFrame: SideChatPresentationRect(geometry.contentFrame),
            windowFrame: SideChatPresentationRect(geometry.windowFrame)
        ))
    }

    private func presentationGeometry() -> (
        availableContentHeight: Double,
        displayID: Int,
        screenFrame: NSRect,
        contentFrame: NSRect,
        windowFrame: NSRect
    ) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = screen?.visibleFrame ?? screenFrame
        let layoutFrame = NSRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: visibleFrame.maxY - screenFrame.minY
        )
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0

        let windowOrigin = NSPoint(
            x: min(
                max(
                    layoutFrame.minX + Layout.minimumOpenXOffset,
                    layoutFrame.minX + geometrySettings.openXOffset
                ),
                layoutFrame.maxX - Layout.minimumWindowWidth
            ),
            y: layoutFrame.minY + geometrySettings.bottomOffset
        )
        let maximumWindowWidth = max(260, layoutFrame.width - 48)
        let maximumWindowHeight = max(180, layoutFrame.maxY - windowOrigin.y)
        let requestedWindowSize = CGSize(
            width: min(
                maximumWindowWidth,
                ceil(contentSize.width + geometrySettings.horizontalBackdropPadding)
            ),
            height: min(
                maximumWindowHeight,
                ceil(contentSize.height + geometrySettings.verticalBackdropPadding)
            )
        )
        var windowFrame = NSRect(
            origin: windowOrigin,
            size: CGSize(
                width: max(1, min(requestedWindowSize.width, layoutFrame.maxX - windowOrigin.x)),
                height: requestedWindowSize.height
            )
        )
        let contentFrame = NSRect(
            x: windowFrame.minX + geometrySettings.contentOrigin.x,
            y: windowFrame.minY + geometrySettings.contentOrigin.y,
            width: contentSize.width,
            height: contentSize.height
        )
        let availableContentHeight = max(
            120,
            floor(layoutFrame.maxY - windowFrame.minY - geometrySettings.contentOrigin.y)
        )
        let leftExtension = max(0, windowFrame.minX - screenFrame.minX)
        windowFrame.origin.x -= leftExtension
        windowFrame.size.width += leftExtension
        let bottomExtension = max(0, windowFrame.minY - screenFrame.minY)
        windowFrame.origin.y -= bottomExtension
        windowFrame.size.height += bottomExtension

        return (
            Double(availableContentHeight),
            displayID,
            screenFrame,
            contentFrame,
            windowFrame
        )
    }

    private func observeScreenChanges() {
        guard notificationObservers.isEmpty else { return }

        let applicationCenter = NotificationCenter.default
        let screenObserver = applicationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitPresentation()
            }
        }
        notificationObservers.append((applicationCenter, screenObserver))

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let spaceObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitPresentation()
            }
        }
        notificationObservers.append((workspaceCenter, spaceObserver))
    }
}

private extension SideChatPresentationPhase {
    var targetIsOpen: Bool {
        switch self {
        case .opening, .interactive, .open:
            return true
        case .closed, .closing:
            return false
        }
    }
}

private func logToStandardError(_ message: String) {
    FileHandle.standardError.write(Data("[CommaSideChatHost] \(message)\n".utf8))
}
