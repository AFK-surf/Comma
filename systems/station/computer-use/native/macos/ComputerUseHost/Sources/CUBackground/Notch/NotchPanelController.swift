import AppKit
import Combine
import Foundation
import SwiftUI

/// Observable state backing the macOS Notch Dynamic Island UI and its entrance animation.
///
/// Every visible string comes from the live session: the task name passed at
/// start, the app the agent is operating, and the action or thinking it is on
/// now. Until those exist the island shows one honest default, never filler.
@available(macOS 14.0, *)
@MainActor
public final class NotchViewModel: ObservableObject {
    /// Task name passed at session start; nil when the agent gave none.
    @Published public var taskTitle: String?
    /// The app the agent is operating, from its latest snapshot or start args.
    @Published public var activeAppName: String?
    /// What the agent is doing right now (latest action or thinking); nil
    /// until the first one arrives.
    @Published public var status: String?
    @Published public var presentationState: NotchPresentationState = .hidden
    @Published public var liveSample: NotchEntranceSample
    @Published public var isEntranceRunning: Bool = false
    @Published public var isHoveringPreview: Bool = false
    /// Set once the user pressed "Stop"; the island is collapsing away.
    @Published public private(set) var isStopping: Bool = false
    /// True while the pointer is hovering over the compact notch (drives Comma's
    /// tactile +3.5pt spring outset & subtle specular rim highlight).
    @Published public private(set) var isCompactHovered: Bool = false
    /// Whether the host menu bar is currently dark (controls the ActivityKit-style
    /// hairline keyline and Liquid Glass scrim density on floating Dynamic Island capsules).
    @Published public var isMenuBarDark: Bool

    public static let defaultTitle = "Comma Computer Use"
    public static let idleStatus = "Working on virtual desktop"

    @Published public var anchor: NotchAnchorMetrics
    public let stream: VirtualDesktopStream

    public var onCheckComputer: (() -> Void)?
    public var onToggleState: ((NotchPresentationState) -> Void)?
    /// True only when the most recent state transition was triggered by an explicit user click.
    public private(set) var lastTransitionWasUserInitiated: Bool = false
    /// Called once the island has collapsed after the user pressed "Stop".
    public var onStop: (() -> Void)?

    /// Schedules a delayed callback on the main actor and returns a cancellation handle.
    public typealias DelayScheduler = @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void

