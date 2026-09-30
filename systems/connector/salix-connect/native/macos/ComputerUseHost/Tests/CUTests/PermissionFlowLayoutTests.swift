import AppKit
import SwiftUI
import XCTest
@testable import PermissionFlow

final class PermissionFlowLayoutTests: XCTestCase {
    @MainActor
    func testSettingsFocusDoesNotChangePanelHeight() {
        let controller = PermissionFlowController(configuration: .init(
            requiredAppURLs: [URL(fileURLWithPath: "/Applications/Comma Computer Use.app")],
            promptForAccessibilityTrust: false
        ))
        controller.guidanceSteps = [(pane: .accessibility, granted: true), (pane: .screenRecording, granted: false)]
        // Exercise widths around the instruction's wrapping threshold.
        for width in stride(from: 300.0, through: 560.0, by: 20.0) {
            func height(settingsFocused: Bool) -> CGFloat {
                controller.isSettingsFrontmost = settingsFocused
                let host = NSHostingView(rootView:
                    PermissionFlowPanelView(controller: controller).frame(width: width)
                )
                host.layoutSubtreeIfNeeded()
                return host.fittingSize.height
            }
            let inactive = height(settingsFocused: false)
            let active = height(settingsFocused: true)
            XCTAssertGreaterThan(inactive, 0)
            XCTAssertEqual(active, inactive, accuracy: 0.5,
                           "Focus changed panel height at width \(width)")
        }
    }
}
