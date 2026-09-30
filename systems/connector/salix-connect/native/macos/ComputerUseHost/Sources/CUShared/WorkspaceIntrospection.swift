import AppKit
import CoreGraphics
import Foundation

/// Pre-session workspace introspection. Legacy ComputerUse exposed these
/// as always-available runtime methods so an agent could discover what
/// apps / windows exist BEFORE calling `start` (and therefore before it
/// had any clue what string to put in `apps: [...]`). We expose the same
/// functionality as no-active-session-required daemon actions routed via
/// `SessionRegistry`.
@MainActor
public enum WorkspaceIntrospection {
    /// `list-applications`: dump every regular-activation app the user
    /// has running, one per line, with localized name + bundle id +
    /// hidden flag. Matches the output that `ForegroundExecutor`'s
    /// in-session `.listApplications` returns, so the agent sees the
    /// same shape whether it calls before or after `start`.
    public static func listApplicationsText() -> String {
        let lines = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> String? in
                guard let name = app.localizedName else { return nil }
                let bundle = app.bundleIdentifier ?? ""
                let hidden = app.isHidden ? " [hidden]" : ""
                return "\(name) (\(bundle))\(hidden)"
            }
        return lines.joined(separator: "\n")
    }

    /// `list-windows`: `CGWindowListCopyWindowInfo` snapshot restricted
    /// to on-screen, layer-0 windows (what the user can actually see),
    /// one per line.
    public static func listWindowsText() -> String {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return ""
        }
        let lines = raw.compactMap { info -> String? in
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            let number = info[kCGWindowNumber as String] as? Int ?? -1
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            let title = info[kCGWindowName as String] as? String ?? ""
            let bounds: String = {
                guard let dict = info[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: dict as CFDictionary)
                else { return "(no bounds)" }
                return "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
            }()
            if title.isEmpty {
                return "[\(number)] \(owner) \(bounds)"
            }
            return "[\(number)] \(owner) \"\(title)\" \(bounds)"
        }
        return lines.joined(separator: "\n")
    }
}
