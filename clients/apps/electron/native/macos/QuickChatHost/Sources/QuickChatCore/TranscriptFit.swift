import CoreGraphics

/// How the transcript fills its box: at the largest size while it fits, then
/// smaller as it grows, then at the smallest size taller than the box.
public enum TranscriptFit {
    public struct Result: Equatable, Sendable {
        public var fontSize: CGFloat
        /// How far the text at `fontSize` is taller than the box.
        public var overflow: CGFloat
    }

    /// The largest size, in `step`s from `minimum` to `maximum`, whose text is
    /// no taller than `height`. `textHeight` grows with the size, because a
    /// larger size wraps into more and taller lines.
    public static func fit(
        height: CGFloat,
        maximum: CGFloat,
        minimum: CGFloat,
        step: CGFloat = 0.5,
        textHeight: (CGFloat) -> CGFloat
    ) -> Result {
        let largest = textHeight(maximum)
        if largest <= height { return Result(fontSize: maximum, overflow: 0) }
        let smallest = textHeight(minimum)
        if smallest > height { return Result(fontSize: minimum, overflow: smallest - height) }

        // `low` fits and `high` does not, both counted in steps above `minimum`.
        var low = 0
        var high = Int(((maximum - minimum) / step).rounded(.up))
        while high - low > 1 {
            let middle = (low + high) / 2
            if textHeight(minimum + CGFloat(middle) * step) <= height {
                low = middle
            } else {
                high = middle
            }
        }
        return Result(fontSize: minimum + CGFloat(low) * step, overflow: 0)
    }
}
