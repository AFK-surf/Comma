import CoreGraphics
import Foundation

/// NameDrop's textures, drawn once at launch to match the package's images:
/// soft glows, spectral sheens and the eclipse arcs. They are smooth, so they
/// are drawn small and scaled by their layers.
struct NameDropTextures {
    /// White elliptical glow (the hint glows and the ridge glow).
    let glow: CGImage
    /// Round white glow (the light the shockwave blooms from).
    let circle: CGImage
    /// Elliptical glow, deep blue at the top through pale yellow at its
    /// center to dark red below (the hint sheen).
    let sheen: CGImage
    /// The same, paler (the shockwave's sheen).
    let paleSheen: CGImage
    /// A spectral arc on black, for colorDodge.
    let rainbowArc: CGImage
    /// A soft dark arc on white, for multiply.
    let darkArc: CGImage

    init() {
        glow = Self.render(width: 400, height: 140) { x, y in
            (1, 1, 1, Self.gaussian(Self.ellipse(x, y), Self.glowSigma))
        }
        circle = Self.render(width: 160, height: 160) { x, y in
            // The package's exp(-r²·2.2), r in units of a quarter of the layer.
            let r = Self.ellipse(x, y) * 2
            return (1, 0.985, 0.94, exp(-r * r * 2.2))
        }
        sheen = Self.render(width: 400, height: 140) { x, y in
            let (r, g, b) = Self.interpolate(y, Self.sheenColors)
            return (r, g, b, Self.gaussian(Self.ellipse(x, y), Self.glowSigma))
        }
        paleSheen = Self.render(width: 400, height: 140) { x, y in
            let (r, g, b) = Self.interpolate(y, Self.paleSheenColors)
            return (r, g, b, Self.gaussian(Self.ellipse(x, y), Self.glowSigma))
        }
        // The package's eclipse layers show their images upside down (its
        // study flips them too): these are drawn as they appear, a dome.
        rainbowArc = Self.render(width: 400, height: 200, opaque: true) { x, flipped in
            let y = 1 - flipped
            // Rows of the package's 398-row image from the arc's brightest line.
            let rows = (y - Self.arcY(x, bottom: 0.648, halfWidth: 0.45, depth: 0.927)) * 398
            let envelope = rows < 0
                ? 1 - Self.smoothstep(21, 27, -rows)
                : 1 - Self.smoothstep(18, 24, rows)
            let (r, g, b) = Self.interpolate((rows + 21) / 39, Self.arcColors)
            let k = envelope * Self.arcFade(x)
            return (r * k, g * k, b * k, 1)
        }
        darkArc = Self.render(width: 400, height: 200, opaque: true) { x, flipped in
            let y = 1 - flipped
            let distance = y - Self.arcY(x, bottom: 0.633, halfWidth: 1, depth: 4.42)
            let v = 1 - 0.31 * Self.gaussian(abs(distance), 0.071) * Self.arcFade(x, reach: 0.36)
            return (v, v, v, 1)
        }
    }

    // MARK: Shapes

    /// The package's glows fall to 0.4 at 0.4 of their half-width.
    private static let glowSigma = 0.295

