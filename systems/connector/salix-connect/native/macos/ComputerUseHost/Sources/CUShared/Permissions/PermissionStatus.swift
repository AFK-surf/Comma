import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct PermissionPaneStatus: Codable, Sendable, Equatable {
    public let pane: PermissionPane
    public let granted: Bool

    public init(pane: PermissionPane, granted: Bool) {
        self.pane = pane
        self.granted = granted
    }
}

public struct PermissionStatusReport: Codable, Sendable, Equatable {
    public let bundlePath: String?
    public let statuses: [PermissionPaneStatus]

    public init(bundlePath: String?, statuses: [PermissionPaneStatus]) {
        self.bundlePath = bundlePath
        self.statuses = statuses
    }

    public var allGranted: Bool {
        statuses.allSatisfy(\.granted)
    }

    public func pretty() -> String {
        var lines: [String] = []
        if let bundlePath {
            lines.append("daemon bundle: \(bundlePath)")
        }
        for entry in statuses {
            let flag = entry.granted ? "granted" : "missing"
            lines.append("  \(entry.pane.rawValue): \(flag)")
        }
        return lines.joined(separator: "\n")
    }
}

public enum PermissionStatusProbe {
    public static func check(_ pane: PermissionPane) -> Bool {
        switch pane {
        case .accessibility:
            AXIsProcessTrusted()
        case .screenRecording:
            CGPreflightScreenCaptureAccess()
        }
    }

    public static func report() -> PermissionStatusReport {
        let statuses = PermissionPane.allCases.map {
            PermissionPaneStatus(pane: $0, granted: check($0))
        }
        return PermissionStatusReport(
            bundlePath: Bundle.main.bundleURL.path,
            statuses: statuses
        )
    }
}
