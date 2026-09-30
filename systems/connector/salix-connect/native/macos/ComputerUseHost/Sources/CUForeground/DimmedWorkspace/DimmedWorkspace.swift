import AppKit

public enum DimmedWorkspace {
    @MainActor private static let coordinator = WorkspaceDimmingCoordinator()

    public static var appearance: Appearance {
        get { MainActor.assumeIsolated { coordinator.appearance } }
        set { MainActor.assumeIsolated { coordinator.updateAppearance(newValue) } }
    }

    public static var isActive: Bool {
        MainActor.assumeIsolated { coordinator.isActive }
    }

    @MainActor
    public static var overlayWindows: [NSWindow] {
        coordinator.allOverlayWindows
    }

    public static func activate() {
        MainActor.assumeIsolated { coordinator.activate() }
    }

    public static func deactivate() {
        MainActor.assumeIsolated { coordinator.deactivate() }
    }

    public static func refresh() {
        MainActor.assumeIsolated { coordinator.refresh(withDelay: false) }
    }
}
