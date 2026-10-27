import AppKit
import MCP

extension MacApp {
    /// The macOS app whose icon stands for this entry on Comma's Plugins page.
    public var iconBundleID: String {
        switch self {
        case .calendar: "com.apple.iCal"
        case .reminders: "com.apple.reminders"
        case .contacts: "com.apple.AddressBook"
        case .messages: BundleID.messages
        case .mail: BundleID.mail
        case .notes: BundleID.notes
        case .music: BundleID.music
        case .maps: "com.apple.Maps"
        case .system: "com.apple.systempreferences"
        case .vision: "com.apple.Preview"
        }
    }
}

/// `comma/appIcons`: each app's icon as base64 PNG, keyed by app; `mac` is Finder's,
/// which stands for the plugin itself. An app missing from this Mac is left out.
public enum CommaAppIcons: MCP.Method {
    public static let name = "comma/appIcons"
    public typealias Result = Value
}

public enum AppIcons {
    /// Twice the Plugins page's largest artwork, 44 points.
    static let pixels = 96

    @MainActor
    public static func report() -> Value {
        var icons: [String: Value] = [:]
        let entries = MacApp.allCases.map { ($0.rawValue, $0.iconBundleID) } + [("mac", "com.apple.finder")]
        for (key, bundleID) in entries {
            if let png = png(bundleID: bundleID) { icons[key] = .string(png.base64EncodedString()) }
        }
        return .object(["icons": .object(icons)])
    }

    @MainActor
    static func png(bundleID: String) -> Data? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
