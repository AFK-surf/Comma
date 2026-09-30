import AppKit
import Foundation

@MainActor
protocol OverlayWindowSource: AnyObject {
    var overlayWindows: [NSWindow] { get }
}

@MainActor
final class OverlayWindowRegistry {
    static let shared = OverlayWindowRegistry()

    private struct WeakSource {
        weak var value: AnyObject?
    }

    private var sources: [WeakSource] = []

    private init() {}

    func register(_ source: OverlayWindowSource) {
        cleanup()

        let identifier = ObjectIdentifier(source)
        if sources.contains(where: { weakSource in
            guard let value = weakSource.value else { return false }
            return ObjectIdentifier(value) == identifier
        }) {
            return
        }

        sources.append(WeakSource(value: source))
    }

    func excludedWindowIDs() -> Set<UInt32> {
        cleanup()

        var ids = Set<UInt32>()
        for case let source as OverlayWindowSource in sources.compactMap(\.value) {
            for window in source.overlayWindows where window.windowNumber > 0 {
                ids.insert(UInt32(window.windowNumber))
            }
        }
        return ids
    }

    private func cleanup() {
        sources.removeAll { $0.value == nil }
    }
}
