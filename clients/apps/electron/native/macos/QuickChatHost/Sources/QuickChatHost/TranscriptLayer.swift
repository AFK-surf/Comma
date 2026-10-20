import AppKit
import CoreText
import QuartzCore
import QuickChatCore

/// The words being said, in a box above the Dock.
///
/// Each character is its own vector layer, so the text can shrink without
/// blurring. TextKit sets the lines, as it does in the editor, so the words
/// stay in place when they open for editing. Characters appear one at a time as they are recognized, with no
/// animation: one per frame, more per frame when the recognizer delivers a
/// burst, so the text never trails the voice. The text is as large as fits
/// the box, centered in it; once it no longer fits it shrinks, and at the
/// smallest size it grows above the box up to `maximumHeight`. Taller still,
/// it scrolls to its last line, under a fade at each edge with more text
/// beyond, and a scroll over it shows the earlier lines. Sending moves it: it
/// leaves with the wave.
@MainActor
final class TranscriptLayer {
    let layer = CALayer()

    nonisolated static let maximumSize: CGFloat = 24
    nonisolated static let minimumSize: CGFloat = 15
    /// Line height as a multiple of the size; the box holds three lines at the largest size.
    nonisolated static let leading: CGFloat = 1.3
    nonisolated static var boxHeight: CGFloat { (maximumSize * leading).rounded() * 3 }
    /// Seven lines at the smallest size.
    nonisolated static var maximumHeight: CGFloat { (minimumSize * leading).rounded() * 7 }
    /// A burst is shown over at most this many frames.
    private static let catchUpFrames = 6
    /// The fade at an edge with more text beyond it.
    private static let fadeHeight: CGFloat = 28
    /// An edge's fade deepens over this much hidden text, so it comes and goes with a scroll.
    private static let fadeRamp: CGFloat = 6
    static let wordColor = NSColor.white.withAlphaComponent(0.96).cgColor
    private static let hintColor = NSColor.white.withAlphaComponent(0.5).cgColor

    /// A hint is dimmer than the words. While Quick Chat waits for words
    /// (listening, or preparing to), a band of light sweeps across the hint.
    /// A message that stays after the dim has cleared (a failed send) is
    /// drawn like the words.
    enum PlaceholderStyle {
        case waiting
        case hint
        case message
    }

    private let content = CALayer()
    /// Set like the words at the largest size, as one outline with a halo,
    /// and a lighter copy of it for the band of light. The copy has no halo,
    /// so the band moves without redrawing the halo.
    private let placeholder = CALayer()
    private let hint = CAShapeLayer()
    private let shine = CAShapeLayer()
    private let band = CAGradientLayer()
    private let fade = CAGradientLayer()
    private var glyphs: [Glyph] = []
    /// How many of `glyphs` are shown; the rest wait for the next frames.
    private var shown = 0
    private var reveal: Timer?
    private var fontSize = TranscriptLayer.maximumSize
    private var scroll = TranscriptScroll()

    /// True while the text is taller than its box.
    var scrolls: Bool { scroll.overflow > 0 }
    /// How far the text is scrolled back from its last line.
    var scrolledBack: CGFloat { scroll.offset }

    /// Where the words are drawn, in the layer's coordinates, as far as the
    /// box shows them; nil with none.
    var wordsRect: CGRect? {
        var rect = CGRect.null
        for glyph in glyphs {
            guard let ink = glyph.layer.path?.boundingBoxOfPath, !ink.isNull else { continue }
            rect = rect.union(ink.offsetBy(dx: content.position.x + glyph.layer.position.x,
                                           dy: content.position.y + glyph.layer.position.y))
        }
        rect = rect.intersection(layer.bounds)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    private struct Glyph {
        let character: Character
        let layer: CAShapeLayer
        var line: Int
    }

    init() {
        layer.masksToBounds = false
        content.anchorPoint = .zero
        // A close dark halo: white text stays readable over white windows.
        for text in [content, hint] {
            text.shadowColor = NSColor.black.cgColor
            text.shadowOpacity = 0.6
            text.shadowRadius = 8
            text.shadowOffset = .zero
        }
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        shine.anchorPoint = .zero
        shine.fillColor = NSColor.white.cgColor
        band.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.8).cgColor,
                       NSColor.white.withAlphaComponent(0).cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        shine.mask = band
        placeholder.addSublayer(hint)
        placeholder.addSublayer(shine)
        layer.addSublayer(placeholder)
        layer.addSublayer(content)
    }