    public static func defaultDelayScheduler(
        delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> () -> Void {
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }

    private let scheduleAfter: DelayScheduler
    private var entranceStart: Date?
    private var entranceFinish: DispatchWorkItem?
    private var stopCancel: (() -> Void)?
    private var autoCollapseCancel: (() -> Void)?

    /// Spring used for compact ↔ expanded morphs on legacy notches (matches Comma NotchKit).
    static let morphAnimation: Animation = .smooth(duration: 0.42, extraBounce: 0)
    /// Symmetric ~340ms spring used for floating Dynamic Island capsule expand & collapse morphs.
    static let capsuleExpandAnimation: Animation = .spring(response: 0.34, dampingFraction: 0.86)
    /// Slight 0.06s shell hold on collapse so expanded content finishes fading out before the mask shrinks.
    static let capsuleCollapseAnimation: Animation = .spring(response: 0.34, dampingFraction: 0.86).delay(0.06)
    /// Tactile hover spring matching Comma `NotchConfiguration.compactHoverAnimationConfiguration`.
    static let compactHoverAnimation: Animation = .spring(response: 0.29, dampingFraction: 0.79, blendDuration: 0.11)
    /// Subtle hover swell matching Comma `NotchConfiguration.compactHoverOutset`.
    public static let compactHoverOutset: CGFloat = 3.5
    /// Collapse back into the notch after "Stop": quicker than a morph, still
    /// without bounce, so the session ends the moment the user asked.
    static let exitAnimation: Animation = .spring(duration: 0.34, bounce: 0)
    static let exitDuration: TimeInterval = 0.34
    public static let entranceAutoCollapseDelay: TimeInterval = 2.6

    public init(
        anchor: NotchAnchorMetrics,
        stream: VirtualDesktopStream,
        taskTitle: String? = nil,
        activeAppName: String? = nil,
        isMenuBarDark: Bool? = nil,
        scheduleAfter: @escaping DelayScheduler = NotchViewModel.defaultDelayScheduler
    ) {
        self.anchor = anchor
        self.stream = stream
        self.taskTitle = Self.nonEmpty(taskTitle)
        self.activeAppName = Self.nonEmpty(activeAppName)
        self.isMenuBarDark = isMenuBarDark ?? Self.detectMenuBarDark()
        self.scheduleAfter = scheduleAfter
        self.liveSample = NotchEntranceSample.sample(elapsed: 0, anchor: anchor)
    }

    public static func detectMenuBarDark() -> Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// First line: the task name, else the app being operated.
    public var headline: String {
        taskTitle ?? activeAppName ?? Self.defaultTitle
    }

    /// Second line: the live action or thinking, else the honest idle line.
    public var statusLine: String {
        status ?? Self.idleStatus
    }

    /// Leading label of the compact pill.
    public var compactName: String {
        activeAppName ?? taskTitle ?? "Computer Use"
    }

    /// Plays the spring entrance: the island grows out of the hardware notch (or the
    /// top edge) into the expanded card, then tucks into the minimal compact state
    /// automatically if the user does not hover over it.
    public func playEntranceAnimation() {
        cancelEntrance()
        cancelAutoCollapse()
        isCompactHovered = false
        lastTransitionWasUserInitiated = false
        presentationState = .expanded
        liveSample = NotchEntranceSample.sample(elapsed: 0, anchor: anchor)
        isEntranceRunning = true
        onToggleState?(.expanded)
        scheduleAutoCollapseAfterEntrance()
    }

    /// Entrance geometry for a display frame. The clock starts at the first
    /// rendered frame, so window setup never eats the opening of the spring.
    func entranceSample(at date: Date) -> NotchEntranceSample {
        guard isEntranceRunning else {
            return NotchEntranceSample.sample(elapsed: NotchEntranceSample.totalDuration, anchor: anchor)
        }
        let start: Date
        if let entranceStart {
            start = entranceStart
        } else {
            start = date
            entranceStart = date
            let finish = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.finishEntrance() }
            }
            entranceFinish = finish
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchEntranceSample.totalDuration, execute: finish)
        }
        return NotchEntranceSample.sample(elapsed: date.timeIntervalSince(start), anchor: anchor)
    }

    private func finishEntrance() {
        entranceFinish = nil
        entranceStart = nil
        liveSample = NotchEntranceSample.sample(elapsed: NotchEntranceSample.totalDuration, anchor: anchor)
        isEntranceRunning = false
    }

    private func cancelEntrance() {
        entranceFinish?.cancel()
        entranceFinish = nil
        entranceStart = nil
        isEntranceRunning = false
    }

    private func cancelAutoCollapse() {
        autoCollapseCancel?()
        autoCollapseCancel = nil
    }

    private func scheduleAutoCollapseAfterEntrance() {
        cancelAutoCollapse()
        autoCollapseCancel = scheduleAfter(Self.entranceAutoCollapseDelay) { [weak self] in
            guard let self, !self.isStopping else { return }
            self.autoCollapseCancel = nil
            let pointerInExpanded = NotchDimensions.islandScreenRect(for: .expanded, anchor: self.anchor)
                .contains(NSEvent.mouseLocation)
            if self.presentationState == .expanded && !pointerInExpanded {
                self.setPresentationState(.compact, animated: true)
            }
        }
    }

    /// Mirrors Comma `NotchRuntimeModel.handleMouseMoved(at:)`: updates the tactile
    /// compact hover feedback (`isCompactHovered`) when hovering the collapsed notch.
    public func handleMouseMoved(at screenPoint: CGPoint) {
        guard !isStopping else {
            setCompactHovered(false)
            return
        }
        switch presentationState {
        case .compact:
            let inside = NotchDimensions.compactHitRect(for: anchor).contains(screenPoint)
            setCompactHovered(inside)
        case .expanded:
            if NotchDimensions.islandScreenRect(for: .expanded, anchor: anchor).contains(screenPoint) {
                cancelAutoCollapse()
            }
            setCompactHovered(false)
        case .hidden:
            setCompactHovered(false)
        }
    }

    public func setCompactHovered(_ hovered: Bool) {
        let resolved = (presentationState == .compact && !isStopping) ? hovered : false
        guard isCompactHovered != resolved else { return }
        withAnimation(Self.compactHoverAnimation) {
            isCompactHovered = resolved
        }
    }

    /// Mirrors Comma `NotchRuntimeModel.handleMouseDown(at:)`:
    /// - Compact: clicking inside `compactHitRect` expands to the full Liquid Glass card.
    /// - Expanded: clicking the top notch band (`compactHitRect`) or anywhere outside
    ///   `expandedRect` collapses back to the minimal compact pill; clicking inside the
    ///   expanded body leaves it open for controls (`previewTile`, `Check computer`, `Stop`).
    public func handleMouseDown(at screenPoint: CGPoint) {
        guard !isStopping else { return }
        let compactHit = NotchDimensions.compactHitRect(for: anchor)
        switch presentationState {
        case .hidden:
            return
        case .compact:
            guard compactHit.contains(screenPoint) else { return }
            setPresentationState(.expanded, animated: true, userInitiated: true)
        case .expanded:
            if anchor.isFloatingCapsule,
               NotchDimensions.expandedPreviewScreenRect(for: anchor).contains(screenPoint)
            {
                return
            }
            if compactHit.contains(screenPoint) {
                setPresentationState(.compact, animated: true)
                return
            }
            let expandedHit = NotchDimensions.islandScreenRect(for: .expanded, anchor: anchor)
            if !expandedHit.contains(screenPoint) {
                setPresentationState(.compact, animated: true)
            }
        }
    }

    /// Interactive screen-space hit test matching Comma `NotchRuntimeModel.containsInteractivePoint(_:)`.
    public func containsInteractivePoint(_ screenPoint: CGPoint) -> Bool {
        guard !isStopping else { return false }
        switch presentationState {
        case .hidden:
            return false
        case .compact:
            return NotchDimensions.compactHitRect(for: anchor).contains(screenPoint)
        case .expanded:
            return NotchDimensions.islandScreenRect(for: .expanded, anchor: anchor).contains(screenPoint)
        }
    }

    /// Shows what the agent is doing now (an action summary or its `thinking`)
    /// on the single status line, replacing the previous one.
    public func recordStatus(_ text: String, appName: String? = nil) {
        if let appName = Self.nonEmpty(appName) {
            activeAppName = appName
        }
        guard let line = Self.statusText(text) else { return }
        status = line
    }

    /// Collapses a multi-line thinking string onto one line.
    static func statusText(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    public func toggleCompactExpanded() {
        let next: NotchPresentationState = (presentationState == .expanded) ? .compact : .expanded
        setPresentationState(next)
    }

    public func setPresentationState(
        _ state: NotchPresentationState,
        animated: Bool = true,
        userInitiated: Bool = false
    ) {
        guard !isStopping else { return }
        cancelEntrance()
        cancelAutoCollapse()
        lastTransitionWasUserInitiated = userInitiated
        if state == .expanded {
            liveSample = NotchEntranceSample.sample(
                elapsed: NotchEntranceSample.totalDuration,
                anchor: anchor
            )
        }
        if state != .compact {
            isCompactHovered = false
        }
        if animated {
            let anim: Animation
            if anchor.isFloatingCapsule {
                anim = (state == .compact) ? Self.capsuleCollapseAnimation : Self.capsuleExpandAnimation
            } else {
                anim = Self.morphAnimation
            }
            withAnimation(anim) {
                presentationState = state
            }
        } else {
            presentationState = state
        }
        onToggleState?(state)
    }

    /// The user pressed "Stop": the island folds back into the notch, then
    /// `onStop` ends the session. Further presses are ignored.
    public func requestStop() {
        guard !isStopping else { return }
        isStopping = true
        cancelEntrance()
        cancelAutoCollapse()
        withAnimation(Self.exitAnimation) {
            presentationState = .hidden
        }
        onToggleState?(.hidden)
        stopCancel = scheduleAfter(Self.exitDuration) { [weak self] in
            guard let self else { return }
            self.stopCancel = nil
            self.onStop?()
        }
    }

    public func invalidate() {
        cancelEntrance()
        cancelAutoCollapse()
        stopCancel?()
        stopCancel = nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Non-activating borderless floating NSPanel anchored seamlessly to the display's top notch.
/// Mirrors Comma's `NotchWindow` (`styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel]`,
/// `becomesKeyOnlyIfNeeded = true`, `canBecomeKey = true`, `.statusBar + 8`) so macOS 26's
/// `.glassEffect(.clear, in:)` renders live Liquid Glass rather than an inactive dimmed surface.
@available(macOS 14.0, *)
public final class NotchPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        alphaValue = 1
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        // Click-through outside the visible island is handled by shrunken panel bounds +
        // `NotchPassthroughHostingView.hitTest(_:)` (exact parity with Comma's `NotchWindow`).
        ignoresMouseEvents = false
        isMovable = false
        isMovableByWindowBackground = false
        appearance = NSAppearance(named: .darkAqua)
        level = .statusBar + 8
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

/// Transparent passthrough NSHostingView matching Comma's `NotchPassthroughHostingView`:
/// keeps the backing CALayer non-opaque across AppKit glass layout passes and rejects hits
/// outside the visible island silhouette.
@available(macOS 14.0, *)
private final class NotchPassthroughHostingView<Content: View>: NSHostingView<Content> {
    var interactivePointProvider: ((NSPoint) -> Bool)?

    override var isOpaque: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        configureTransparentBacking()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureTransparentBacking()
        window?.contentView?.configureTransparentBackingIfPossible()
    }

    override func layout() {
        super.layout()
        configureTransparentBacking()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return nil }
        let screenPoint = window.convertPoint(toScreen: point)
        guard interactivePointProvider?(screenPoint) == true else { return nil }
        return super.hitTest(point) ?? self
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    func configureTransparentBacking() {
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
    }
}

private extension NSView {
    func configureTransparentBackingIfPossible() {
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
    }
}

/// Visual tokens shared by the island's text and controls.
@available(macOS 14.0, *)
enum NotchStyle {
    /// macOS dark-appearance system blue (#0A84FF).
    static let accent = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    static let accentHover = Color(red: 64 / 255, green: 156 / 255, blue: 1)
    static let titleFont = Font.system(size: 14, weight: .medium)
    static let statusFont = Font.system(size: 13)
    static let actionFont = Font.system(size: 13)
    static let stopFont = Font.system(size: 12.5, weight: .medium)
}

/// SwiftUI view rendered inside `NotchPanel`: a matte-black macOS Dynamic Island
/// with the live virtual desktop preview, the task name, one live status line,
/// and the "Check computer ↗" / "Stop" actions.
@available(macOS 14.0, *)
public struct NotchContentView: View {
    @ObservedObject public var viewModel: NotchViewModel
    @State private var isHoveringCheck = false
    @State private var isHoveringStop = false
    @State private var isPressingStop = false

    public init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
    }

    private func dimensions(
        sample: NotchEntranceSample?
    ) -> (width: CGFloat, height: CGFloat, ear: CGFloat, corner: CGFloat) {
        if let s = sample {
            return (s.width, s.height, s.earRadius, s.bottomCornerRadius)
        }
        let target = NotchDimensions.target(for: viewModel.presentationState, anchor: viewModel.anchor)
        return (target.bodyWidth, target.bodyHeight, target.earRadius, target.bottomCornerRadius)
    }

    public var body: some View {
        let running = viewModel.isEntranceRunning
        TimelineView(.animation(paused: !running)) { context in
            island(sample: running ? viewModel.entranceSample(at: context.date) : nil)
        }
    }

    /// Comma NotchKit Liquid Glass constants (`NotchHost/main.swift`).
    private static let liquidGlassHeight: CGFloat = 200
    private static let liquidGlassTransitionHeight: CGFloat = 86

    /// `sample` is the entrance frame while the entrance runs, else nil.
    @ViewBuilder
    private func island(sample: NotchEntranceSample?) -> some View {
        let dims = dimensions(sample: sample)
        let state = viewModel.presentationState
        let isCapsule = viewModel.anchor.isFloatingCapsule
        let isCapsuleCompactHovered = isCapsule && state == .compact && viewModel.isCompactHovered
        let hoverOutset: CGFloat = (!isCapsule && state == .compact && viewModel.isCompactHovered)
            ? NotchViewModel.compactHoverOutset
            : 0
        let capsuleHoverScale: CGFloat = isCapsuleCompactHovered ? NotchDynamicIslandLayout.hoverScale : 1.0
        let totalW = dims.width + dims.ear * 2 + hoverOutset * 2
        let height = max(0, dims.height + hoverOutset)
        let topOffset: CGFloat = isCapsule ? viewModel.anchor.topMargin : 0
        let cornerRadius: CGFloat = isCapsule
            ? min(dims.corner, height / 2)
            : (dims.corner + (hoverOutset > 0 ? 1.5 : 0))
        let shape = NotchSilhouetteShape(
            earRadius: dims.ear,
            bottomCornerRadius: cornerRadius,
            topCornerRadius: isCapsule ? cornerRadius : 0
        )

        ZStack(alignment: .top) {
            // Background shell stays outside `.compositingGroup()` so macOS 26's
            // `.glassEffect(.clear, in:)` keeps live backdrop refraction (1:1 with Comma NotchKit).
            shellBackground(width: totalW, height: height, shape: shape, state: state)
                .zIndex(0)

            // Content keeps its settled size and rides the island's walls while
            // it morphs: on legacy notches the preview stays pinned to bottom-left;
            // on floating Dynamic Island capsules it anchors top-left beside the camera.
            ZStack(alignment: .top) {
                if state == .expanded {
                    expandedContent(ear: dims.ear, sample: sample)
                        .transition(
                            isCapsule
                                ? .asymmetric(
                                    insertion: .opacity
                                        .combined(with: .scale(scale: 0.96, anchor: .top))
                                        .animation(.easeOut(duration: 0.17).delay(0.17)),
                                    removal: .opacity
                                        .combined(with: .scale(scale: 0.96, anchor: .top))
                                        .animation(.easeIn(duration: 0.07))
                                )
                                : .opacity.animation(.easeOut(duration: 0.22).delay(0.06))
                        )
                } else if state == .compact {
                    compactContent(ear: dims.ear, pillHeight: height)
                        .transition(
                            isCapsule
                                ? .asymmetric(
                                    insertion: .opacity.animation(.easeOut(duration: 0.12).delay(0.28)),
                                    removal: .opacity.animation(.easeIn(duration: 0.06))
                                )
                                : .opacity.animation(.easeOut(duration: 0.14))
                        )
                }
            }
            .frame(width: totalW, height: height, alignment: .top)
            .compositingGroup()
            .mask(alignment: .top) {
                shape
                    .fill(.white)
                    .frame(width: totalW, height: height)
            }
            .zIndex(1)
        }
        .scaleEffect(capsuleHoverScale, anchor: .center)
        .animation(
            isCapsuleCompactHovered
                ? .spring(response: 0.30, dampingFraction: 0.72)
                : .spring(response: 0.26, dampingFraction: 0.92),
            value: capsuleHoverScale
        )
        .padding(.top, topOffset)
        .opacity(state == .hidden ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }

    private func shellBackground(
        width: CGFloat,
        height: CGFloat,
        shape: NotchSilhouetteShape,
        state: NotchPresentationState
    ) -> some View {
        let isExpandedCapsule = state == .expanded && viewModel.anchor.isFloatingCapsule
        return shellSurface(width: width, height: height, shape: shape, state: state)
            .shadow(
                color: .black.opacity(primaryShellShadowOpacity(for: state)),
                radius: isExpandedCapsule ? 18 : 16,
                x: 0,
                y: isExpandedCapsule ? 8 : 9
            )
            .shadow(
                color: .black.opacity(secondaryShellShadowOpacity(for: state)),
                radius: isExpandedCapsule ? 3 : 4,
                x: 0,
                y: 1
            )
    }

    @ViewBuilder
    private func shellSurface(
        width: CGFloat,
        height: CGFloat,
        shape: NotchSilhouetteShape,
        state: NotchPresentationState
    ) -> some View {
        if viewModel.anchor.isFloatingCapsule {
            capsuleShellSurface(width: width, height: height, shape: shape, state: state)
        } else {
            #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    clearGlassShellSurface(width: width, height: height, shape: shape, state: state)
                } else {
                    blackShellSurface(width: width, height: height, shape: shape)
                }
            #else
                blackShellSurface(width: width, height: height, shape: shape)
            #endif
        }
    }

    /// Floating Dynamic Island capsule shell:
    /// - Compact / Hidden: pure opaque `#000000` (never lightens to grey on hover so the
    ///   OLED camera cutout stays invisible), with an ActivityKit-style 0.5pt hairline
    ///   keyline on dark menu bars only (`0.12` idle / `0.22` hovered).
    /// - Expanded: macOS 26+ Liquid Glass (`.glassEffect(.clear, in:)`) with a full-card
    ///   darkening scrim (pure black over the top 30% camera band fading to `0.72` light /
    ///   `0.55` dark at the bottom so text keeps ≥ 5:1 contrast while preserving live glass
    ///   refraction), plus a lower-half-only specular edge rim that avoids haloing the camera.
    @ViewBuilder
    private func capsuleShellSurface(
        width: CGFloat,
        height: CGFloat,
        shape: NotchSilhouetteShape,
        state: NotchPresentationState
    ) -> some View {
        if state == .expanded {
            #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    capsuleExpandedGlassSurface(width: width, height: height, shape: shape)
                } else {
                    capsuleOpaqueBlackSurface(width: width, height: height, shape: shape, hovered: false)
                }
            #else
                capsuleOpaqueBlackSurface(width: width, height: height, shape: shape, hovered: false)
            #endif
        } else {
            capsuleOpaqueBlackSurface(
                width: width,
                height: height,
                shape: shape,
                hovered: state == .compact && viewModel.isCompactHovered
            )
        }
    }

    private func capsuleOpaqueBlackSurface(
        width: CGFloat,
        height: CGFloat,
        shape: NotchSilhouetteShape,
        hovered: Bool
    ) -> some View {
        let keyline: Double = viewModel.isMenuBarDark ? (hovered ? 0.22 : 0.12) : 0
        return shape
            .fill(Color.black)
            .overlay {
                if keyline > 0 {
                    shape
                        .stroke(Color.white.opacity(keyline), lineWidth: 1)
                        .clipShape(shape)
                }
            }
            .frame(width: width, height: height)
            .contentShape(shape)
            .clipShape(shape)
            .allowsHitTesting(false)
    }

    #if compiler(>=6.2)
        @available(macOS 26.0, *)
        private func capsuleExpandedGlassSurface(
            width: CGFloat,
            height: CGFloat,
            shape: NotchSilhouetteShape
        ) -> some View {
            let floor: Double = viewModel.isMenuBarDark ? 0.55 : 0.72
            let midOpacity: Double = floor + (1 - floor) * 0.5
            let rimBottom: Double = viewModel.isMenuBarDark ? 0.18 : 0.14
            return shape
                .fill(Color.black.opacity(0.08))
                .frame(width: width, height: height)
                .contentShape(shape)
                .glassEffect(.clear, in: shape)
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.00),
                            .init(color: .black, location: 0.30),
                            .init(color: .black.opacity(midOpacity), location: 0.62),
                            .init(color: .black.opacity(floor), location: 1.00),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: width, height: height)
                    .clipShape(shape)
                    .allowsHitTesting(false)
                }
                .overlay {
                    shape
                        .stroke(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0), location: 0.00),
                                    .init(color: .white.opacity(0), location: 0.35),
                                    .init(color: .white.opacity(rimBottom), location: 1.00),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                        .frame(width: width, height: height)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                }
                .clipShape(shape)
        }
    #endif

    #if compiler(>=6.2)
        /// Exact Comma `NotchKitView.clearGlassShellSurface` material: clear macOS 26
        /// Liquid Glass over the lower half, solid black upper half fading smoothly down
        /// with a 4-stop gradient, 1pt white 16% edge chrome, and opaque black in compact state.
        @available(macOS 26.0, *)
        private func clearGlassShellSurface(
            width: CGFloat,
            height: CGFloat,
            shape: NotchSilhouetteShape,
            state: NotchPresentationState
        ) -> some View {
            let bottomTint: Double = state == .expanded ? 0.08 : (state == .compact ? 0.12 : 0)
            let opaqueOverlay: Double = state == .expanded ? 0 : 1
            let glassHeight = min(max(0, height * 0.5), Self.liquidGlassHeight)
            let solidBlackHeight = max(0, height - glassHeight)
            let transitionHeight = min(Self.liquidGlassTransitionHeight, glassHeight)

            return shape
                .fill(Color.black.opacity(bottomTint))
                .frame(width: width, height: height)
                .contentShape(shape)
                .glassEffect(.clear, in: shape)
                .overlay {
                    VStack(spacing: 0) {
                        Color.black.frame(height: solidBlackHeight)
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.82), location: 0.28),
                                .init(color: .black.opacity(0.30), location: 0.72),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: transitionHeight)
                        Spacer(minLength: 0)
                    }
                    .frame(width: width, height: height)
                    .clipShape(shape)
                    .allowsHitTesting(false)
                }
                .overlay {
                    shape
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                        .frame(width: width, height: height)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                }
                .overlay {
                    shape
                        .fill(.black)
                        .frame(width: width, height: height)
                        .opacity(opaqueOverlay)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                }
                .overlay {
                    if state == .compact && viewModel.isCompactHovered {
                        ZStack {
                            shape.fill(Color.white.opacity(0.06))
                            shape.stroke(Color.white.opacity(0.24), lineWidth: 1)
                        }
                        .frame(width: width, height: height)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                    }
                }
                .clipShape(shape)
        }
    #endif

    private func blackShellSurface(
        width: CGFloat,
        height: CGFloat,
        shape: NotchSilhouetteShape
    ) -> some View {
        ZStack {
            shape.fill(.black)
            if viewModel.presentationState == .compact && viewModel.isCompactHovered {
                shape.fill(Color.white.opacity(0.06))
                shape.stroke(Color.white.opacity(0.24), lineWidth: 1)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
    }

    private func primaryShellShadowOpacity(for state: NotchPresentationState) -> Double {
        guard state == .expanded else { return 0 }
        if viewModel.anchor.isFloatingCapsule { return 0.22 }
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) { return 0.18 }
        #endif
        return 0.32
    }

    private func secondaryShellShadowOpacity(for state: NotchPresentationState) -> Double {
        guard state == .expanded else { return 0 }
        if viewModel.anchor.isFloatingCapsule { return 0.10 }
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) { return 0.06 }
        #endif
        return 0.12
    }

    // MARK: - Expanded Layout

    @ViewBuilder
    private func expandedContent(ear: CGFloat, sample: NotchEntranceSample?) -> some View {
        let target = NotchDimensions.target(for: .expanded, anchor: viewModel.anchor)
        if viewModel.anchor.isFloatingCapsule {
            let previewFrame = NotchDynamicIslandLayout.expandedPreviewFrame(in: target)
            let detailsFrame = NotchDynamicIslandLayout.expandedDetailsFrame(in: target)

            ZStack(alignment: .topLeading) {
                previewTile
                    .frame(width: previewFrame.width, height: previewFrame.height)
                    .scaleEffect(sample?.previewScale ?? 1, anchor: .topLeading)
                    .opacity(sample?.previewOpacity ?? 1)
                    .offset(x: previewFrame.minX, y: previewFrame.minY)

                detailsColumn
                    .frame(width: detailsFrame.width, height: detailsFrame.height, alignment: .topLeading)
                    .opacity(sample?.detailsOpacity ?? 1)
                    .offset(x: detailsFrame.minX, y: detailsFrame.minY + (sample?.detailsOffsetY ?? 0))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let previewFrame = NotchExpandedLayout.previewFrame(in: target)
            let detailsFrame = NotchExpandedLayout.detailsFrame(in: target)

            ZStack {
                previewTile
                    .frame(width: previewFrame.width, height: previewFrame.height)
                    .scaleEffect(sample?.previewScale ?? 1, anchor: .bottomLeading)
                    .opacity(sample?.previewOpacity ?? 1)
                    .padding(.leading, previewFrame.minX)
                    .padding(.bottom, target.bodyHeight - previewFrame.maxY)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                detailsColumn
                    .frame(width: detailsFrame.width, height: detailsFrame.height, alignment: .topLeading)
                    .opacity(sample?.detailsOpacity ?? 1)
                    .offset(y: sample?.detailsOffsetY ?? 0)
                    .padding(.trailing, target.bodyWidth - detailsFrame.maxX)
                    .padding(.top, detailsFrame.minY)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .padding(.horizontal, ear)
        }
    }

    private var previewTile: some View {
        let radius = viewModel.anchor.isFloatingCapsule
            ? NotchDynamicIslandLayout.expandedPreviewCornerRadius
            : NotchExpandedLayout.previewCornerRadius
        let tileShape = RoundedRectangle(
            cornerRadius: radius,
            style: .continuous
        )
        return Button(action: { viewModel.onCheckComputer?() }) {
            VirtualDesktopSurfaceView(stream: viewModel.stream)
                .clipShape(tileShape)
                .overlay(alignment: .topTrailing) {
                    if viewModel.isHoveringPreview {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.95))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .padding(7)
                            .transition(.opacity)
                    }
                }
                .contentShape(tileShape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                viewModel.isHoveringPreview = hovering
            }
        }
        .help("Check computer")
    }

    /// Task name and live status hang from the preview's top edge; the action
    /// row sits on its bottom edge.
    private var detailsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(viewModel.headline)
                .font(NotchStyle.titleFont)
                .foregroundStyle(Color.white.opacity(0.96))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 18, alignment: .leading)

            statusRow
                .padding(.top, viewModel.anchor.isFloatingCapsule ? NotchDynamicIslandLayout.expandedTitleToStatusGap : 7)

            Spacer(minLength: 0)

            actionRow
        }
    }

    /// One live line: what the agent is doing right now. A new line fades in
    /// and settles 4pt upward while the old one fades out in place.
    private var statusRow: some View {
        HStack(alignment: .center, spacing: 8) {
            NotchActivityRing()
                .frame(width: 13, height: 13)

            ZStack(alignment: .leading) {
                NotchShimmerText(
                    text: viewModel.statusLine,
                    font: NotchStyle.statusFont,
                    base: Color.white.opacity(0.6),
                    highlight: Color.white.opacity(0.98)
                )
                .id(viewModel.statusLine)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 4)),
                    removal: .opacity
                ))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .frame(height: 18)
        .animation(.spring(duration: 0.38, bounce: 0), value: viewModel.statusLine)
    }

    private var actionRow: some View {
        HStack(alignment: .center, spacing: 12) {
            checkComputerButton
            Spacer(minLength: 0)
            stopButton
        }
        .frame(height: NotchExpandedLayout.actionRowHeight)
    }

    private var checkComputerButton: some View {
        Button(action: { viewModel.onCheckComputer?() }) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Check computer")
                    .font(NotchStyle.actionFont)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Color.white.opacity(isHoveringCheck ? 1.0 : 0.92))
            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
            .frame(height: NotchExpandedLayout.actionRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHoveringCheck = hovering
            }
        }
        .help("Open the agent's desktop in a window")
    }

    /// Ends the session: windows go back to the main screen, the virtual
    /// desktop and the island go away.
    private var stopButton: some View {
        Button(action: { viewModel.requestStop() }) {
            Text("Stop")
                .font(NotchStyle.stopFont)
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: NotchExpandedLayout.actionRowHeight)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(isPressingStop ? 0.28 : (isHoveringStop ? 0.22 : 0.16)))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(NotchPressStyle(isPressed: $isPressingStop))
        .disabled(viewModel.isStopping)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHoveringStop = hovering
            }
        }
        .help("Stop the agent and bring its windows back")
    }

    // MARK: - Minimal Compact Notch Layout (0pt protrusion below notch/menu bar)

    private func compactContent(ear: CGFloat, pillHeight: CGFloat) -> some View {
        let layout = NotchCompactLayout.self
        let thumbShape = RoundedRectangle(cornerRadius: layout.previewCornerRadius, style: .continuous)

        return Group {
                if viewModel.anchor.isFloatingCapsule {
                    // Floating iPhone-aligned Dynamic Island capsule: concentric mini live
                    // preview in the left cap, pure-black camera zone in the center, and a
                    // concentric `16pt` (`lineWidth: 2`) activity ring in the right cap.
                    let capsuleLayout = NotchDynamicIslandLayout.self
                    let capsuleThumbShape = RoundedRectangle(
                        cornerRadius: capsuleLayout.previewCornerRadius,
                        style: .continuous
                    )
                    HStack(alignment: .center, spacing: 0) {
                        HStack(spacing: 0) {
                            VirtualDesktopSurfaceView(stream: viewModel.stream)
                                .frame(
                                    width: capsuleLayout.previewSize.width,
                                    height: capsuleLayout.previewSize.height
                                )
                                .clipShape(capsuleThumbShape)
                                .overlay(
                                    capsuleThumbShape
                                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                                )
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, capsuleLayout.previewLeadingInset)
                        .frame(width: capsuleLayout.wingWidth, alignment: .leading)

                        Spacer().frame(width: max(capsuleLayout.minCutoutWidth, viewModel.anchor.notchWidth))

                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            NotchActivityRing(lineWidth: capsuleLayout.activityRingLineWidth)
                                .frame(
                                    width: capsuleLayout.activityRingSize,
                                    height: capsuleLayout.activityRingSize
                                )
                        }
                        .padding(.trailing, capsuleLayout.activityTrailingInset(forHeight: pillHeight))
                        .frame(width: capsuleLayout.wingWidth, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if viewModel.anchor.hasHardwareNotch {
                    // Symmetric minimal wings flanking the MacBook camera housing.
                    HStack(alignment: .center, spacing: 0) {
                        HStack {
                            VirtualDesktopSurfaceView(stream: viewModel.stream)
                                .frame(width: layout.previewSize.width, height: layout.previewSize.height)
                                .clipShape(thumbShape)
                        }
                        .frame(width: layout.notchedWingWidth, alignment: .center)

                        Spacer().frame(width: viewModel.anchor.notchWidth)

                        HStack {
                            NotchActivityRing()
                                .frame(width: 13, height: 13)
                        }
                        .frame(width: layout.notchedWingWidth, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    // Flush menu-bar pill on non-notched displays.
                    HStack(alignment: .center, spacing: 0) {
                        VirtualDesktopSurfaceView(stream: viewModel.stream)
                            .frame(width: layout.previewSize.width, height: layout.previewSize.height)
                            .clipShape(thumbShape)

                        Spacer().frame(width: layout.previewToStatusGap)

                        HStack(alignment: .center, spacing: 6) {
                            NotchActivityRing()
                                .frame(width: 12, height: 12)

                            ZStack(alignment: .leading) {
                                NotchShimmerText(
                                    text: viewModel.statusLine,
                                    font: .system(size: 12, weight: .regular),
                                    base: Color.white.opacity(0.58),
                                    highlight: Color.white.opacity(0.98)
                                )
                                .id(viewModel.statusLine)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 3)),
                                    removal: .opacity
                                ))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipped()
                            .animation(.spring(duration: 0.38, bounce: 0), value: viewModel.statusLine)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, layout.edgeInset)
                    .padding(.trailing, layout.trailingInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            viewModel.setCompactHovered(hovering)
        }
        .padding(.horizontal, ear)
        .help("Click to expand")
    }
}

/// Plain button style that reports the pressed state, so a control can tint
/// its own background while held.
@available(macOS 14.0, *)
struct NotchPressStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
    }
}

/// Subtle activity ring for the live status line: a faint track with a short
/// arc that turns steadily while the agent works.
@available(macOS 14.0, *)
struct NotchActivityRing: View {
    var lineWidth: CGFloat = 1.5
    private static let period: Double = 1.1

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: Self.period) / Self.period) * 360
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.white.opacity(0.88), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(angle - 90))
            }
            .padding(lineWidth / 2)
        }
    }
}

