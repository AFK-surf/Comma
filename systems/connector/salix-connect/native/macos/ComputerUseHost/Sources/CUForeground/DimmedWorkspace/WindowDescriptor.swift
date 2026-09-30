import AppKit
import CoreGraphics
import Foundation

struct WindowDescriptor {
    let number: Int
    let layer: Int
    let bounds: CGRect?
    let ownerPID: pid_t?
    let ownerName: String?
    let title: String?

    init?(dictionary: [String: Any]) {
        guard
            let number = dictionary[kCGWindowNumber as String] as? Int,
            let layer = dictionary[kCGWindowLayer as String] as? Int
        else {
            return nil
        }

        self.number = number
        self.layer = layer
        ownerPID = dictionary[kCGWindowOwnerPID as String] as? pid_t
        ownerName = dictionary[kCGWindowOwnerName as String] as? String
        title = dictionary[kCGWindowName as String] as? String

        if let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary {
            bounds = CGRect(dictionaryRepresentation: boundsDictionary)
        } else {
            bounds = nil
        }
    }

    static func onScreenWindows() -> [WindowDescriptor] {
        let options: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier

        return windows
            .compactMap(Self.init)
            .filter { $0.layer == 0 }
            .filter { $0.ownerPID != selfPID }
    }
}

// MARK: - SkyLight Private API for Window Corner Radii

@_silgen_name("SLSMainConnectionID")
private func SLSMainConnectionID() -> Int32

@_silgen_name("SLSWindowQueryWindows")
private func SLSWindowQueryWindows(_ cid: Int32, _ windows: CFArray, _ count: Int) -> CFTypeRef?

@_silgen_name("SLSWindowQueryResultCopyWindows")
private func SLSWindowQueryResultCopyWindows(_ result: CFTypeRef) -> CFTypeRef?

@_silgen_name("SLSWindowIteratorAdvance")
private func SLSWindowIteratorAdvance(_ iterator: CFTypeRef) -> Bool

@_silgen_name("SLSWindowIteratorGetWindowID")
private func SLSWindowIteratorGetWindowID(_ iterator: CFTypeRef) -> UInt32

@_silgen_name("SLSWindowIteratorGetResolvedCornerRadii")
private func SLSWindowIteratorGetResolvedCornerRadii(_ iterator: CFTypeRef) -> CFArray?

/// Queries the WindowServer for the resolved corner radii of the given window.
/// Returns the maximum corner radius, or `nil` if the query fails.
func queryWindowCornerRadius(windowNumber: Int) -> CGFloat? {
    let cid = SLSMainConnectionID()
    let windowIDs = [NSNumber(value: Int32(windowNumber))] as CFArray

    guard let queryResult = SLSWindowQueryWindows(cid, windowIDs, 1),
          let iterator = SLSWindowQueryResultCopyWindows(queryResult)
    else { return nil }

    guard SLSWindowIteratorAdvance(iterator) else { return nil }

    guard let radiiArray = SLSWindowIteratorGetResolvedCornerRadii(iterator) else { return nil }
    let count = CFArrayGetCount(radiiArray)
    guard count > 0 else { return nil }

    var maxRadius: Double = 0
    for i in 0 ..< count {
        let num = unsafeBitCast(CFArrayGetValueAtIndex(radiiArray, i), to: CFNumber.self)
        var val: Double = 0
        CFNumberGetValue(num, .float64Type, &val)
        maxRadius = max(maxRadius, val)
    }

    return maxRadius > 0 ? CGFloat(maxRadius) : nil
}
