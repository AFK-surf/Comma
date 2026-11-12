import AppKit
import CoreVideo
import QuartzCore

@MainActor
final class WorkspaceDimmingCoordinator {
    private(set) var appearance = Appearance()
    private(set) var isActive = false
    var allOverlayWindows: [NSWindow] {
        overlayWindows + [colorfulBorderWindow].compactMap(\.self)
    }

    private var overlayWindows: [NSWindow] = []
    private var activationObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var pendingRefresh: DispatchWorkItem?
    private var lastRenderSignature: RenderSignature?
    private var lastPrintedFocusedBounds: CGRect?
    private var lastDisplayLinkTimestamp: TimeInterval = 0
    private var accumulatedDeltaTime: TimeInterval = 0
    private var frameReportCount: Int = 0

    private var displayLinkWrapper: CVDisplayLinkWrapper?
    private var nextObservationTimestamp: TimeInterval = 0
    private var boostedObservationDeadline: TimeInterval = 0
    private var animationState: AnimationState?
    private var presentedOpacity: Double = 0
    private var currentAnchorWindowNumbers: [Int] = []
    private var currentScreenFrames: [CGRect] = []
    private var colorfulBorderWindow: ColorfulBorderWindow?
    private var lastBorderAnchorWindowNumber: Int = 0
    private var lastBorderCornerRadius: CGFloat = 16

    func activate() {
        guard !isActive else {
            refresh(withDelay: false)
            return
        }

        isActive = true
        startObservingActivationChanges()
        startObservingScreenChanges()
        startDisplayLinkIfNeeded()
        boostObservationWindow()
        refresh(withDelay: false)
    }

    func deactivate() {
        guard isActive else { return }

        isActive = false
        pendingRefresh?.cancel()
        pendingRefresh = nil
        stopObservingActivationChanges()
        stopObservingScreenChanges()
        stopDisplayLink()
        animationState = nil
        nextObservationTimestamp = 0
        boostedObservationDeadline = 0
        lastRenderSignature = nil
        lastPrintedFocusedBounds = nil
        lastDisplayLinkTimestamp = 0
        accumulatedDeltaTime = 0
        frameReportCount = 0
        currentAnchorWindowNumbers = []
        currentScreenFrames = []
        presentedOpacity = 0
        lastBorderAnchorWindowNumber = 0
        lastBorderCornerRadius = 16
        removeAllOverlays()
        removeColorfulBorder()
    }

    func updateAppearance(_ appearance: Appearance) {
        self.appearance = appearance

        guard isActive else { return }
        refresh(withDelay: false)
    }

