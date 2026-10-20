import SwiftUI

/// A glyph from Central Icons, the desktop's icon set, drawn from the asset catalog in the foreground style.
/// Asset names follow the Central name (`IconBox2` is `central-box-2`, its filled style `central-box-2-fill`);
/// older assets keep their `icon-` names. It is decorative: the control or label around it carries the name.
/// `size` is fixed in points, for glyphs inside fixed-size controls; `relativeTo` makes it grow with that text
/// style instead, for a glyph set beside text.
struct CentralIcon: View {
    private let name: String
    private let size: CGFloat
    private let scales: Bool
    @ScaledMetric private var scaledSize: CGFloat

    init(_ name: String, size: CGFloat = 20, relativeTo style: Font.TextStyle? = nil) {
        self.name = name
        self.size = size
        scales = style != nil
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: style ?? .body)
    }

    var body: some View {
        let side = scales ? scaledSize : size
        Image(decorative: name).renderingMode(.template).resizable().interpolation(.high)
            .frame(width: side, height: side)
    }
}
