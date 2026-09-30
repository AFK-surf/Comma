import AppKit
import Foundation

enum SideChatPresentationPhase: String, Equatable {
    case closed
    case opening
    case interactive
    case open
    case closing
}

struct SideChatPresentationRect: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: NSRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }
}

struct SideChatPresentation: Equatable {
    let availableContentHeight: Double
    let revision: Int
    let phase: SideChatPresentationPhase
    let progress: Double
    let offsetX: Double
    let displayID: Int
    let screenFrame: SideChatPresentationRect
    let contentFrame: SideChatPresentationRect
    let windowFrame: SideChatPresentationRect
}
