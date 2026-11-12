import AppKit
import PermissionFlow

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = PermissionFlowController(configuration: .init(
    requiredAppURLs: [Bundle.main.bundleURL],
    promptForAccessibilityTrust: false
))

// Render the actual drag card, including its localized label, without TCC grants.
for _ in 0..<2 {
    controller.showPanel()
    guard let panel = app.windows.first(where: { $0.isVisible }),
          let content = panel.contentView else {
        fatalError("Permission drag panel did not open")
    }
    content.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()
    precondition(content.bounds.height > 0, "Permission drag panel is empty")
    controller.closePanel()
}
print("PASS: packaged permission drag panel opens and reopens")
