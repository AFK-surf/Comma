import XCTest

/// Tasks named inline in a message's text, drawn as the desktop's inline Task: a pill behind the status glyph and title.
@MainActor final class InlineTaskUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The pills are drawn from a copy of the text laid out under the selectable text, so both layouts must give each
    /// line the same height. When they did not, on iOS 26 a pill sat above its title, and one sat empty at the end of
    /// the line above its Task.
    func testInlineTaskPillsCentreOnTheirTitles() throws {
        let app = XCUIApplication.fixture(light: true, arguments: ["--launch-in-chat"])
        // Router message 27 names two Tasks inline, the first in a line of Chinese; each Task's title is a link.
        XCTAssertTrue(app.links["Review launch"].waitUntilHittable(timeout: 10), "The message naming Tasks inline is in view")
        let message = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Review launch")).firstMatch
        let pills = try inlinePills(in: keepScreenshot(app, "Inline Task pills"), of: message.frame, screen: app.frame)
        XCTAssertGreaterThanOrEqual(pills.count, 2, "Each inline Task has a pill")
        for pill in pills {
            let ink = try XCTUnwrap(pill.ink, "The pill at \(pill.rows) has its title on it")
            XCTAssertEqual(ink.middle, pill.rows.middle, accuracy: 1.5,
                           "The pill at \(pill.rows) centres on its title, whose ink is at \(ink)")
        }
    }
}

/// One line of an inline Task's pill: the rows it covers and the rows its title's ink covers, in points.
private struct InlinePill {
    let rows: ClosedRange<CGFloat>
    let ink: ClosedRange<CGFloat>?
}

private extension ClosedRange<CGFloat> {
    var middle: CGFloat { (lowerBound + upperBound) / 2 }
}

@MainActor private extension XCTestCase {
    /// The pills in `frame` of a light-mode screenshot, found by their fill. The title is the dark ink on a pill past
    /// its status glyph, which takes the pill's first 24pt and a 2pt gap.
    func inlinePills(in screenshot: XCUIScreenshot, of frame: CGRect, screen: CGRect) throws -> [InlinePill] {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let scale = CGFloat(width) / screen.width
        func px(_ points: CGFloat) -> Int { Int((points * scale).rounded()) }
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let index = (y * width + x) * 4
            return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
        }
        // `CommaTheme.inlineTaskPill` in light mode, 0xE4E5E7; the bubble under it is 0xF1F1F1.
        func isPill(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = rgb(x, y)
            return abs(r - 0xE4) <= 3 && abs(g - 0xE5) <= 3 && abs(b - 0xE7) <= 3
        }
        func isInk(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = rgb(x, y)
            return r + g + b < 3 * 0x80
        }
        let xs = max(px(frame.minX - screen.minX), 0)..<min(px(frame.maxX - screen.minX), width)
        // A pill may reach a few points past the text's first and last lines.
        let ys = max(px(frame.minY - screen.minY - 8), 0)..<min(px(frame.maxY - screen.minY + 8), height)

        // Rows with a pill's worth of fill, grouped into bands: one band a line.
        var bands: [ClosedRange<Int>] = []
        for y in ys where xs.filter({ isPill($0, y) }).count >= px(8) {
            if let last = bands.last, last.upperBound == y - 1 { bands[bands.count - 1] = last.lowerBound...y }
            else { bands.append(y...y) }
        }
        var pills: [InlinePill] = []
        for band in bands where band.count >= px(12) {
            // Columns mostly filled across the band, grouped into one run a pill.
            var runs: [ClosedRange<Int>] = []
            for x in xs where band.filter({ isPill(x, $0) }).count * 3 >= band.count {
                if let last = runs.last, x - last.upperBound <= px(3) { runs[runs.count - 1] = last.lowerBound...x }
                else { runs.append(x...x) }
            }
            for run in runs where run.count >= px(12) {
                let title = min(run.lowerBound + px(26), run.upperBound)...run.upperBound
                // A little past the band, where its rounded ends thin out, and short of the lines above and below.
                let around = max(band.lowerBound - px(2), 0)...min(band.upperBound + px(2), height - 1)
                let inked = around.filter { y in title.contains { isInk($0, y) } }
                let points = { (pixels: ClosedRange<Int>) in
                    (CGFloat(pixels.lowerBound) / scale + screen.minY)...(CGFloat(pixels.upperBound + 1) / scale + screen.minY)
                }
                pills.append(InlinePill(rows: points(band),
                                        ink: inked.first.flatMap { first in inked.last.map { points(first...$0) } }))
            }
        }
        return pills
    }
}
