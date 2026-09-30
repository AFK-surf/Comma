import AppKit

public enum NotchWindowMetadata {
    public static let automationIdentifier = "NotchKit.Window"
    public static let title = "Notch"

    @MainActor
    public static func isAutomationWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == automationIdentifier
    }
}
