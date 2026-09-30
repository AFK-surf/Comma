import AppKit

public enum ColorfulBorderRenderMode {
    case full
    case noiseOnly
}

public struct Appearance {
    public var color: NSColor
    public var opacity: Double
    public var mode: DimmingMode
    public var activationDelay: TimeInterval
    public var animationDuration: TimeInterval
    public var ignoresDesktop: Bool
    public var showColorfulBorder: Bool
    public var colorfulBorderAmplitude: Double
    public var colorfulBorderRenderMode: ColorfulBorderRenderMode

    public init(
        color: NSColor = .black,
        opacity: Double = 0.7,
        mode: DimmingMode = .frontmostWindow,
        activationDelay: TimeInterval = 0.2,
        animationDuration: TimeInterval = 0.18,
        ignoresDesktop: Bool = true,
        showColorfulBorder: Bool = false,
        colorfulBorderAmplitude: Double = 1.0,
        colorfulBorderRenderMode: ColorfulBorderRenderMode = .full
    ) {
        self.color = color
        self.opacity = opacity.clamped(to: 0 ... 1)
        self.mode = mode
        self.activationDelay = max(0, activationDelay)
        self.animationDuration = max(0, animationDuration)
        self.ignoresDesktop = ignoresDesktop
        self.showColorfulBorder = showColorfulBorder
        self.colorfulBorderAmplitude = colorfulBorderAmplitude.clamped(to: 0 ... 1)
        self.colorfulBorderRenderMode = colorfulBorderRenderMode
    }
}
