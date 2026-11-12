import Foundation

public enum PermissionPane: String, Codable, Sendable, CaseIterable {
    case accessibility
    case screenRecording = "screen_recording"

    public var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    public var purpose: String {
        switch self {
        case .accessibility:
            "Required for clicks, typing, and accessibility-tree inspection."
        case .screenRecording:
            "Required for window screenshots and coordinate-based clicks."
        }
    }
}
