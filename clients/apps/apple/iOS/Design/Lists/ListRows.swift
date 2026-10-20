import SwiftUI
import UIKit

/// How far a row placed with `commaListRow(_:)` sits from a plain `List`'s edges and its neighbours.
enum ListRowInset {
    /// Edge to edge: the row lays out its own margins (headers, banners, empty states, spinners).
    case flush
    /// Task rows: their press surface keeps 10pt from the sides, and rows sit 2pt apart.
    case task
    /// Rows on their own rounded surface, aligned with the page's 16pt margins and 4pt apart.
    case surface

    var edges: EdgeInsets {
        switch self {
        case .flush: EdgeInsets()
        case .task: EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10)
        case .surface: EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)
        }
    }
}

extension View {
    /// Places a row in a plain `List` the way every list in the app does: no separator and no system
    /// background, so the row's own surface (or none) is the only fill.
    func commaListRow(_ inset: ListRowInset = .flush) -> some View {
        listRowInsets(inset.edges)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// Central glyphs for swipe actions. Swipe actions show images at their own size, so the 24pt assets are
/// drawn at 16pt to sit small beside the action's title.
enum SwipeIcon {
    static func image(_ name: String, size: CGFloat = 16) -> Image {
        guard let source = UIImage(named: name) else { return Image(decorative: name) }
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        return Image(uiImage: drawn.withRenderingMode(.alwaysTemplate))
    }

    /// A whole swipe action, glyph and title, drawn in `ink` for an action on a light fill: the system draws
    /// swipe titles in white, which would vanish there. Pair it with `hairTitle` as the label's title, which
    /// keeps the system's titled layout so the capsule sizes to this image; that title's gap adds 4pt on the
    /// right, so the image starts with 4pt of its own to stay centred. The title matches the system's: the
    /// footnote size (13pt by default) in regular weight, 6pt after a 16pt glyph.
    static let hairTitle = "\u{200A}"

    @MainActor static func titled(_ name: String, title: String, ink: UIColor, size: CGFloat = 16) -> Image {
        let font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ink])
        let textSize = text.size()
        let lead: CGFloat = 4, gap: CGFloat = 6
        let canvas = CGSize(width: ceil(lead + size + gap + textSize.width), height: ceil(max(size, textSize.height)))
        let drawn = UIGraphicsImageRenderer(size: canvas).image { _ in
            UIImage(named: name)?.withTintColor(ink, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: lead, y: (canvas.height - size) / 2, width: size, height: size))
            text.draw(at: CGPoint(x: lead + size + gap, y: (canvas.height - textSize.height) / 2))
        }
        drawn.accessibilityLabel = title
        return Image(uiImage: drawn.withRenderingMode(.alwaysOriginal))
    }
}

/// Central glyphs for menu items.
enum MenuIcon {
    /// The glyph of a destructive item. A menu draws a destructive title in red but tints a template glyph with
    /// the app's blue, so this one is drawn in the same system red itself; disabled, in the greyed label colour.
    static func destructive(_ name: String, enabled: Bool = true) -> Image {
        guard let source = UIImage(named: name) else { return Image(name) }
        let ink: UIColor = enabled ? .systemRed : .tertiaryLabel
        return Image(uiImage: source.withTintColor(ink, renderingMode: .alwaysOriginal))
    }
}
