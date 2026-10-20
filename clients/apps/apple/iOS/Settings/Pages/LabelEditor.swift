import SwiftUI
import CommaCore

/// A label being added or edited, before it is saved.
struct LabelDraft: Identifiable {
    let id = UUID()
    var labelID: String?
    var name = ""
    var color: String
    var description = ""
    init(label: TaskLabel) { labelID = label.id; name = label.name; color = label.color; description = label.description ?? "" }
    init(color: String) { self.color = color }
}

/// The sheet for a label's name, description and colour.
struct LabelEditor: View {
    struct Result { let id: String?; let name: String; let color: String; let description: String? }
    @State var draft: LabelDraft
    let colors: [String]
    let save: (Result) -> Void
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var swatch: CGFloat = 30
    @FocusState private var nameFocused: Bool

    private static let fallbackColors = ["blue", "indigo", "purple", "pink", "orange", "warning", "success", "error", "brand"]

    var body: some View {
        NavigationStack {
            SettingsPage(background: CommaTheme.cardPrimary) {
                SettingsSection {
                    TextField("Name", text: $draft.name).font(.body).focused($nameFocused).surfaceRowFrame()
                    TextField("Description (optional)", text: $draft.description, axis: .vertical)
                        .font(.body).lineLimit(1...4).surfaceRowFrame(vertical: 12)
                }
                SettingsSection(Text("Colour")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 6), spacing: 4) {
                        ForEach(options, id: \.self) { color in swatchButton(color) }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 6)
                }
            }
            .pageTitle(draft.labelID == nil ? "New label" : "Edit label")
            // The way out every sheet has; a new label starts in its name.
            .sheetCloseButton { dismiss() }
            .onAppear { if draft.labelID == nil { nameFocused = true } }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
                        save(Result(id: draft.labelID, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    color: draft.color, description: draft.labelID == nil && description.isEmpty ? nil : description))
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(CommaTheme.brandSolid)
        .commaSheet()
    }

    /// The server's colours, and the draft's own if the server no longer offers it.
    private var options: [String] {
        let offered = colors.isEmpty ? Self.fallbackColors : colors
        return offered.contains(draft.color) ? offered : offered + [draft.color]
    }

    /// A colour's name for VoiceOver; the server names some by their role ("warning", "brand").
    private static func name(of color: String) -> Text {
        switch color {
        case "blue": Text("Blue")
        case "indigo": Text("Indigo")
        case "purple": Text("Purple")
        case "pink": Text("Pink")
        case "orange": Text("Orange")
        case "warning": Text("Yellow")
        case "success": Text("Green")
        case "error": Text("Red")
        case "brand": Text("Comma blue")
        default: Text("Custom colour")
        }
    }

    private func swatchButton(_ color: String) -> some View {
        let chosen = color == draft.color
        return Button { draft.color = color } label: {
            Circle().fill(TaskLabelColor.color(color)).frame(width: swatch, height: swatch)
                .overlay {
                    if chosen {
                        CentralIcon("icon-check", size: swatch).foregroundStyle(.white)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                // The chosen colour also carries a ring, so the choice reads without the checkmark's contrast.
                .overlay(Circle().inset(by: -3).stroke(TaskLabelColor.color(color).opacity(chosen ? 0.45 : 0), lineWidth: 2))
                .frame(width: max(44, swatch + 12), height: max(44, swatch + 12)).contentShape(Circle())
        }
        .buttonStyle(TactileButtonStyle(scale: 0.9))
        .animation(.spring(response: 0.25, dampingFraction: 1), value: chosen)
        .accessibilityLabel(Self.name(of: color))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