    /// `frame` is as high as the text can grow, `maximumHeight`; the box is at its bottom.
    func layout(frame: CGRect) {
        withoutActions {
            layer.frame = frame
            content.frame = CGRect(origin: .zero, size: frame.size)
            fade.frame = layer.bounds
            let edge = Double(Self.fadeHeight / frame.height)
            fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        }
    }

    /// Clears the text and shows `placeholder` until words arrive.
    func reset(placeholder text: String, style: PlaceholderStyle) {
        stopReveal()
        withoutActions {
            for glyph in glyphs { glyph.layer.removeFromSuperlayer() }
            glyphs = []
            shown = 0
            fontSize = Self.maximumSize
            scroll = TranscriptScroll()
            layer.mask = nil
            content.removeAllAnimations()
            content.filters = nil
            content.opacity = 1
            content.transform = CATransform3DIdentity
            content.position = .zero
            showPlaceholder(text, style: style)
            placeholder.removeAllAnimations()
            placeholder.opacity = 1
        }
    }

    func setPlaceholder(_ text: String, style: PlaceholderStyle) {
        withoutActions { showPlaceholder(text, style: style) }
    }

    /// Wraps `text` in the box and centers it, in the same lines and place as
    /// words of the largest size.
    private func showPlaceholder(_ text: String, style: PlaceholderStyle) {
        let layout = Self.layout(text, size: Self.maximumSize, width: layer.bounds.width)
        let outline = CGMutablePath()
        for item in layout.items {
            outline.addPath(item.path, transform: CGAffineTransform(translationX: item.origin.x, y: item.origin.y))
        }
        hint.path = outline
        shine.path = outline
        shine.frame = CGRect(x: 0, y: 0, width: layer.bounds.width, height: layout.height)
        placeholder.position = CGPoint(x: 0, y: (Self.boxHeight - layout.height) / 2)
        hint.fillColor = style == .message ? Self.wordColor : Self.hintColor
        let waiting = style == .waiting && glyphs.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        shimmer(across: waiting ? outline.boundingBoxOfPath : nil)
    }

    /// Sweeps the band across `ink` for 1.4 s, then rests 0.6 s, until the
    /// hint goes; nil stops it. Core Animation runs it, with no work here per frame.
    private func shimmer(across ink: CGRect?) {
        band.removeAnimation(forKey: "shimmer")
        guard let ink, !ink.isNull else { return }
        let width = Self.maximumSize * 3
        // At rest the band is before the text, so the copy shows nothing.
        band.frame = CGRect(x: ink.minX - width, y: ink.minY - 4, width: width, height: ink.height + 8)
        let sweep = CAKeyframeAnimation(keyPath: "position.x")
        sweep.values = [ink.minX - width / 2, ink.maxX + width / 2, ink.maxX + width / 2]
        sweep.keyTimes = [0, 0.7, 1]
        sweep.duration = 2
        sweep.repeatCount = .infinity
        band.add(sweep, forKey: "shimmer")
    }

    /// Shows `text`, keeping the characters it shares with what is shown.
    /// Characters that replace shown ones (a corrected phrase) appear at
    /// once; the ones after appear one by one over the next frames, or at
    /// once when `revealed` (words that were already on screen, in the editor).
    func setText(_ text: String, revealed: Bool = false) {
        let characters = Array(text)
        var kept = 0
        while kept < min(glyphs.count, characters.count), glyphs[kept].character == characters[kept] {
            kept += 1
        }

        let width = layer.bounds.width
        let fit = Self.fit(text, width: width)
        let layout = Self.layout(text, size: fit.fontSize, width: width)
        let resized = fit.fontSize != fontSize
        fontSize = fit.fontSize
        scroll.setOverflow(layout.height - layer.bounds.height)

        withoutActions {
            for glyph in glyphs[kept...] { glyph.layer.removeFromSuperlayer() }
            glyphs.removeSubrange(kept...)
            shown = revealed ? characters.count : min(shown, characters.count)

            for index in glyphs.indices {
                let item = layout.items[index]
                glyphs[index].line = item.line
                if resized { glyphs[index].layer.path = item.path }
                glyphs[index].layer.position = item.origin
            }
            for index in kept..<characters.count {
                let item = layout.items[index]
                let shape = CAShapeLayer()
                shape.fillColor = Self.wordColor
                shape.path = item.path
                shape.position = item.origin
                shape.isHidden = index >= shown
                content.addSublayer(shape)
                glyphs.append(Glyph(character: characters[index], layer: shape, line: item.line))
            }

            // Centered in the box while it fits, above it once it does not, scrolled once taller still.
            if scrolls {
                placeScrolledText()
            } else {
                content.position = CGPoint(x: 0, y: fit.overflow > 0 ? 0 : (Self.boxHeight - layout.height) / 2)
                layer.mask = nil
            }
            if !characters.isEmpty {
                placeholder.opacity = 0
                shimmer(across: nil)
            }
        }
        startReveal()
    }

