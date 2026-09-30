import AppKit
import CoreGraphics
import Foundation
import OSLog

private let borderLogger = Logger(
    subsystem: "surf.comma.CommaComputerUse",
    category: "BorderOverlay"
)

/// User-facing API for drawing the animated colorful border around a window
/// or display. Both modes (foreground via `WindowManager`'s active window,
/// background per-action target) share this single implementation.
@MainActor
public final class BorderOverlay {
    private let window: ColorfulBorderWindow
    private var appearance: BorderAppearance
    private var attachedAnchor: Int?

    public init(appearance: BorderAppearance = .default) {
        window = ColorfulBorderWindow()
        self.appearance = appearance
        applyAppearance()
    }

    /// Pin the border around an existing CG window (identified by its
    /// CGWindowID). The border is placed below the target window so the
    /// window's chrome appears on top of the glow halo. Re-attaching to the
    /// same window is cheap and updates the placement to the window's
    /// current frame.
    public func attach(toCGWindow windowNumber: CGWindowID, cornerRadius: CGFloat? = nil) {
        guard let axBounds = lookupBounds(forCGWindowID: windowNumber) else {
            borderLogger.warning(
                "attach(cgWindow=\(windowNumber, privacy: .public)) skipped: CGWindowListCopyWindowInfo returned no bounds"
            )
            return
        }
        let radius = cornerRadius ?? appearance.defaultCornerRadius
        let wasAttached = attachedAnchor != nil

        borderLogger.info(
            "attach(cgWindow=\(windowNumber, privacy: .public)) ax=\(axBounds.debugDescription, privacy: .public) wasAttached=\(wasAttached, privacy: .public)"
        )

        // Daemon runs as `.accessory`; `animator().alphaValue = 1` (what
        // legacy `fadeIn()` relies on) silently doesn't animate in inactive
        // apps, so the window stays at alpha=0 forever. Set alpha directly
        // on the first attach instead of the delayed fade.
        if attachedAnchor == nil {
            window.alphaValue = 1
        }
        attachedAnchor = Int(windowNumber)
        window.update(
            focusedWindowBounds: axBounds,
            anchorWindowNumber: Int(windowNumber),
            cornerRadius: radius
        )
    }

    /// Toggle between active animated colorful state and the muted noise
    /// state used while the session is paused.
    public func setPaused(_ paused: Bool) {
        window.borderView.setActivityAmplitude(paused ? 0 : appearance.activityAmplitude)
        window.borderView.setRenderMode(paused ? .noiseOnly : Self.viewRenderMode(appearance.renderMode))
    }

    public func setActivityAmplitude(_ amplitude: Double) {
        appearance.activityAmplitude = amplitude.clamped(to: 0 ... 1)
        window.borderView.setActivityAmplitude(appearance.activityAmplitude)
    }

    public func setRenderMode(_ mode: BorderRenderMode) {
        appearance.renderMode = mode
        window.borderView.setRenderMode(Self.viewRenderMode(mode))
    }

    /// Tear down. The window is kept alive (cheap) so subsequent attaches
    /// don't pay the Metal-pipeline init cost; only its visibility changes.
    public func detach() {
        attachedAnchor = nil
        window.orderOut(nil)
    }

    private func applyAppearance() {
        window.borderView.setActivityAmplitude(appearance.activityAmplitude)
        window.borderView.setRenderMode(Self.viewRenderMode(appearance.renderMode))
    }

    private static func viewRenderMode(_ mode: BorderRenderMode) -> ColorfulBorderView.RenderMode {
        switch mode {
        case .full: .full
        case .noiseOnly: .noiseOnly
        }
    }

    // MARK: - CG window bounds lookup

    /// Returns the bounds of `windowNumber` in AX-screen space (y-down,
    /// origin top-left of primary display) — what `kCGWindowBounds` reports.
    private func lookupBounds(forCGWindowID windowNumber: CGWindowID) -> CGRect? {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard
            let infoList = CGWindowListCopyWindowInfo(options, windowNumber) as? [[String: Any]],
            let entry = infoList.first,
            let dict = entry[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: dict)
        else { return nil }
        return rect
    }
}
