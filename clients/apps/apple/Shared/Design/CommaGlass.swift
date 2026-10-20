import SwiftUI

extension View {
    /// Liquid Glass on iOS 26 and later; a translucent material with a hairline on earlier systems. Without
    /// `shown` the control keeps its place and content but drops its glass, which on iOS 26 melts into a
    /// neighbouring glass shape in the same container instead of vanishing.
    /// `tint` colours the glass, as for a destructive or selected control.
    @ViewBuilder func commaGlass<S: Shape>(in shape: S, interactive: Bool = false, shown: Bool = true,
                                           tint: Color? = nil) -> some View {
        if #available(iOS 26.0, watchOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            self.glassEffect(shown ? (interactive ? glass.interactive() : glass) : .identity, in: shape)
        } else {
            // Before glass, a tinted control is the solid colour: material over it would wash it out.
            self.background(tint.map { AnyShapeStyle($0.opacity(shown ? 1 : 0)) }
                            ?? AnyShapeStyle(.regularMaterial.opacity(shown ? 1 : 0)), in: shape)
                .overlay(shape.stroke(CommaTheme.borderPrimary.opacity(shown ? 0.7 : 0), lineWidth: 0.5))
                .shadow(color: .black.opacity(shown ? 0.06 : 0), radius: 10, y: 3)
        }
    }

    /// A glass card floating over the conversation: the + attachment card and the composer's @ and / menu. Its
    /// content is clipped to the card, and once `raised` off the control it came from it casts the menus' shadow.
    func commaGlassCard<S: Shape>(in shape: S, raised: Bool = true) -> some View {
        clipShape(shape)
            .commaGlass(in: shape)
            .shadow(color: .black.opacity(raised ? 0.12 : 0), radius: 24, y: 8)
    }

    /// Lets neighbouring glass shapes blend and morph together on iOS 26 and later.
    @ViewBuilder func commaGlassGroup(spacing: CGFloat) -> some View {
        if #available(iOS 26.0, watchOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

/// Press feedback for a button drawn with interactive glass (`commaGlass(in:interactive: true)`). On iOS 26
/// the glass answers the touch itself, swelling and lighting under the finger, so the label adds nothing:
/// a second scale on top would fight it. Earlier systems have no interactive glass and get the tactile scale.
struct GlassButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, watchOS 26.0, *) {
            configuration.label
        } else {
            TactileButtonStyle(scale: scale).makeBody(configuration: configuration)
        }
    }
}
