import Photos
import SwiftUI

/// Recent photos as a three-column grid. A tap marks a photo with its place in the selection (up to
/// eight, as in the system picker); Add attaches them in that order. All Photos opens the system picker.
struct PhotoGridPanel: View {
    let back: () -> Void
    let openAllPhotos: () -> Void
    let attach: ([AttachmentImage]) -> Void
    @State private var library = PhotoLibraryModel()
    @State private var selection: [String] = []
    @State private var adding = false
    @Environment(\.openURL) private var openURL

    static let maxSelection = 8
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack {
            content
            PanelControls {
                PanelIconButton(icon: "icon-back", label: "Back", action: back)
            } center: {
                EmptyView()
            } trailing: {
                trailingAction
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .sensoryFeedback(.selection, trigger: selection)
        .task { await library.load() }
    }

    @ViewBuilder private var content: some View {
        switch library.access {
        case .asking:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            VStack(spacing: 14) {
                Text("Allow photo access in Settings to see recent photos here, or choose from All Photos.")
                    .font(.subheadline).foregroundStyle(CommaTheme.textTertiary).multilineTextAlignment(.center)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(url) }.buttonStyle(PanelCapsuleStyle())
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .allowed:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(library.assets, id: \.localIdentifier) { asset in
                        PhotoCell(asset: asset, order: selection.firstIndex(of: asset.localIdentifier)) {
                            toggle(asset.localIdentifier)
                        }
                    }
                }
                // Room to scroll the last row above the floating controls.
                .padding(.bottom, 88)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder private var trailingAction: some View {
        if selection.isEmpty {
            Button("All Photos", action: openAllPhotos).buttonStyle(PanelCapsuleStyle())
        } else {
            Button { Task { await add() } } label: {
                Text("Add \(selection.count)").monospacedDigit().contentTransition(.numericText())
            }
            .buttonStyle(PanelCapsuleStyle(prominent: true))
            .disabled(adding)
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
            if let index = selection.firstIndex(of: id) {
                selection.remove(at: index)
            } else if selection.count < Self.maxSelection {
                selection.append(id)
            }
        }
    }

    private func add() async {
        adding = true
        defer { adding = false }
        let byID = Dictionary(uniqueKeysWithValues: library.assets.map { ($0.localIdentifier, $0) })
        var images: [AttachmentImage] = []
        for id in selection {
            if let asset = byID[id], let image = await PhotoLibraryModel.image(asset) { images.append(image) }
        }
        attach(images)
    }
}

/// One square photo; marked, it dims slightly and shows its number in the selection.
private struct PhotoCell: View {
    let asset: PHAsset
    let order: Int?
    let toggle: () -> Void
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Button(action: toggle) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image { Image(uiImage: image).resizable().scaledToFill() } else { CommaTheme.bgTertiary }
                }
                .clipped()
                .overlay { Color.black.opacity(order == nil ? 0 : 0.18) }
                .overlay(alignment: .topTrailing) { badge.padding(8) }
                .contentShape(Rectangle())
        }
        .buttonStyle(PhotoPressStyle())
        .task(id: asset.localIdentifier) {
            image = await PhotoLibraryModel.thumbnail(asset, side: 140, scale: displayScale)
        }
        .accessibilityLabel(Text("Photo"))
        .accessibilityValue(order.map { Text("Selected, \($0 + 1)") } ?? Text(""))
        .accessibilityAddTraits(order == nil ? [] : .isSelected)
    }

    private var badge: some View {
        ZStack {
            if let order {
                Circle().fill(CommaTheme.brandSolid)
                Text("\(order + 1)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
            }
            Circle().strokeBorder(.white, lineWidth: 1.5)
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.25), radius: 2)
        .animation(.spring(response: 0.25, dampingFraction: 1), value: order)
    }
}

/// A photo dims under the finger as it lands, as in Photos; the grid's 2pt gaps leave no room to shrink it.
private struct PhotoPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay { Color.black.opacity(configuration.isPressed ? 0.15 : 0) }
            .animation(configuration.isPressed ? nil : CommaMotion.feedbackIn, value: configuration.isPressed)
    }
}
