import CoreGraphics

public enum NotchExpandedSizing {
    case intrinsic
    case clamped(min: CGSize, max: CGSize)
    case fixed(CGSize)
}
