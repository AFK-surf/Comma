import SwiftUI

/// The row of controls floating on a panel's bottom edge.
struct PanelControls<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let center: Center
    @ViewBuilder let trailing: Trailing

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(alignment: .bottom) {
                leading
                Spacer(minLength: 0)
                trailing
            }
            center
        }
        .padding(22)
        .commaGlassGroup(spacing: 16)
    }
}

/// A 44pt glass circle holding one Central icon.
struct PanelIconButton: View {
    let icon: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CentralIcon(icon, size: 22)
                .foregroundStyle(CommaTheme.textPrimary)
                .frame(width: 44, height: 44)
                .commaGlass(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(GlassButtonStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

/// A 44pt glass capsule for a panel's text action; prominent fills it with the brand colour. A press has one
/// response: interactive glass answers it by itself on iOS 26 (see `GlassButtonStyle`), so only the solid
/// capsule, and the material before iOS 26, scale under the finger.
struct PanelCapsuleStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && scalesOnPress
        surface(configuration.label
            .font(.body)
            .foregroundStyle(prominent ? .white : CommaTheme.textPrimary)
            .padding(.horizontal, 18)
            .frame(minHeight: 44))
            .scaleEffect(pressed ? 0.95 : 1)
            .animation(.easeOut(duration: pressed ? 0.05 : 0.15), value: pressed)
    }

    private var scalesOnPress: Bool {
        if prominent { return true }
        if #available(iOS 26.0, *) { return false }
        return true
    }

    /// Glass would mute the brand fill, so the prominent action is a solid capsule.
    @ViewBuilder private func surface(_ label: some View) -> some View {
        if prominent {
            label.background(CommaTheme.brandSolid, in: Capsule())
        } else {
            label.commaGlass(in: Capsule(), interactive: true)
        }
    }
}