    /// Distance from the center in half-extents: 1 on the ellipse touching the edges.
    private static func ellipse(_ x: Double, _ y: Double) -> Double {
        let dx = (x - 0.5) * 2, dy = (y - 0.5) * 2
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func gaussian(_ distance: Double, _ sigma: Double) -> Double {
        exp(-(distance * distance) / (2 * sigma * sigma))
    }

    /// The arc is the bottom of an ellipse in the package's image: lowest
    /// (`bottom`, y down) at the center, `halfWidth` and `depth` its semi-axes.
    /// Fitted to the package's arcs.
    private static func arcY(_ x: Double, bottom: Double, halfWidth: Double, depth: Double) -> Double {
        let dx = min(abs(x - 0.5) / halfWidth, 1)
        return bottom - depth + depth * (1 - dx * dx).squareRoot()
    }

    /// Full at the arc's bottom, about half a quarter of the width out, gone a third out.
    private static func arcFade(_ x: Double, reach: Double = 0.33) -> Double {
        let dx = abs(x - 0.5) / reach
        return max(0, 1 - dx * dx * dx)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Color, sampled from the package's images

    private typealias Stop = (at: Double, r: Double, g: Double, b: Double)

    /// Top to bottom through the hint sheen's center.
    private static let sheenColors: [Stop] = [
        (0.0, 0.13, 0.13, 0.13), (0.2, 0.11, 0.12, 0.27), (0.3, 0.11, 0.27, 0.53),
        (0.4, 0.23, 0.58, 0.72), (0.5, 0.82, 0.88, 0.55), (0.6, 0.91, 0.52, 0.27),
        (0.7, 0.46, 0.12, 0.12), (0.8, 0.16, 0.15, 0.15), (1.0, 0.3, 0.3, 0.3),
    ]

    private static let paleSheenColors: [Stop] = [
        (0.0, 0.44, 0.44, 0.44), (0.2, 0.45, 0.5, 0.58), (0.3, 0.49, 0.59, 0.74),
        (0.4, 0.55, 0.75, 0.81), (0.5, 0.86, 0.91, 0.63), (0.6, 0.93, 0.69, 0.55),
        (0.7, 0.69, 0.45, 0.44), (0.8, 0.4, 0.37, 0.37), (1.0, 0.37, 0.37, 0.37),
    ]

    /// Across the rainbow arc, from 21 rows above its brightest line to 18 below.
    private static let arcColors: [Stop] = [
        (0.0, 0.24, 0.28, 0.43), (5 / 39, 0.29, 0.37, 0.53), (9 / 39, 0.35, 0.49, 0.56),
        (13 / 39, 0.45, 0.62, 0.53), (16 / 39, 0.58, 0.72, 0.56), (19 / 39, 0.75, 0.78, 0.69),
        (21 / 39, 0.79, 0.78, 0.71), (24 / 39, 0.78, 0.67, 0.57), (27 / 39, 0.70, 0.50, 0.38),
        (31 / 39, 0.60, 0.30, 0.24), (35 / 39, 0.47, 0.18, 0.17), (1.0, 0.30, 0.13, 0.13),
    ]

    private static func interpolate(_ t: Double, _ stops: [Stop]) -> (Double, Double, Double) {
        let t = max(0, min(1, t))
        guard let upper = stops.firstIndex(where: { $0.at >= t }), upper > 0 else {
            let s = stops[0]
            return (s.r, s.g, s.b)
        }
        let a = stops[upper - 1], b = stops[upper]
        let k = (t - a.at) / (b.at - a.at)
        return (a.r + (b.r - a.r) * k, a.g + (b.g - a.g) * k, a.b + (b.b - a.b) * k)
    }

    // MARK: Pixels

    /// `pixel(x, y)` gets the pixel center in 0…1, y down, and returns
    /// straight (not premultiplied) RGBA in 0…1.
    private static func render(
        width: Int,
        height: Int,
        opaque: Bool = false,
        _ pixel: (Double, Double) -> (Double, Double, Double, Double)
    ) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let (r, g, b, a) = pixel(
                    (Double(column) + 0.5) / Double(width),
                    (Double(row) + 0.5) / Double(height)
                )
                let alpha = max(0, min(1, a))
                let offset = (row * width + column) * 4
                bytes[offset] = UInt8((max(0, min(1, r)) * alpha * 255).rounded())
                bytes[offset + 1] = UInt8((max(0, min(1, g)) * alpha * 255).rounded())
                bytes[offset + 2] = UInt8((max(0, min(1, b)) * alpha * 255).rounded())
                bytes[offset + 3] = UInt8((alpha * 255).rounded())
            }
        }
        let info = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }
}
