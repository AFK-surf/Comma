import Foundation

/// The device a Task was sent from (`TaskSummary.clientPlatform`), by name. Every device shows the
/// desktop's laptop glyph, as on its Task panel.
func platformLabel(_ platform: String) -> String {
    switch platform {
    case "macos": "macOS"
    case "windows": "Windows"
    case "linux": "Linux"
    case "ios": "iOS"
    case "android": "Android"
    case "watchos": "watchOS"
    case "web": String(localized: "Web browser")
    default: String(localized: "Unknown device")
    }
}
