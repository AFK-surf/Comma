import SwiftUI

extension View {
    /// Presents this sheet's content the app's way: on the opaque sheet surface (`cardPrimary`) rather than the
    /// default glass, at `detents` (following `selection` when the sheet moves itself), with the grabber whenever
    /// it can be resized. Apply it to the root of the sheet's content.
    func commaSheet(_ detents: Set<PresentationDetent> = [.medium, .large],
                    selection: Binding<PresentationDetent>? = nil) -> some View {
        modifier(CommaSheet(detents: detents, selection: selection))
    }

    /// A sheet's way out, the same on every sheet: the cross at the leading edge. `id` keeps an accessibility
    /// identifier a test reaches it by.
    func sheetCloseButton(id: String? = nil, _ close: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if let id { SheetCloseButton(close: close).accessibilityIdentifier(id) } else { SheetCloseButton(close: close) }
            }
        }
    }
}

extension EnvironmentValues {
    /// The view is in a sheet presented with `commaSheet()`; its page title is set a step quieter.
    @Entry var inSheet = false
}

private struct CommaSheet: ViewModifier {
    let detents: Set<PresentationDetent>
    let selection: Binding<PresentationDetent>?

    func body(content: Content) -> some View {
        Group {
            if let selection {
                content.presentationDetents(detents, selection: selection)
            } else {
                content.presentationDetents(detents)
            }
        }
        .presentationDragIndicator(detents.count > 1 ? .visible : .hidden)
        .presentationBackground(CommaTheme.cardPrimary)
        .environment(\.inSheet, true)
    }
}

/// The same cross as the Task dock's close. On iOS 26 the toolbar draws it in glass.
private struct SheetCloseButton: View {
    let close: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            // In the text colour, whatever tint the sheet gives its own controls.
            Button(role: .close, action: close) { Label("Close", image: "icon-close") }
                .tint(CommaTheme.textPrimary)
        } else {
            Button(action: close) {
                CentralIcon("icon-close", size: 16)
                    .foregroundStyle(CommaTheme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(CommaTheme.bgTertiary, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle())
            .accessibilityLabel("Close")
        }
    }
}
