import AppKit

public enum BorderRenderMode: Sendable {
    /// Animated colorful gradient (active session).
    case full
    /// Monochrome noise only (paused / no-activity state).
    case noiseOnly
}

/// Visual knobs for `BorderOverlay`. Defaults match legacy ComputerUse so
/// the active-session look is identical to the foreground agent's previous
/// appearance.
public struct BorderAppearance: Sendable {
    /// 0…1 controls the color motion / breathing intensity. 0 ≈ paused,
    /// 1 ≈ fully active.
    public var activityAmplitude: Double
    public var renderMode: BorderRenderMode
    /// Default corner radius used when the caller doesn't override it on
    /// `attach(...)`.
    public var defaultCornerRadius: CGFloat
    /// Time after `attach(...)` before the border fades in.
    public var fadeInDelay: TimeInterval
    public var fadeInDuration: TimeInterval

    public init(
        activityAmplitude: Double = 1.0,
        renderMode: BorderRenderMode = .full,
        defaultCornerRadius: CGFloat = 10,
        fadeInDelay: TimeInterval = 0.18,
        fadeInDuration: TimeInterval = 0.18
    ) {
        self.activityAmplitude = activityAmplitude.clamped(to: 0 ... 1)
        self.renderMode = renderMode
        self.defaultCornerRadius = defaultCornerRadius
        self.fadeInDelay = max(0, fadeInDelay)
        self.fadeInDuration = max(0, fadeInDuration)
    }

    public static let `default` = BorderAppearance()
}
