import Foundation

/// The shape and schedule of the fill wave, after the desktop's `draftFillMotion.ts`: a crest, `reach` em to each
/// side of its centre, crosses the filled text once from left to right at a constant speed. On the crest a glyph
/// grows from its baseline, lifts, and takes the brand blue; the glyphs after it on its line move aside, so the
/// line reflows instead of overlapping. Ahead of the crest and behind it the text is at rest, so the first and the
/// last frame are the field's own text.
///
/// Positions are in em from the left edge of the filled text, so the crest travels by visual distance, whatever
/// the script. Each later line starts `lineLag` em behind the one above it: the crest sweeps the lines together,
/// as the desktop's band does, and the slight lag reads as one wave running down the text.
struct DraftFillWave: Equatable {
    /// Crest half-width: about eight glyphs move together.
    static let reach = 4.0
    /// Crest travel while one glyph goes through the whole profile.
    static let profile = 2 * reach
    /// Size gain on the crest (the desktop's `GROW`).
    static let grow = 0.18
    /// Lift on the crest, in em: the native wave rises as it grows, as Messages' text effects do.
    static let rise = 0.12
    /// Crest travel between one line and the next.
    static let lineLag = 1.5
    /// The whole wave, from the crest's front edge on the first glyph to the last glyph at rest; the desktop's
    /// 25ms start delay plus its 725ms sweep. Longer text travels faster.
    static let duration = 0.75
    /// Reduce Motion: the filled text only takes the blue and gives it back, with no movement.
    static let fadeDuration = 0.6
    /// The crest colour's peak strength in the Reduce Motion fade.
    static let fadePeak = 0.7

    /// The first and last glyph positions, in em.
    let first: Double
    let last: Double

    /// The crest's centre at `progress` (0...1), in em. It starts `reach` before the first glyph and ends `reach`
    /// after the last, so neither end moves anything.
    func crest(at progress: Double) -> Double {
        first - Self.reach + min(1, max(0, progress)) * (last - first + Self.profile)
    }

    /// How strongly the crest holds a glyph at `position`: 0 at rest, 1 on its centre.
    func strength(at position: Double, progress: Double) -> Double {
        Self.bell((position - crest(at: progress)) / Self.reach)
    }

    /// A raised cosine over -1...1, flat at both ends: the desktop's `bell`.
    static func bell(_ z: Double) -> Double {
        0.5 + 0.5 * cos(.pi * min(1, max(-1, z)))
    }

    /// The crest's colour weights across its width, sampled for a gradient band that tints like `bell`.
    static let bandStops: [(location: Double, weight: Double)] = (0...8).map { index in
        let location = Double(index) / 8
        return (location, bell(location * 2 - 1))
    }

    /// The Reduce Motion fade's colour weight at `progress`: up and back, no movement.
    static func fade(at progress: Double) -> Double {
        fadePeak * sin(.pi * min(1, max(0, progress)))
    }

    /// One glyph's place on the crest's line: its centre and advance as laid out at rest.
    struct Glyph: Equatable {
        let center: Double
        let width: Double
    }

    /// The horizontal shift of each glyph on one line, in points, for the strengths given: each glyph sits right
    /// after the grown glyphs to its left, and its own growth spreads to both sides of its centre. `glyphs` are in
    /// visual order.
    static func shifts(_ glyphs: [Glyph], strengths: [Double]) -> [Double] {
        var push = 0.0
        return zip(glyphs, strengths).map { glyph, strength in
            let gain = glyph.width * grow * strength
            defer { push += gain }
            return push + gain / 2
        }
    }
}
