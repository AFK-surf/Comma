import SwiftUI
import UIKit

/// Label colours from the desktop palette (`.comma-label-dot`): a preset name or a `#rrggbb` custom colour.
enum TaskLabelColor {
    static func color(_ value: String) -> Color {
        if value.hasPrefix("#"), value.count == 7, let hex = UInt32(value.dropFirst(), radix: 16) { return Color(hex: hex) }
        switch value {
        case "blue": return Color(hex: 0x0BA5EC)
        case "indigo": return Color(hex: 0x6172F3)
        case "purple": return Color(hex: 0x7A5AF8)
        case "pink": return Color(hex: 0xF670C7)
        case "orange": return Color(hex: 0xF38744)
        case "warning": return Color(hex: 0xFAC515)
        case "success": return Color(hex: 0x47CD89)
        case "error": return Color(hex: 0xF97066)
        case "brand": return Color(hex: 0x205BFF)
        default: return Color(hex: 0xB6B8BB)
        }
    }

    /// The label's dot as a menu icon. Menus tint shapes and template images, so the dot is drawn into an
    /// image that keeps its colour: 10pt, centred in the 24pt square menus give their icons.
    static func menuDot(_ value: String) -> Image {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in
            UIColor(color(value)).setFill()
            UIBezierPath(ovalIn: CGRect(x: 7, y: 7, width: 10, height: 10)).fill()
        }
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
    }
}
