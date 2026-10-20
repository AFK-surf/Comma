import CoreGraphics

/// Where text taller than its box is scrolled. It follows the last line as
/// words arrive. Scrolled back, it keeps the lines being read in place while
/// the text grows below them, until it is scrolled to the end again.
public struct TranscriptScroll: Equatable, Sendable {
    /// How far the text is taller than the box.
    public private(set) var overflow: CGFloat = 0
    /// How far the text is scrolled back from its last line, from 0 to `overflow`.
    public private(set) var offset: CGFloat = 0

    public init() {}

    /// The text changed and is now `overflow` taller than the box.
    public mutating func setOverflow(_ overflow: CGFloat) {
        let overflow = max(overflow, 0)
        // The text grows at the bottom: scrolling back by as much keeps the lines in place.
        if offset > 0 { offset = min(max(offset + overflow - self.overflow, 0), overflow) }
        self.overflow = overflow
    }

    /// A positive `delta` scrolls back toward the first line.
    public mutating func scroll(by delta: CGFloat) {
        offset = min(max(offset + delta, 0), overflow)
    }

    /// How much of the text is out of the box above it.
    public var hiddenAbove: CGFloat { overflow - offset }
    /// How much of the text is out of the box below it.
    public var hiddenBelow: CGFloat { offset }
}