/// Single-line text with an Apple Intelligence–style light sweep: a soft bright
/// band glides across dimmer base text, then rests before the next pass.
@available(macOS 14.0, *)
struct NotchShimmerText: View {
    let text: String
    let font: Font
    let base: Color
    let highlight: Color

    /// Seconds for one sweep, then the pause before the next.
    private static let sweep: Double = 1.9
    private static let rest: Double = 0.7
    /// Half-width of the bright band as a fraction of the text width.
    private static let bandHalfWidth: Double = 0.22

    var body: some View {
        TimelineView(.animation) { context in
            let center = Self.bandCenter(at: context.date)
            label(base)
                .overlay {
                    label(highlight)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white, location: 0.5),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: UnitPoint(x: center - Self.bandHalfWidth, y: 0.5),
                                endPoint: UnitPoint(x: center + Self.bandHalfWidth, y: 0.5)
                            )
                        )
                }
        }
    }

    private func label(_ color: Color) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    static func bandCenter(at date: Date) -> Double {
        let period = sweep + rest
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        let u = min(1, phase / sweep)
        let eased = u * u * (3 - 2 * u)
        let start = -bandHalfWidth
        let end = 1 + bandHalfWidth
        return start + (end - start) * eased
    }
}

/// Owns the Notch floating panel lifecycle, coordinating the entrance animation,
/// native hover expand/collapse, exact click-through outside the visible island,
/// live virtual desktop preview stream, status updates, the "Check computer"
/// viewer (and its full-resolution capture), and the user's "Stop".
@available(macOS 14.0, *)
@MainActor
public final class NotchOverlayController {
    private var panel: NotchPanel?
    private var hostingView: NotchPassthroughHostingView<NotchContentView>?
    public private(set) var viewModel: NotchViewModel?
    private var viewerController: VirtualDesktopViewerController?

    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalDownMonitor: Any?
    private var localDownMonitor: Any?
    private var panelResizeWork: DispatchWorkItem?
    private var glassStabilizationTask: Task<Void, Never>?
    private var appearanceObserver: NSObjectProtocol?
    private var virtualDisplayID: CGDirectDisplayID?
    private var virtualDisplayBounds: CGRect = .zero

