import SwiftUI

/// What a row does, which sets its colours: a setting or a place to go, an action, or a destructive action.
enum SettingsRowRole {
    case standard, action, destructive

    var title: Color {
        switch self {
        case .standard: CommaTheme.textPrimary
        case .action: CommaTheme.brandSolid
        case .destructive: CommaTheme.errorPrimary
        }
    }

    var icon: Color { self == .standard ? CommaTheme.textSecondary : title }
}

/// A row's Central icon, when it has one, and its title. A disabled row greys both.
struct SettingsLabel: View {
    let title: Text
    var icon: String?
    var role = SettingsRowRole.standard
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                CentralIcon(icon, size: 20, relativeTo: .body)
                    .foregroundStyle(isEnabled ? role.icon : CommaTheme.textPlaceholder)
            }
            title.font(.body).foregroundStyle(isEnabled ? role.title : CommaTheme.textPlaceholder)
                .multilineTextAlignment(.leading)
        }
    }
}

/// A row: its label and current value, then whatever trails it (a chevron, a control). At accessibility text
/// sizes the value moves under the title, so neither is cut short. Put it in a `Button` or a `NavigationLink`
/// styled `SurfaceRowButtonStyle` to make it tappable.
struct SettingsRow<Trailing: View>: View {
    private let label: SettingsLabel
    private let value: Text?
    private let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The icon column and its gap, which a stacked value is indented by to sit under the title.
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 28

    init(_ title: Text, icon: String? = nil, role: SettingsRowRole = .standard, value: Text? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        label = SettingsLabel(title: title, icon: icon, role: role)
        self.value = value
        self.trailing = trailing()
    }

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 8))
        HStack(spacing: 8) {
            layout {
                label.frame(maxWidth: .infinity, alignment: .leading)
                if let value {
                    value.font(.body).foregroundStyle(CommaTheme.textTertiary)
                        .lineLimit(stacked ? nil : 1)
                        .padding(.leading, stacked && label.icon != nil ? iconColumn : 0)
                }
            }
            trailing
        }
        .surfaceRowFrame()
        // A row read alone, such as the workspace or the version, reads as one: its title, then its value.
        .accessibilityElement(children: .combine)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(_ title: Text, icon: String? = nil, role: SettingsRowRole = .standard, value: Text? = nil) {
        self.init(title, icon: icon, role: role, value: value) { EmptyView() }
    }
}

/// The chevron of a row that opens a page.
struct SettingsChevron: View {
    var body: some View {
        CentralIcon("central-chevron-right-small", size: 20, relativeTo: .body)
            .foregroundStyle(CommaTheme.textQuaternary)
            .padding(.trailing, -4)
    }
}

/// The checkmark on the chosen row of a choice.
struct SettingsCheckmark: View {
    let shown: Bool

    var body: some View {
        CentralIcon("icon-check", size: 24, relativeTo: .body)
            .foregroundStyle(CommaTheme.brandSolid)
            .opacity(shown ? 1 : 0)
            .padding(.trailing, -4)
    }
}

/// A setting that is on or off: its label, then the switch, which the label names for VoiceOver.
struct SettingsToggle: View {
    let title: Text
    var icon: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { SettingsLabel(title: title, icon: icon) }
            .tint(CommaTheme.brandSolid)
            .surfaceRowFrame()
    }
}

/// A status line inside a group: a glyph in the icon column (or a spinner) beside wrapping `.subheadline` text.
struct SettingsNote<Leading: View, Message: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let message: Message
    @ScaledMetric(relativeTo: .body) private var slot: CGFloat = 20

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            leading.frame(width: slot, height: slot)
            VStack(alignment: .leading, spacing: 4) { message }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        }
        .font(.subheadline)
        .surfaceRowFrame(vertical: 12)
        .accessibilityElement(children: .combine)
    }
}

extension SettingsNote where Leading == CentralIcon {
    init(icon: String, @ViewBuilder message: () -> Message) {
        self.init(leading: { CentralIcon(icon, size: 20, relativeTo: .body) }, message: message)
    }
}
