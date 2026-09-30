import AppKit
import CUShared
import Foundation

@MainActor
final class PermissionFlowBridge: DaemonPermissionBridgeProviding {
    private let window: PermissionAuthWindowController

    init() {
        window = PermissionAuthWindowController()
    }

    func showAuthorizationUI() -> String {
        window.show()
        return "Authorization window opened."
    }
}
