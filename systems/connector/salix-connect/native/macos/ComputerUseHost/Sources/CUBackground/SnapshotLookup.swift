import CoreGraphics
import Foundation

/// Public helpers around the on-disk snapshot store. Used by
/// `BackgroundModeRuntime` to find the CGWindowID a snapshot points at so
/// the colorful border can attach around the right window.
public enum BackgroundSnapshotLookup {
    /// CGWindowID for the snapshot's target window, or `nil` if the
    /// snapshot can't be loaded (stale id, file gone, etc.).
    public static func cgWindowID(forSnapshot snapshotID: String) -> CGWindowID? {
        guard let metadata = try? ComputerUseSnapshotStore.load(snapshotID: snapshotID) else {
            return nil
        }
        return CGWindowID(metadata.windowID)
    }
}
