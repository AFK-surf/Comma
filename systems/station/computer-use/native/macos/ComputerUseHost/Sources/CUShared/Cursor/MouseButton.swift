import Foundation

/// Mouse buttons. Used by `DaemonCursor` for choosing the down/up event
/// pair to drive, and by both modes' input dispatchers for the same.
public enum MouseButton: String, Sendable, Equatable {
    case left
    case right
    case middle
}
