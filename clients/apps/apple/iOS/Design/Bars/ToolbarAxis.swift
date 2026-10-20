import SwiftUI

// The vertical bar (iPhone Duo's status column) ships in the iOS 27.1 SDK. Older SDKs build
// these items for the horizontal navigation bar only.
extension ToolbarContent {
    /// Keeps an item in the horizontal navigation bar when the system also shows a vertical bar.
    @ToolbarContentBuilder func horizontalBarOnly() -> some ToolbarContent {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) { axisBehavior(.horizontalOnly) } else { self }
        #else
        self
        #endif
    }
}