    func refresh(withDelay: Bool) {
        pendingRefresh?.cancel()

        guard isActive else {
            removeAllOverlays()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            boostObservationWindow()
            renderCurrentState(force: true, shouldAnimate: true)
        }

        pendingRefresh = workItem

        let delay = withDelay ? appearance.activationDelay : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func renderCurrentState(force: Bool, shouldAnimate: Bool) {
        guard isActive else {
            lastRenderSignature = nil
            removeAllOverlays()
            return
        }

        if appearance.ignoresDesktop,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        {
            lastRenderSignature = nil
            currentAnchorWindowNumbers = []
            currentScreenFrames = []
            removeColorfulBorder()
            transitionPresentedOpacity(to: 0, animated: shouldAnimate)
            return
        }

        let descriptors = WindowDescriptor.onScreenWindows()
        let screens = NSScreen.screens
        let anchorWindowNumbers = anchorWindowNumbers(for: descriptors, screens: screens)
        let screenFrames = screens.map(\.frame)
        let signature = RenderSignature(
            mode: appearance.mode,
            color: appearance.color,
            targetOpacity: appearance.opacity,
            anchorWindowNumbers: anchorWindowNumbers,
            screenFrames: screenFrames
        )

        guard force || signature != lastRenderSignature else { return }

        applyOverlayLayout(
            screens: screens,
            descriptors: descriptors,
            anchorWindowNumbers: anchorWindowNumbers,
            screenFrames: screenFrames
        )
        updateColorfulBorder(descriptors: descriptors, screens: screens)
        transitionPresentedOpacity(
            to: appearance.opacity,
            animated: shouldAnimate && shouldAnimateTransition(from: lastRenderSignature, to: signature)
        )
        lastRenderSignature = signature
    }

    private func applyOverlayLayout(
        screens: [NSScreen],
        descriptors: [WindowDescriptor],
        anchorWindowNumbers: [Int],
        screenFrames: [CGRect]
    ) {
        ensureOverlayWindowsMatchScreens(screens)

        for (index, screen) in screens.enumerated() {
            let overlay = overlayWindows[index]
            overlay.backgroundColor = appearance.color.withAlphaComponent(presentedOpacity)
            overlay.order(.below, relativeTo: anchorWindowNumbers[index])
            syncOverlayFrameIfNeeded(overlay, screen: screen)
        }

        currentAnchorWindowNumbers = anchorWindowNumbers
        currentScreenFrames = screenFrames
        _ = descriptors
    }

    private func ensureOverlayWindowsMatchScreens(_ screens: [NSScreen]) {
        let requiresRebuild =
            overlayWindows.count != screens.count ||
            zip(overlayWindows, screens).contains(where: { overlay, screen in
                overlay.screen !== screen || overlay.frame != screen.frame
            })

        guard requiresRebuild else { return }

        removeAllOverlays()
        overlayWindows = screens.map(makeOverlayWindow(for:))
    }

    private func makeOverlayWindow(for screen: NSScreen) -> NSWindow {
        let overlay = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )

        overlay.isReleasedWhenClosed = false
        overlay.animationBehavior = .none
        overlay.backgroundColor = appearance.color.withAlphaComponent(presentedOpacity)
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.transient, .fullScreenNone]
        overlay.level = .normal
        return overlay
    }

    private func syncOverlayFrameIfNeeded(_ overlay: NSWindow, screen: NSScreen) {
        guard overlay.frame != screen.frame else { return }
        overlay.setFrame(screen.frame, display: false)
    }

    private func transitionPresentedOpacity(
        to targetOpacity: Double,
        animated: Bool,
        restartFromOpacity: Double? = nil
    ) {
        let startOpacity = restartFromOpacity ?? presentedOpacity

        guard startOpacity != targetOpacity || animationState != nil else { return }

        guard animated, appearance.animationDuration > 0 else {
            animationState = nil
            presentedOpacity = targetOpacity
            applyPresentedOpacity()
            if targetOpacity == 0 {
                removeAllOverlays()
            }
            return
        }

        startDisplayLinkIfNeeded()
        boostObservationWindow()
        animationState = AnimationState(
            startOpacity: startOpacity,
            targetOpacity: targetOpacity,
            startTimestamp: nil,
            duration: appearance.animationDuration
        )
    }

    private func applyPresentedOpacity() {
        let color = appearance.color.withAlphaComponent(presentedOpacity)
        overlayWindows.forEach { $0.backgroundColor = color }
    }

    private func shouldAnimateTransition(from previous: RenderSignature?, to current: RenderSignature) -> Bool {
        guard let previous else { return true }

        return previous.anchorWindowNumbers != current.anchorWindowNumbers ||
            previous.screenFrames != current.screenFrames
    }

    private func removeAllOverlays() {
        overlayWindows.forEach { $0.close() }
        overlayWindows.removeAll()
    }

    // MARK: - Display Link (CVDisplayLink)

    private func startDisplayLinkIfNeeded() {
        guard displayLinkWrapper == nil else { return }
        let wrapper = CVDisplayLinkWrapper()
        wrapper.start { [weak self] timestamp in
            Task { @MainActor [weak self] in
                guard let self, isActive else { return }
                handleDisplayLinkTick(timestamp: timestamp)
            }
        }
        displayLinkWrapper = wrapper
    }

    private func stopDisplayLink() {
        displayLinkWrapper?.stop()
        displayLinkWrapper = nil
    }

    private func handleDisplayLinkTick(timestamp: TimeInterval) {
        // Track delta time
        let deltaTime: TimeInterval = if lastDisplayLinkTimestamp > 0 {
            timestamp - lastDisplayLinkTimestamp
        } else {
            0
        }
        lastDisplayLinkTimestamp = timestamp
        accumulatedDeltaTime += deltaTime

        // Print active window position with dedup on every tick
        let descriptors = WindowDescriptor.onScreenWindows()
        let focusedBounds = descriptors.first?.bounds
        if focusedBounds != lastPrintedFocusedBounds {
            lastPrintedFocusedBounds = focusedBounds
            frameReportCount += 1
            if let focusedBounds {
                print("[\(frameReportCount)] Focused window frame: \(focusedBounds.debugDescription) | dt: \(String(format: "%.4f", deltaTime))s | total: \(String(format: "%.4f", accumulatedDeltaTime))s")
            } else {
                print("[\(frameReportCount)] Focused window frame: unavailable | dt: \(String(format: "%.4f", deltaTime))s | total: \(String(format: "%.4f", accumulatedDeltaTime))s")
            }
        }

        // Update colorful border position every tick
        updateColorfulBorder(descriptors: descriptors, screens: NSScreen.screens)

        stepAnimation(at: timestamp)

        guard timestamp >= nextObservationTimestamp else { return }

        renderCurrentState(force: false, shouldAnimate: true)
        nextObservationTimestamp = timestamp + displayLinkInterval(at: timestamp)
    }

    // MARK: - Observation

    private func startObservingActivationChanges() {
        guard activationObserver == nil else { return }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh(withDelay: true)
            }
        }
    }

    private func stopObservingActivationChanges() {
        guard let activationObserver else { return }

        NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        self.activationObserver = nil
    }

    private func startObservingScreenChanges() {
        guard screenParametersObserver == nil else { return }

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.boostObservationWindow(duration: 0.6)
                self?.renderCurrentState(force: true, shouldAnimate: true)
            }
        }
    }

    private func stopObservingScreenChanges() {
        guard let screenParametersObserver else { return }

        NotificationCenter.default.removeObserver(screenParametersObserver)
        self.screenParametersObserver = nil
    }

    private func boostObservationWindow(duration: TimeInterval = 0.6) {
        let now = CACurrentMediaTime()
        nextObservationTimestamp = now
        boostedObservationDeadline = max(boostedObservationDeadline, now + duration)
    }

    private func displayLinkInterval(at timestamp: TimeInterval) -> TimeInterval {
        timestamp < boostedObservationDeadline ? (1.0 / 30.0) : 0.25
    }

    private func stepAnimation(at timestamp: TimeInterval) {
        guard var animationState else { return }

        if animationState.startTimestamp == nil {
            animationState.startTimestamp = timestamp
            self.animationState = animationState
        }

        guard let startTimestamp = animationState.startTimestamp else { return }
        let progress = min(max((timestamp - startTimestamp) / animationState.duration, 0), 1)
        let easedProgress = 1 - pow(1 - progress, 3)
        presentedOpacity = animationState.startOpacity + (animationState.targetOpacity - animationState.startOpacity) * easedProgress
        applyPresentedOpacity()

        guard progress >= 1 else { return }

        presentedOpacity = animationState.targetOpacity
        applyPresentedOpacity()
        self.animationState = nil
        if presentedOpacity == 0 {
            removeAllOverlays()
        }
    }

    private func updateColorfulBorder(descriptors: [WindowDescriptor], screens: [NSScreen]) {
        guard appearance.showColorfulBorder,
              let focused = descriptors.first,
              let bounds = focused.bounds
        else {
            removeColorfulBorder()
            return
        }

        let borderWindow: ColorfulBorderWindow
        if let existing = colorfulBorderWindow {
            borderWindow = existing
        } else {
            borderWindow = ColorfulBorderWindow()
            colorfulBorderWindow = borderWindow
            borderWindow.fadeIn()
        }

        if lastBorderAnchorWindowNumber != 0, lastBorderAnchorWindowNumber != focused.number {
            borderWindow.resetFade()
            lastBorderCornerRadius = queryWindowCornerRadius(windowNumber: focused.number) ?? 16
        } else if lastBorderAnchorWindowNumber == 0 {
            lastBorderCornerRadius = queryWindowCornerRadius(windowNumber: focused.number) ?? 16
        }
        lastBorderAnchorWindowNumber = focused.number

        borderWindow.borderView.setRenderMode(
            appearance.colorfulBorderRenderMode == .noiseOnly ? .noiseOnly : .full
        )
        borderWindow.borderView.setActivityAmplitude(appearance.colorfulBorderAmplitude)
        borderWindow.update(
            focusedWindowBounds: bounds,
            anchorWindowNumber: focused.number,
            cornerRadius: lastBorderCornerRadius,
            screens: screens
        )
    }

    private func removeColorfulBorder() {
        colorfulBorderWindow?.close()
        colorfulBorderWindow = nil
    }

    private func anchorWindowNumbers(
        for descriptors: [WindowDescriptor],
        screens: [NSScreen]
    ) -> [Int] {
        switch appearance.mode {
        case .frontmostWindow:
            screens.map { _ in descriptors.first?.number ?? 0 }
        case .frontmostWindowPerScreen:
            screens.map { screen in
                let screenBounds = screen.frame.asWindowServerBounds(in: screens)
                let descriptor = descriptors.first { descriptor in
                    guard let bounds = descriptor.bounds else { return false }
                    return screenBounds.contains(bounds.center)
                }

                return descriptor?.number ?? 0
            }
        }
    }
}

// MARK: - CVDisplayLink Wrapper

private final class CVDisplayLinkWrapper {
    private var link: CVDisplayLink?
    private var onTick: ((TimeInterval) -> Void)?

    func start(onTick: @escaping (TimeInterval) -> Void) {
        self.onTick = onTick
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnSuccess }
            let wrapper = Unmanaged<CVDisplayLinkWrapper>.fromOpaque(userInfo).takeUnretainedValue()
            wrapper.onTick?(CACurrentMediaTime())
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())

        CVDisplayLinkStart(link)
    }

    func stop() {
        guard let link else { return }
        CVDisplayLinkStop(link)
        self.link = nil
        onTick = nil
    }

    deinit {
        if link != nil { stop() }
    }
}
