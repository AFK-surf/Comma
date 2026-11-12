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

    /// The grant as a process started now would have it: asked of a new process (this executable's
    /// `--permissions-status`), as a running one keeps what it had when it started. Nil when it does not say. Ported
    /// from still.fail's Status.swift `fresh` (its `status` argument).
    public static func fresh(_ pane: PermissionPane) -> Bool? {
        guard let executable = Bundle.main.executablePath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--permissions-status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let said = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let permissions = said?["permissions"] as? [String: Any]
        return permissions?[pane == .screenRecording ? "screenRecording" : "accessibility"] as? Bool
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
