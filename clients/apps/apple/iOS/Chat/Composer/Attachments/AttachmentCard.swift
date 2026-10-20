import SwiftUI

/// The one surface of the attachment flow: glass whose frame, corners and fill change together, so the
/// + button's glass grows into the menu, the menu into the camera or photo window, and each folds back the
/// same way. The card takes exactly the frame it is given. Its content keeps its own size, sits on the card's
/// centre unless the overlay offsets it, and is clipped by the card, so nothing inside is laid out again
/// while the card moves.
struct AttachmentCard<Content: View>: View {
    let surface: AttachmentSurface
    /// Out of the button. Folded onto it the card is the button's own glass, so it casts no shadow yet.
    let raised: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: surface == .menu ? 34 : 44, style: .continuous)
        let menu = surface == .menu
        Color.clear
            .overlay { content }
            .background { fill(shape) }
            .clipShape(shape)
            .commaGlass(in: shape)
            // The menu's rows are still, so its shadow can follow the glass. A window's shadow comes from a plate
            // behind it instead: a shadow cast by the card itself is redrawn off screen for every frame of the live
            // camera inside it. The plate has the window's own fill, which the window covers, so the glass reads
            // the same over it as over the fill.
            .shadow(color: .black.opacity(raised && menu ? 0.12 : 0), radius: raised && menu ? 24 : 0, y: 8)
            .background {
                shape.fill(surface == .camera ? Color.black : CommaTheme.bgPrimary)
                    .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
                    .opacity(raised && !menu ? 1 : 0)
                    .animation(AttachmentMotion.fill, value: menu)
            }
    }

    /// The menu is the native menu's material, Liquid Glass alone: over a 50% grey checkerboard the system
    /// menu reads 216 and this card 220, where a frosted fill read 240. The camera's black and the photos'
    /// page colour arrive early in the resize, so the glass never lingers as a grey half-way tone.
    private func fill(_ shape: RoundedRectangle) -> some View {
        ZStack {
            shape.fill(Color.black).opacity(surface == .camera ? 1 : 0)
            shape.fill(CommaTheme.bgPrimary).opacity(surface == .photos ? 1 : 0)
        }
        .animation(AttachmentMotion.fill, value: surface)
    }
}

/// One axis of the card's frame, as its two edges. The card animates its edges rather than a scale, so its
/// corners and glass stay true at every size and its content is never laid out again.
struct CardEdges: ViewModifier, @preconcurrency Animatable {
    let axis: Axis
    var edges: AnimatablePair<CGFloat, CGFloat>

    init(_ axis: Axis, _ lower: CGFloat, _ upper: CGFloat) {
        self.axis = axis
        edges = AnimatablePair(lower, upper)
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { edges }
        set { edges = newValue }
    }

    func body(content: Content) -> some View {
        let length = max(0, edges.second - edges.first)
        switch axis {
        case .horizontal: content.frame(width: length).offset(x: edges.first)
        case .vertical: content.frame(height: length).offset(y: edges.first)
        }
    }
}

/// One spring moves the card both ways, so its glass, its rows and the + button read as one piece. Opening
/// starts in the tap's own frame: the card grows out of the button as solid glass, 90% out in about 105ms
/// and within a point of rest by about 165ms with no visible bounce, while the button's + fades under it and
/// the rows sharpen in where they will rest. Closing runs the same spring back: the rows leave at once, and
/// the card shrinks onto the button, which is back by about 115ms, and hides there. A native menu's 12%
/// bounce suits its clear droplet; on this card it reads as a heavy slab settling.
enum AttachmentMotion {
    /// The card's frame, its content's resting offset and its shadow, and the + button's opacity, both ways.
    static let morph = Animation.spring(response: 0.2, dampingFraction: 0.88)
    /// Starts with the glass, so the rows have arrived when it has.
    static let contentIn = Animation.easeOut(duration: 0.15)
    static let contentOut = Animation.easeOut(duration: 0.08)
    /// Closing, the card's glass fades into the button's over the spring's last stretch onto it.
    static let dissolve = Animation.easeOut(duration: 0.1).delay(0.06)
    /// Menu to window and back: the card's frame and corners, settling in about 0.3s without a bounce.
    static let resize = Animation.spring(response: 0.3, dampingFraction: 0.9)
    /// During a resize the leaving content goes at once and the arriving content follows the frame, so the
    /// menu's rows and the window never show through each other.
    static let leave = Animation.easeOut(duration: 0.08)
    static let arrive = Animation.easeOut(duration: 0.16).delay(0.08)
    /// The window's own fill, ahead of the frame.
    static let fill = Animation.easeOut(duration: 0.12)
    static let reduced = Animation.easeInOut(duration: 0.2)
}
