import SwiftUI
import UIKit
import CommaCore

/// A connected app's mark: the desktop's brand artwork when this app ships it, else the source's own icon,
/// else the desktop's plug-in puzzle piece. Monochrome marks (GitHub, Notion) follow the text colour.
struct ProviderLogo: View {
    let source: RecommendationSource?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image = ProviderArtwork.image(source?.appID) {
                Image(uiImage: image).resizable().scaledToFit().foregroundStyle(CommaTheme.textPrimary)
            } else if let url = source?.iconURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() } else { fallback }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        CentralIcon("central-puzzle", size: size).foregroundStyle(CommaTheme.sidebarIcon)
    }
}

/// Several apps' marks overlapping in small rings, standing for the apps as a group: the sample before any is
/// connected, or the platforms with nothing new. Each app shows once.
struct ProviderLogoStack: View {
    let sources: [RecommendationSource?]

    var body: some View {
        HStack(spacing: -4) {
            ForEach(Array(distinct.enumerated()), id: \.offset) { _, source in
                ProviderLogo(source: source, size: 16)
                    .padding(5)
                    .background(CommaTheme.cardPrimary, in: Circle())
                    .overlay(Circle().strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
            }
        }
        .accessibilityHidden(true)
    }

    private var distinct: [RecommendationSource?] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0?.appID ?? "").inserted }
    }
}

/// Provider artwork shipped in the asset catalog, keyed like the desktop logo resolver.
enum ProviderArtwork {
    /// The decorative sample shown before any source is connected, as on the desktop.
    static let samples = ["linear", "slack", "github", "googledrive"]

    static func image(_ appID: String?) -> UIImage? {
        guard let key = RecommendationSource.brandKey(appID) else { return nil }
        let name = "provider-" + (key == "googleworkspace" ? "google" : key)
        return UIImage(named: name)
    }

    /// A mark sized for a line of text, for use inside a `Text`.
    @MainActor static func inline(_ appID: String?, pointSize: CGFloat, tint: UIColor) -> Image? {
        guard let image = image(appID) else { return nil }
        let key = "\(appID ?? "")-\(pointSize)-\(tint.hashValue)"
        if let cached = cache[key] { return Image(uiImage: cached) }
        let source = image.renderingMode == .alwaysTemplate ? image.withTintColor(tint, renderingMode: .alwaysOriginal) : image
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: pointSize, height: pointSize)).image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: pointSize, height: pointSize))
        }
        cache[key] = rendered
        return Image(uiImage: rendered)
    }

    @MainActor private static var cache: [String: UIImage] = [:]
}