    /// Scrolls the text back from its last line by `offset`, as the editor had it.
    func scroll(back offset: CGFloat) {
        guard scrolls else { return }
        scroll.scroll(by: offset - scroll.offset)
        withoutActions { placeScrolledText() }
    }

    /// A scroll wheel or trackpad over the box.
    func scroll(with event: NSEvent) {
        guard scrolls else { return }
        // A wheel counts lines; a trackpad counts points.
        let line = (fontSize * Self.leading).rounded()
        scroll.scroll(by: event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * line)
        withoutActions { placeScrolledText() }
    }

    /// Text taller than the box shows `scroll`'s lines, fading out at an edge
    /// with more text beyond it.
    private func placeScrolledText() {
        content.position = CGPoint(x: 0, y: -scroll.offset)
        fade.colors = [
            NSColor.white.withAlphaComponent(1 - Self.fadeDepth(hidden: scroll.hiddenBelow)).cgColor,
            NSColor.white.cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(1 - Self.fadeDepth(hidden: scroll.hiddenAbove)).cgColor,
        ]
        layer.mask = fade
    }

    private static func fadeDepth(hidden: CGFloat) -> CGFloat {
        min(1, hidden / fadeRamp)
    }

    /// The text leaves with the wave: each line, lowest first, rises
    /// `distance` and fades, blurring as it goes.
    func send(distance: CGFloat) {
        stopReveal()
        let base = CACurrentMediaTime()
        withoutActions {
            for glyph in glyphs { glyph.layer.isHidden = false }
            shown = glyphs.count
            // Each glyph leaves from what the fades showed of it, so none
            // brightens as they go; lines scrolled out of the box stay hidden.
            let opacities = glyphs.map { layer.mask == nil ? 1 : fadeOpacity($0) }
            layer.mask = nil
            content.filters = [CoreAnimationPrivate.filter("gaussianBlur", ["inputRadius": 0])]
            // The lowest line shown leaves first.
            let lastLine = glyphs.indices.filter { opacities[$0] > 0 }.map { glyphs[$0].line }.max() ?? 0
            // On NameDrop's tempo, leaving as the wave starts and gone in
            // about a sixth of a second.
            let tempo = NameDropEffect.Tuning.tempo
            for (glyph, opacity) in zip(glyphs, opacities) {
                guard opacity > 0 else {
                    glyph.layer.opacity = 0
                    continue
                }
                let fromBottom = Double(lastLine - glyph.line)
                // Lower lines leave first, by less than it takes them to reach the line above.
                let begin = (0.03 + fromBottom * 0.012) / tempo
                spring(glyph.layer, "transform.translation.y", from: 0, to: distance,
                       speed: Float(1.8 * tempo), begin: begin, base: base)
                spring(glyph.layer, "opacity", from: opacity, to: 0,
                       speed: Float(2.0 * tempo), begin: begin + 0.06 / tempo, base: base)
            }
            spring(content, "filters.gaussianBlur.inputRadius", from: 0, to: 10,
                   speed: Float(1.8 * tempo), begin: 0.06 / tempo, base: base)
            placeholder.opacity = 0
            shimmer(across: nil)
        }
    }

    /// The fades' opacity where they are dimmest over `glyph`: at the top or
    /// the bottom of its outline, or at the edge it reaches past. A glyph
    /// with no outline, such as a space, shows nothing.
    private func fadeOpacity(_ glyph: Glyph) -> Float {
        guard let ink = glyph.layer.path?.boundingBoxOfPath, !ink.isNull else { return 0 }
        let bottom = content.position.y + glyph.layer.position.y + ink.minY
        let top = bottom + ink.height
        /// How much of an edge's fade covers a point `inset` inside the box from it.
        func covered(_ inset: CGFloat) -> CGFloat { min(1, max(0, 1 - inset / Self.fadeHeight)) }
        let below = 1 - Self.fadeDepth(hidden: scroll.hiddenBelow) * covered(bottom)
        let above = 1 - Self.fadeDepth(hidden: scroll.hiddenAbove) * covered(layer.bounds.height - top)
        return Float(min(below, above))
    }

    /// Esc: the text goes with the hint.
    func cancel() {
        stopReveal()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.15
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        withoutActions {
            content.opacity = 0
            placeholder.opacity = 0
            shimmer(across: nil)
        }
        content.add(fade, forKey: "opacity")
        placeholder.add(fade, forKey: "opacity")
    }

    // MARK: Reveal

