import Foundation

/// Local per-machine preferences shared between Comma Electron and the macOS
/// Computer Use daemon (`<runtimeDirectory>/preferences.json`).
public enum ComputerUsePreferences {
    public struct Stored: Codable, Sendable, Equatable {
        public var showInNotch: Bool?

        public init(showInNotch: Bool? = nil) {
            self.showInNotch = showInNotch
        }
    }

    public static var preferencesURL: URL {
        DaemonPaths.runtimeDirectory.appendingPathComponent("preferences.json", isDirectory: false)
    }

    /// Whether Computer Use should launch its isolated virtual desktop and top
    /// Notch island. Defaults to `true` when unset or unreadable; `false` keeps
    /// target apps on the user's current screen in plain background mode.
    public static func showInNotch(from url: URL = preferencesURL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let value = stored.showInNotch
        else {
            return true
        }
        return value
    }

    public static func write(showInNotch: Bool, to url: URL = preferencesURL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Stored(showInNotch: showInNotch))
        try data.write(to: url, options: .atomic)
    }
}
