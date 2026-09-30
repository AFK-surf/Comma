import AppKit
import SwiftUI

@MainActor
final class NotchWindowManager {
    private var window: NotchWindow?
    private var hostingView: NotchPassthroughHostingView<NotchRootView>?
    private var lastPresentationState: NotchRuntimeModel.PresentationState = .collapsed
    private var glassStabilizationTask: Task<Void, Never>?

    func syncWindow(with model: NotchRuntimeModel) {
        guard model.overlayWindowFrame != .zero else { return }

        if window == nil || window?.screen?.notchDisplayID != model.selectedDisplayID {
            recreateWindow(with: model)
        }

        guard let window, let hostingView else { return }

        if hasMeaningfulFrameChange(window.frame, model.overlayWindowFrame) {
            window.setFrame(model.overlayWindowFrame, display: false)
        }
        let hostingFrame = NSRect(origin: .zero, size: model.overlayWindowFrame.size)
        if hasMeaningfulFrameChange(hostingView.frame, hostingFrame) {
            hostingView.frame = hostingFrame
        }
        hostingView.interactivePointProvider = { [weak model] point in
            model?.containsInteractivePoint(point) == true
        }

        if model.windowShouldBeVisible {
            presentWindow(window, for: model)
            syncGlassStabilization(
                for: model,
                window: window,
                didEnterExpanded: lastPresentationState != .expanded
                    && model.presentationState == .expanded
            )
        } else {
            stopGlassStabilization()
            window.orderOut(nil)
        }
        lastPresentationState = model.presentationState
    }

    func close() {
        stopGlassStabilization()
        window?.close()
        hostingView = nil
        window = nil
        lastPresentationState = .collapsed
    }

    private func recreateWindow(with model: NotchRuntimeModel) {
        close()

        let window = NotchWindow(
            contentRect: model.overlayWindowFrame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let hostingView = NotchPassthroughHostingView(
            rootView: NotchRootView(model: model)
        )
        hostingView.frame = .init(origin: .zero, size: model.overlayWindowFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.interactivePointProvider = { [weak model] point in
            model?.containsInteractivePoint(point) == true
        }
        hostingView.configureTransparentBacking()

        window.contentView = hostingView
        window.contentView?.configureTransparentBackingIfPossible()

        self.window = window
        self.hostingView = hostingView
    }

    private func presentWindow(_ window: NotchWindow, for model: NotchRuntimeModel) {
        if model.presentationState == .expanded {
            focusGlassWindow(window, reassert: lastPresentationState != model.presentationState)
        } else {
            window.orderFrontRegardless()
        }
    }

    private func focusGlassWindow(_ window: NotchWindow, reassert: Bool) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        guard reassert else { return }

        Task { @MainActor [weak window] in
            await Task.yield()
            guard let window, window.isVisible else { return }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard window.isVisible else { return }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func syncGlassStabilization(
        for model: NotchRuntimeModel,
        window: NotchWindow,
        didEnterExpanded: Bool
    ) {
        let usesExpandedGlass = model.configuration.materialStyle == .liquidGlass
            && model.presentationState == .expanded
        guard usesExpandedGlass else {
            stopGlassStabilization()
            return
        }
        guard didEnterExpanded, glassStabilizationTask == nil else { return }

        // AppKit can briefly replace the hosting view's transparent backing while
        // a newly-key expanded window settles its glass effect. Reassert only
        // during a bounded post-transition window; steady state does no polling.
        glassStabilizationTask = Task { @MainActor [weak window] in
            for _ in 0 ..< 3 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled, let window, window.isVisible else { return }
                window.contentView?.configureTransparentBackingIfPossible()
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    private func stopGlassStabilization() {
        glassStabilizationTask?.cancel()
        glassStabilizationTask = nil
    }

    private func hasMeaningfulFrameChange(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) > 0.5
            || abs(lhs.origin.y - rhs.origin.y) > 0.5
            || abs(lhs.size.width - rhs.size.width) > 0.5
            || abs(lhs.size.height - rhs.size.height) > 0.5
    }
}

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
