import SwiftUI
import XCTest
@testable import Comma

/// The drag that shows where messages came from uncovers each platform logo in the strip it opens beside the bubble,
/// never over the bubble's own text.
@MainActor final class SourceRevealTests: XCTestCase {
    func testOpenStripShowsTheLogoBesideTheBubbleNotOverIt() throws {
        let width: CGFloat = 300, bubble: CGFloat = 100, height: CGFloat = 30
        let row = HStack(spacing: 0) {
            Spacer(minLength: 0)
            Color(.sRGB, red: 1, green: 0, blue: 0).frame(width: bubble, height: height)
        }
        .frame(width: width, height: height)
        .modifier(SourceRevealRow(moves: true, platform: "slack", travel: SourceReveal.maxTravel))
        .background(Color.white)
        let renderer = ImageRenderer(content: row)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let pixels = try Pixels(image)
        let y = Int(height / 2)
        let bubbleEnd = Int(width - SourceReveal.maxTravel)
        // The moved bubble keeps every one of its pixels.
        for x in (bubbleEnd - Int(bubble) + 1)..<bubbleEnd - 1 {
            XCTAssertTrue(pixels.isRed(x: x, y: y), "the logo covers the bubble at x \(x): \(pixels.rgb(x, y))")
        }
        // The logo is in the strip the drag opened.
        let inStrip = (bubbleEnd + 1..<Int(width)).contains { !pixels.isWhite(x: $0, y: y) }
        XCTAssertTrue(inStrip, "no logo in the open strip")
    }
}

private struct Pixels {
    let bytes: [UInt8]
    let width: Int

    init(_ image: CGImage) throws {
        width = image.width
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        bytes = data
    }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    func isRed(x: Int, y: Int) -> Bool { let (r, g, b) = rgb(x, y); return r > 220 && g < 40 && b < 40 }
    func isWhite(x: Int, y: Int) -> Bool { let (r, g, b) = rgb(x, y); return r > 245 && g > 245 && b > 245 }
}