    private func startReveal() {
        guard shown < glyphs.count, reveal == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealNext() }
        }
        RunLoop.main.add(timer, forMode: .common)
        reveal = timer
        revealNext()
    }

    private func revealNext() {
        let waiting = glyphs.count - shown
        guard waiting > 0 else { return stopReveal() }
        let count = max(1, (waiting + Self.catchUpFrames - 1) / Self.catchUpFrames)
        withoutActions {
            for glyph in glyphs[shown..<(shown + count)] { glyph.layer.isHidden = false }
        }
        shown += count
    }

    private func stopReveal() {
        reveal?.invalidate()
        reveal = nil
    }

    // MARK: Layout

    private struct Layout {
        var height: CGFloat
        /// One per character: where it sits (its first glyph's pen position,
        /// y up from the bottom of the text), its outline and its line.
        var items: [(origin: CGPoint, path: CGPath, line: Int)]
    }

    static func font(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .medium)
    }

    /// Centered lines of a fixed height, `leading` times the size.
    static func paragraph(size: CGFloat) -> NSParagraphStyle {
        let line = (size * leading).rounded()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = line
        paragraph.maximumLineHeight = line
        return paragraph
    }

    /// The size `text` is set at in a box `width` wide.
    static func fit(_ text: String, width: CGFloat) -> TranscriptFit.Result {
        TranscriptFit.fit(height: boxHeight, maximum: maximumSize, minimum: minimumSize) { size in
            layout(text, size: size, width: width).height
        }
    }

    private static func layout(_ text: String, size: CGFloat, width: CGFloat) -> Layout {
        let characters = Array(text)
        var characterAt: [Int] = []
        for (index, character) in characters.enumerated() {
            characterAt.append(contentsOf: repeatElement(index, count: character.utf16.count))
        }
        guard !characters.isEmpty else { return Layout(height: 0, items: []) }

        // TextKit, as the editor sets the words, so they do not move when it opens.
        let storage = NSTextStorage(string: text, attributes: [
            .font: font(size: size),
            .paragraphStyle: paragraph(size: size),
        ])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        // Characters the system font lacks (Chinese) take a fallback font here.
        storage.fixAttributes(in: NSRange(location: 0, length: storage.length))
        manager.ensureLayout(for: container)
        let height = manager.usedRect(for: container).height.rounded(.up)

        var origin = [CGPoint?](repeating: nil, count: characters.count)
        let outline = (0..<characters.count).map { _ in CGMutablePath() }
        var lineOf = [Int](repeating: 0, count: characters.count)
        var line = -1
        var lineEnd = 0
        var fragment = CGRect.zero
        for glyph in 0..<manager.numberOfGlyphs {
            if glyph >= lineEnd {
                var range = NSRange()
                fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
                lineEnd = NSMaxRange(range)
                line += 1
            }
            let index = manager.characterIndexForGlyph(at: glyph)
            let character = characterAt[index]
            // The glyph's baseline position, y up from the bottom of the text.
            let location = manager.location(forGlyphAt: glyph)
            let pen = CGPoint(x: fragment.minX + location.x, y: height - fragment.minY - location.y)
            let start = origin[character] ?? pen
            origin[character] = start
            lineOf[character] = line
            guard !manager.propertyForGlyph(at: glyph).contains(.null),
                  !manager.propertyForGlyph(at: glyph).contains(.controlCharacter),
                  let glyphFont = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont,
                  let path = CTFontCreatePathForGlyph(glyphFont, manager.cgGlyph(at: glyph), nil)
            else { continue }
            outline[character].addPath(path, transform: CGAffineTransform(translationX: pen.x - start.x, y: pen.y - start.y))
        }
        // A character with no glyph (a line break) sits where the one before it ends.
        var last = CGPoint.zero
        let items = characters.indices.map { index -> (origin: CGPoint, path: CGPath, line: Int) in
            let point = origin[index] ?? last
            last = point
            return (point, outline[index], lineOf[index])
        }
        return Layout(height: height, items: items)
    }

    // MARK: Animation

    /// NameDrop's spring (mass 2, stiffness 300, damping 50) at `speed`.
    private func spring(
        _ target: CALayer, _ keyPath: String, from: Any, to value: Any,
        speed: Float, begin: CFTimeInterval = 0, base: CFTimeInterval
    ) {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 2
        animation.stiffness = 300
        animation.damping = 50
        animation.fromValue = from
        animation.toValue = value
        animation.speed = 0.7 * speed
        animation.duration = animation.settlingDuration
        animation.beginTime = base + begin
        animation.fillMode = .backwards
        target.setValue(value, forKeyPath: keyPath)
        target.add(animation, forKey: keyPath)
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