    public var onRestoreWindowsRequested: (() -> Void)?
    /// The user pressed "Stop" and the island has collapsed: end the session.
    public var onStopRequested: (() -> Void)?

    public init() {}

    public var isViewerOpen: Bool {
        viewerController != nil
    }

    static func selectHostScreen(excluding virtualDisplayID: CGDirectDisplayID?) -> NSScreen? {
        let physical = NSScreen.screens.filter { screen in
            guard let virtualDisplayID else { return true }
            let screenNum = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            return screenNum != virtualDisplayID
        }
        if let notched = physical.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        if let main = NSScreen.main, physical.contains(where: { $0 === main }) {
            return main
        }
        return physical.first
    }

    public func show(
        stream: VirtualDesktopStream,
        virtualDisplayID: CGDirectDisplayID? = nil,
        virtualDisplayBounds: CGRect,
        taskTitle: String? = nil,
        activeAppName: String? = nil,
        playEntrance: Bool = true
    ) {
        viewModel?.invalidate()
        self.virtualDisplayID = virtualDisplayID
        self.virtualDisplayBounds = virtualDisplayBounds

        guard let hostScreen = Self.selectHostScreen(excluding: virtualDisplayID) else { return }
        let anchor = NotchAnchorMetrics.from(screen: hostScreen)
        let frame = NotchDimensions.panelFrame(for: anchor, state: .expanded)

        let vm = NotchViewModel(
            anchor: anchor,
            stream: stream,
            taskTitle: taskTitle,
            activeAppName: activeAppName
        )
        vm.onCheckComputer = { [weak self] in
            guard let self else { return }
            self.openViewer(stream: stream, virtualDisplayBounds: self.virtualDisplayBounds)
        }
        vm.onToggleState = { [weak self, weak vm] state in
            let focusKey = (state == .expanded) && (vm?.lastTransitionWasUserInitiated == true)
            self?.syncPanelGeometryAndHitTest(for: state, focusKey: focusKey)
        }
        vm.onStop = { [weak self] in
            self?.closeViewer()
            self?.onStopRequested?()
        }
        viewModel = vm

        let panel = self.panel ?? NotchPanel(contentRect: frame)
        panel.setFrame(frame, display: true)
        let rootView = NotchContentView(viewModel: vm)
        let hosting = NotchPassthroughHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        hosting.interactivePointProvider = { [weak vm] screenPoint in
            vm?.containsInteractivePoint(screenPoint) == true
        }
        hosting.configureTransparentBacking()
        panel.contentView = hosting
        panel.contentView?.configureTransparentBackingIfPossible()
        hosting.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        panel.displayIfNeeded()

        self.panel = panel
        self.hostingView = hosting
        installPointerMonitors()
        if let existingObserver = appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(existingObserver)
        }
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak vm] _ in
            MainActor.assumeIsolated {
                vm?.isMenuBarDark = NotchViewModel.detectMenuBarDark()
            }
        }

        if playEntrance {
            vm.playEntranceAnimation()
        } else {
            vm.setPresentationState(.expanded, animated: false)
        }
        updatePointerInteraction(at: NSEvent.mouseLocation)
    }

    public func handleScreenParametersChanged(
        virtualDisplayID: CGDirectDisplayID?,
        virtualDisplayBounds: CGRect
    ) {
        self.virtualDisplayID = virtualDisplayID
        self.virtualDisplayBounds = virtualDisplayBounds
        guard let vm = viewModel, let hostScreen = Self.selectHostScreen(excluding: virtualDisplayID) else {
            return
        }
        let updatedAnchor = NotchAnchorMetrics.from(screen: hostScreen)
        vm.isMenuBarDark = NotchViewModel.detectMenuBarDark()
        if vm.anchor != updatedAnchor {
            vm.anchor = updatedAnchor
            syncPanelGeometryAndHitTest(for: vm.presentationState, focusKey: false)
        }
    }

    /// Shrinks the panel frame after collapsing to `.compact` (and expands it
    /// immediately before expanding) while keeping `ignoresMouseEvents` strictly
    /// gated to the visible black island rect so clicks beneath always pass through.
    private func syncPanelGeometryAndHitTest(for state: NotchPresentationState, focusKey: Bool) {
        panelResizeWork?.cancel()
        panelResizeWork = nil
        guard let panel, let viewModel else { return }

        switch state {
        case .expanded:
            panel.ignoresMouseEvents = false
            let expandedFrame = NotchDimensions.panelFrame(for: viewModel.anchor, state: .expanded)
            if panel.frame != expandedFrame {
                panel.setFrame(expandedFrame, display: true)
            }
            hostingView?.configureTransparentBacking()
            panel.contentView?.configureTransparentBackingIfPossible()
            if focusKey {
                focusGlassPanel(panel)
            } else {
                stopGlassStabilization()
                panel.orderFrontRegardless()
            }
            viewModel.handleMouseMoved(at: NSEvent.mouseLocation)

        case .compact:
            stopGlassStabilization()
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            viewModel.handleMouseMoved(at: NSEvent.mouseLocation)
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, let vm = self.viewModel,
                          vm.presentationState == .compact else { return }
                    let compactFrame = NotchDimensions.panelFrame(for: vm.anchor, state: .compact)
                    if panel.frame != compactFrame {
                        panel.setFrame(compactFrame, display: true)
                    }
                    self.hostingView?.configureTransparentBacking()
                    vm.handleMouseMoved(at: NSEvent.mouseLocation)
                }
            }
            panelResizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)

        case .hidden:
            stopGlassStabilization()
            panel.ignoresMouseEvents = true
        }
    }

    /// Mirrors Comma's `NotchWindowManager.focusGlassWindow` + `syncGlassStabilization`:
    /// activates live Liquid Glass when expanding on macOS 26+ without stealing app focus
    /// (because `NotchPanel` is `.nonactivatingPanel`) and keeps the transparent backing crisp.
    private func focusGlassPanel(_ panel: NotchPanel) {
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        stopGlassStabilization()
        glassStabilizationTask = Task { @MainActor [weak self, weak panel] in
            await Task.yield()
            guard !Task.isCancelled, let panel, panel.isVisible,
                  self?.viewModel?.presentationState == .expanded else { return }
            panel.contentView?.configureTransparentBackingIfPossible()
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
    }

    private func stopGlassStabilization() {
        glassStabilizationTask?.cancel()
        glassStabilizationTask = nil
    }

    private func installPointerMonitors() {
        removePointerMonitors()

        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            let point = NSEvent.mouseLocation
            DispatchQueue.main.async {
                self?.updatePointerInteraction(at: point)
            }
        }

        localMoveMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] event in
            self?.updatePointerInteraction(at: NSEvent.mouseLocation)
            return event
        }

        globalDownMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            let point = NSEvent.mouseLocation
            DispatchQueue.main.async {
                self?.handlePointerDown(at: point)
            }
        }

        localDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handlePointerDown(at: NSEvent.mouseLocation)
            return event
        }
    }

    private func removePointerMonitors() {
        if let m = globalMoveMonitor { NSEvent.removeMonitor(m); globalMoveMonitor = nil }
        if let m = localMoveMonitor { NSEvent.removeMonitor(m); localMoveMonitor = nil }
        if let m = globalDownMonitor { NSEvent.removeMonitor(m); globalDownMonitor = nil }
        if let m = localDownMonitor { NSEvent.removeMonitor(m); localDownMonitor = nil }
    }

    private func updatePointerInteraction(at screenPoint: CGPoint) {
        viewModel?.handleMouseMoved(at: screenPoint)
    }

    private func handlePointerDown(at screenPoint: CGPoint) {
        viewModel?.handleMouseDown(at: screenPoint)
    }

    /// Puts the agent's current action or thinking on the status line (and the
    /// viewer's subtitle).
    public func recordStatus(_ text: String, appName: String? = nil) {
        guard let viewModel else { return }
        viewModel.recordStatus(text, appName: appName)
        viewerController?.updateTitle(viewModel.headline)
        viewerController?.updateSubtitle(viewModel.statusLine)
    }

    /// Names the app the agent is operating, from a snapshot it just took.
    public func setActiveApp(_ name: String) {
        guard let viewModel else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, viewModel.activeAppName != trimmed else { return }
        viewModel.activeAppName = trimmed
        viewerController?.updateTitle(viewModel.headline)
    }

    /// Opens the full-size viewer. While it is open the stream captures at the
    /// virtual display's full pixel size, so text in the viewer is Retina-sharp;
    /// closing it drops back to the thumbnail size.
    public func openViewer(stream: VirtualDesktopStream, virtualDisplayBounds: CGRect) {
        if let existing = viewerController {
            existing.bringToFront()
            return
        }
        let viewer = VirtualDesktopViewerController(
            stream: stream,
            virtualDisplayID: virtualDisplayID,
            virtualDisplayBounds: virtualDisplayBounds,
            title: viewModel?.headline ?? NotchViewModel.defaultTitle,
            subtitle: viewModel?.statusLine ?? NotchViewModel.idleStatus
        )
        viewer.onBringWindowsBack = { [weak self] in
            self?.onRestoreWindowsRequested?()
        }
        viewer.onClose = { [weak self, weak stream] in
            stream?.setQuality(.preview)
            self?.viewerController = nil
        }
        viewerController = viewer
        stream.setQuality(.full)
        viewer.show()
    }

    public func closeViewer() {
        viewerController?.close()
        viewerController = nil
    }

    public func tearDown() {
        stopGlassStabilization()
        panelResizeWork?.cancel()
        panelResizeWork = nil
        if let obs = appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            appearanceObserver = nil
        }
        removePointerMonitors()
        closeViewer()
        viewModel?.invalidate()
        viewModel = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        hostingView = nil
    }
}
