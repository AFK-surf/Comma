import SwiftUI

// The vertical bar (iPhone Duo's status column) ships in the iOS 27.1 SDK. Older SDKs build
// these items for the horizontal navigation bar only.
extension ToolbarContent {
    @ToolbarContentBuilder func verticalBarPreferred() -> some ToolbarContent {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) { axisBehavior(.verticalPreferred) } else { self }
        #else
        self
        #endif
    }

    /// Keeps an item in the horizontal navigation bar when the system also shows a vertical bar.
    @ToolbarContentBuilder func horizontalBarOnly() -> some ToolbarContent {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) { axisBehavior(.horizontalOnly) } else { self }
        #else
        self
        #endif
    }
}

extension EnvironmentValues {
    var usesVerticalToolbar: Bool {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) { return toolbarVerticalEdge != nil }
        #endif
        return false
    }
}
