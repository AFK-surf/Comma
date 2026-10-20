import AppKit
import QuartzCore

/// The private Core Animation pieces NameDrop is built from: a backdrop layer
/// that samples what is behind the window, and filters. Every access is by name.
enum CoreAnimationPrivate {
    /// Lets layers in `window` sample and blend with what is behind it:
    /// compositing filters (plusL, colorDodge, multiply) then mix with other
    /// apps' windows, as SpringBoard's layers do on iOS.
    static func hostLayersInWindowServer(_ window: NSWindow) {
        set(window, "canHostLayersInWindowServer", true)
    }

    /// A layer showing the window server's content behind it, through `filters`.
    static func backdropLayer() -> CALayer {
        guard let type = NSClassFromString("CABackdropLayer") as? CALayer.Type else {
            preconditionFailure("CABackdropLayer is unavailable")
        }
        let layer = type.init()
        set(layer, "groupName", UUID().uuidString)
        set(layer, "windowServerAware", true)
        set(layer, "allowsGroupBlending", true)
        return layer
    }

    static func filter(_ type: String, _ values: [String: Any] = [:]) -> NSObject {
        guard let filterClass = NSClassFromString("CAFilter"),
              let filter = (filterClass as AnyObject)
                .perform(NSSelectorFromString("filterWithType:"), with: type)?
                .takeUnretainedValue() as? NSObject
        else { preconditionFailure("CAFilter \(type) is unavailable") }
        for (key, value) in values { filter.setValue(value, forKey: key) }
        return filter
    }

    private static func set(_ object: NSObject, _ key: String, _ value: Any) {
        let setter = NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):")
        precondition(object.responds(to: setter), "\(type(of: object)) has no \(key)")
        object.setValue(value, forKey: key)
    }
}
