import SwiftUI

/// Marks the filled part of the composer's copy of the draft; the text before it stays at rest.
struct DraftFillMark: TextAttribute {}

/// Draws the composer's copy of the draft with the fill wave (`DraftFillWave`) on its marked glyphs: each glyph
/// grows, lifts and moves aside as the crest passes, and a brand-blue band, clipped to the glyphs, rides the
/// crest. Only drawing changes from frame to frame: the copy is laid out once, as the field lays out its text, and
/// SwiftUI interpolates `progress` and calls `draw` again, so each frame costs one pass over the glyphs.
///
/// Under Reduce Motion nothing moves: the marked glyphs take the blue and give it back.
struct DraftFillRenderer: TextRenderer {
    var progress: Double
    /// The text's em, so the wave scales with Dynamic Type.
    let em: CGFloat
    let reduced: Bool
    let tint: Color

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// Room for a grown glyph above its line and for the line's push past its trailing edge.
    var displayPadding: EdgeInsets {
        EdgeInsets(top: em * 0.5, leading: em * 0.25, bottom: em * 0.25, trailing: em)
    }

    /// Glyphs are placed here, not by the drawing: the field's text view keeps baselines off the pixel grid, and a
    /// glyph on the crest moves smoothly rather than in pixel steps.
    private static let drawing: Text.Layout.DrawingOptions = .disablesSubpixelQuantization

    private struct Glyph {
        let slice: Text.Layout.RunSlice
        let bounds: Text.Layout.TypographicBounds
        let line: Int
        let moves: Bool
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var filled: [Glyph] = []
        for (index, line) in layout.enumerated() {
            for run in line {
                guard run[DraftFillMark.self] != nil else {
                    run.forEach { drawAtRest($0, shift: 0, in: &context) }
                    continue
                }
                // Glyphs of right-to-left runs are not drawn apart, so their joins stay whole; they take the band.
                let moves = run.layoutDirection == .leftToRight
                filled += run.map { Glyph(slice: $0, bounds: $0.typographicBounds, line: index, moves: moves) }
            }
        }
        guard let firstLine = filled.first?.line else { return }
        let start = filled.map { $0.bounds.rect.minX }.min() ?? 0
        let positions = filled.map { glyph in
            Double((glyph.bounds.rect.midX - start) / em) + Double(glyph.line - firstLine) * DraftFillWave.lineLag
        }
        let wave = DraftFillWave(first: positions.min() ?? 0, last: positions.max() ?? 0)
        // A layer of its own for each line, so one line's band never tints another's grown glyphs.
        for (line, members) in Dictionary(grouping: filled.indices, by: { filled[$0].line }) {
            let bounds = lineBounds(members.map { filled[$0] })
            context.drawLayer { layer in
                guard !reduced else {
                    members.forEach { drawAtRest(filled[$0].slice, shift: 0, in: &layer) }
                    return paint(.color(tint.opacity(DraftFillWave.fade(at: progress))), over: bounds, in: &layer)
                }
                let ordered = members.sorted { filled[$0].bounds.rect.minX < filled[$1].bounds.rect.minX }
                let strengths = ordered.map { filled[$0].moves ? wave.strength(at: positions[$0], progress: progress) : 0 }
                let shifts = DraftFillWave.shifts(
                    ordered.map { DraftFillWave.Glyph(center: filled[$0].bounds.rect.midX, width: filled[$0].bounds.width) },
                    strengths: strengths)
                for (order, index) in ordered.enumerated() {
                    draw(filled[index], strength: strengths[order], shift: shifts[order], in: &layer)
                }
                // The band's centre on this line: the crest, less the line's lag, back in points.
                let lag = Double(line - firstLine) * DraftFillWave.lineLag
                let centre = start + CGFloat(wave.crest(at: progress) - lag) * em
                paint(band(at: centre), over: bounds, in: &layer)
            }
        }
    }

    /// One glyph, grown about its baseline centre, lifted and moved aside. A glyph past the crest is only moved
    /// aside, by the growth of the glyphs before it.
    private func draw(_ glyph: Glyph, strength: Double, shift: Double, in layer: inout GraphicsContext) {
        guard strength > 0.001 else { return drawAtRest(glyph.slice, shift: shift, in: &layer) }
        let anchor = CGPoint(x: glyph.bounds.rect.midX, y: glyph.bounds.origin.y)
        let scale = 1 + DraftFillWave.grow * strength
        var copy = layer
        copy.translateBy(x: anchor.x + shift, y: anchor.y - DraftFillWave.rise * strength * em)
        copy.scaleBy(x: scale, y: scale)
        copy.translateBy(x: -anchor.x, y: -anchor.y)
        copy.draw(glyph.slice, options: Self.drawing)
    }

    /// A glyph off the crest, at its place in the line or moved aside, its pen position on a whole pixel as the
    /// field's text view sets it. The baseline stays where the font puts it, as the field's does.
    private func drawAtRest(_ slice: Text.Layout.RunSlice, shift: CGFloat, in context: inout GraphicsContext) {
        let x = slice.typographicBounds.origin.x
        let scale = context.environment.displayScale
        let aligned = scale > 0 ? ((x + shift) * scale + 0.01).rounded(.down) / scale : x + shift
        var copy = context
        copy.translateBy(x: aligned - x, y: 0)
        copy.draw(slice, options: Self.drawing)
    }

    /// The crest's blue: a band `reach` em to each side of `centre`, as strong across it as the crest.
    private func band(at centre: CGFloat) -> GraphicsContext.Shading {
        let reach = CGFloat(DraftFillWave.reach) * em
        let stops = DraftFillWave.bandStops.map { Gradient.Stop(color: tint.opacity($0.weight), location: $0.location) }
        return .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: centre - reach, y: 0),
                               endPoint: CGPoint(x: centre + reach, y: 0))
    }

    /// Paints `shading` over `bounds` only where the layer already has glyphs, keeping their coverage.
    private func paint(_ shading: GraphicsContext.Shading, over bounds: CGRect, in layer: inout GraphicsContext) {
        var paint = layer
        paint.blendMode = .sourceAtop
        paint.fill(Path(bounds), with: shading)
    }

    /// The glyphs' line box, with room for a grown, lifted or pushed glyph.
    private func lineBounds(_ glyphs: [Glyph]) -> CGRect {
        glyphs.reduce(CGRect.null) { $0.union($1.bounds.rect) }.insetBy(dx: -em, dy: -em * 0.5)
    }
}
