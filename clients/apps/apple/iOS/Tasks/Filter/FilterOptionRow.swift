import SwiftUI
import CommaCore

/// One option of a field: its checkbox, glyph, name and how many loaded Tasks it holds. VoiceOver reads it
/// as a button that is selected while checked.
struct FilterOptionRow: View {
    let option: TaskFilterOption
    let selected: Bool
    var count = 0
    let toggle: () -> Void
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 18

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                FilterCheckbox(on: selected)
                TaskFilterGlyph(glyph: option.glyph, size: glyphSize).padding(.leading, 12)
                Text(option.name).font(.body).foregroundStyle(CommaTheme.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if count > 0 {
                    Text(count, format: .number).font(.body.monospacedDigit())
                        .foregroundStyle(CommaTheme.textQuaternary)
                }
            }
            .surfaceRowFrame(vertical: 6)
        }
        .buttonStyle(SurfaceRowButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("filterOption-" + option.id)
    }
}

/// A rounded square: a hairline outline when off; a deeper fill holding the checkmark when on. The mark
/// grows in with the toggle, or fades under Reduce Motion.
struct FilterCheckbox: View {
    let on: Bool
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size / 4, style: .continuous)
        shape.fill(GroupedSurface.ink(on ? 0.08 : 0))
            .overlay(shape.strokeBorder(GroupedSurface.ink(on ? 0.14 : 0.12), lineWidth: 1))
            .overlay {
                if on {
                    CentralIcon("icon-check", size: 24, relativeTo: .body)
                        .foregroundStyle(CommaTheme.textSecondary)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
            .animation(reduceMotion ? CommaMotion.stateChange : .spring(response: 0.25, dampingFraction: 1), value: on)
            .accessibilityHidden(true)
    }
}

/// A fixed slot holds each option's status, label, Loop kind, platform or device glyph.
/// Options without a glyph keep an empty slot so names stay aligned.
struct TaskFilterGlyph: View {
    let glyph: TaskFilterOption.Glyph
    var size: CGFloat = 18

    var body: some View {
        Group {
            switch glyph {
            case .status(let bucket):
                TaskStatusIcon(bucket: bucket, size: size, spins: false)
            case .label(let color):
                Circle().fill(TaskLabelColor.color(color)).frame(width: size * 0.55, height: size * 0.55)
            case .loop(let kind):
                CentralIcon(kind.iconName, size: size).foregroundStyle(CommaTheme.textSecondary)
            case .origin(let origin):
                origin.icon
            case .device:
                CentralIcon("icon-macbook", size: size).foregroundStyle(CommaTheme.textSecondary)
            case .none:
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
