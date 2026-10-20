import SwiftUI

/// A Worker as the logo of its model's maker on a plain disc, as on the desktop (`WorkerModelMark`): the core's
/// `taskRun.vendor` names the maker, `comma` for Comma's own model; sparkles while it is not known.
struct WorkerAvatar: View {
    let vendor: String?
    var size: CGFloat = 20

    private static let logos: Set<String> = [
        "anthropic", "deepseek", "glm", "google", "kimi", "meta", "minimax", "mistral", "openai", "qwen", "xai",
    ]

    var body: some View {
        Circle()
            .fill(CommaTheme.bgPrimary)
            .overlay(Circle().strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
            .overlay { mark.foregroundStyle(CommaTheme.textPrimary) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var mark: some View {
        let glyph = size * 0.7
        if vendor == "comma" {
            CommaMark(size: glyph)
        } else if let vendor, Self.logos.contains(vendor) {
            Image(decorative: "model-" + vendor).renderingMode(.template).resizable().interpolation(.high)
                .scaledToFit().frame(width: glyph, height: glyph)
        } else {
            Image(decorative: "central-sparkles-two").renderingMode(.template).resizable().interpolation(.high)
                .scaledToFit().frame(width: glyph, height: glyph)
        }
    }
}
