import SwiftUI
import XCTest
@testable import Comma

/// The client core's Markdown tree read as bubbles. The fixtures are what the core's `messageMarkdown` makes of the
/// text in each test's comment.
final class MarkdownTreeTests: XCTestCase {
    private func tree(_ json: String) -> NSArray { try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! NSArray }

    /// Desktop bubble grouping: consecutive prose shares a bubble, code and tables stand alone, and a thematic break
    /// starts a new bubble.
    func testSlotsFollowDesktopBubbleGrouping() {
        // # Title / Intro with **bold** / - one - two / > quote / ```swift code``` / | a | b | table / After / --- / New group
        let tree = tree("""
            [["h",["Title"],{"level":1}],["p",["Intro with ",["b",["bold"]]]],["list",[["li",[["p",["one"]]]],["li",[["p",["two"]]]]]],\
            ["quote",[["p",["quote"]]]],["pre",{"language":"swift","code":"code\\n"}],\
            ["table",[["tr",[["td",["a"],{"header":true,"align":"left"}],["td",["b"],{"header":true,"align":"center"}]]],\
            ["tr",[["td",["1"],{"align":"left"}],["td",["2"],{"align":"center"}]]]]],["p",["After"]],["hr"],["p",["New group"]]]
            """)
        let slots = MarkdownTree.slots(tree, style: MarkdownStyle()) { _ in nil }
        let kinds = slots.map { slot -> String in
            switch slot {
            case .prose(let blocks): "prose(\(blocks.count))"
            case .code(let language, let text): "code(\(language ?? "-"),\(text))"
            case .table(let table): "table(\(table.head.map { String($0.characters) }),\(table.alignments == [.leading, .center]))"
            case .screen(let link): "screen(\(link.id))"
            }
        }
        XCTAssertEqual(kinds, ["prose(4)", "code(swift,code)", "table([\"a\", \"b\"],true)", "prose(1)", "prose(1)"])
    }

    /// A Task chip sits in the text where the agent wrote it, as a link to the Task with the section it is in.
    func testATaskChipStaysInTheTextAsALink() throws {
        // I started <inline task t1 "Fix [login]", done> for you.
        let tree = tree(#"[["p",["I started ",["comma-inline",{"key":"element-1"}]," for you."]]]"#)
        XCTAssertEqual(MarkdownTree.partIndex("element-1"), 1)
        let slots = MarkdownTree.slots(tree, style: MarkdownStyle()) { key in
            key == "element-1" ? .task(id: "t1", title: "Fix [login]", bucket: .done) : nil
        }
        guard case .prose(let blocks) = try XCTUnwrap(slots.first), case .paragraph(let text) = try XCTUnwrap(blocks.first) else {
            return XCTFail("One paragraph")
        }
        XCTAssertEqual(String(text.characters), "I started Fix [login] for you.")
        let links = text.runs[\.link].compactMap { link, range in link.map { ($0.absoluteString, String(text[range].characters)) } }
        XCTAssertEqual(links.map(\.0), ["comma:task/t1#done"])
        XCTAssertEqual(links.map(\.1), ["Fix [login]"])
        XCTAssertEqual(MarkdownTree.plainText(tree) { _ in .words("Fix [login]") }, "I started Fix [login] for you.")
    }

    /// A line that is only a screen's link (`comma:screen/<device>/<screen>`) is that screen's card, as on the desktop:
    /// the paragraph's other lines stay words before and after it, and a link inside a sentence stays words.
    func testALineThatIsOnlyAScreenLinkIsItsCard() {
        func shown(_ json: String) -> [String] {
            MarkdownTree.slots(tree(json), style: MarkdownStyle()) { _ in nil }.map { slot in
                switch slot {
                case .prose(let blocks):
                    "prose(" + blocks.map { block in
                        if case .paragraph(let text) = block { String(text.characters) } else { "?" }
                    }.joined(separator: "|") + ")"
                case .screen(let link): "screen(\(link.device),\(link.screen),\(link.label ?? "-"))"
                default: "other"
                }
            }
        }
        // Here it is:\n\ncomma:screen/dev1/simulator%3AABC-1\n\nTap to open.
        XCTAssertEqual(shown(#"[["p",["Here it is:"]],["p",["comma:screen/dev1/simulator%3AABC-1"]],["p",["Tap to open."]]]"#),
                       ["prose(Here it is:)", "screen(dev1,simulator:ABC-1,-)", "prose(Tap to open.)"])
        // Look\ncomma:screen/dev1/display\nthere
        XCTAssertEqual(shown(#"[["p",["Look\ncomma:screen/dev1/display\nthere"]]]"#),
                       ["prose(Look)", "screen(dev1,display,-)", "prose(there)"])
        // [My sim](comma:screen/dev1/simulator%3AABC-1)
        XCTAssertEqual(shown(#"[["p",[["a",["My sim"],{"href":"comma:screen/dev1/simulator%3AABC-1"}]]]]"#),
                       ["screen(dev1,simulator:ABC-1,My sim)"])
        // Open comma:screen/dev1/display now
        XCTAssertEqual(shown(#"[["p",["Open comma:screen/dev1/display now"]]]"#),
                       ["prose(Open comma:screen/dev1/display now)"])
        XCTAssertNil(ScreenLinkRef(href: "comma:screen/dev1/settings"))
        XCTAssertEqual(ScreenLinkRef(href: "comma:screen/dev1/simulator%3AABC-1")?.url?.absoluteString,
                       "comma:screen/dev1/simulator%3AABC-1")
    }
}

/// A wide table in an agent bubble, drawn on the simulator in dark mode on the chat background.
@MainActor final class MarkdownTableBubbleTests: XCTestCase {
    /// | 部位 | 说明 | 注意事项 | with one row whose middle cell is longer than a column may grow.
    private static let wideTable = #"""
        [["table",[["tr",[["td",["部位"],{"header":true,"align":"left"}],["td",["说明"],{"header":true,"align":"left"}],\#
        ["td",["注意事项"],{"header":true,"align":"left"}]]],["tr",[["td",["舌"],{"align":"left"}],\#
        ["td",["包含括号说明（第一项、第二项）、顿号、分号等，超过最大列宽时必须完整折行显示而不是截断"],{"align":"left"}],\#
        ["td",["舌苔厚腻时宜清淡饮食；舌质偏红时少吃辛辣、油炸、烧烤等食物"],{"align":"left"}]]]]]]
        """#
    /// `CommaTheme.bgPrimary` in dark mode.
    private static let background = (red: 0x0F, green: 0x0F, blue: 0x10)

    /// Scrolled to its start, middle or end, the table's view stays inside the bubble's rounded corners.
    func testAWideTableStaysInsideTheBubbleCornersWhileItScrolls() async throws {
        let page = try TablePage(tree: Self.wideTable)
        defer { page.close() }
        let scroll = try XCTUnwrap(page.horizontalScroll, "A table wider than the bubble scrolls")
        let end = scroll.contentSize.width - scroll.bounds.width
        XCTAssertGreaterThan(end, 100)
        for offset in [0, end / 2, end] {
            scroll.contentOffset.x = offset
            let bitmap = try await page.capture()
            let bubble = page.frame(of: scroll).insetBy(dx: -4, dy: -4)
            XCTAssertEqual(bubble.width, 340, accuracy: 0.5)
            let stray = bitmap.strayPixels(around: bubble, radius: CommaTheme.bubbleRadius, background: Self.background)
            XCTAssertEqual(stray.count, 0, "Pixels outside the bubble's corners at offset \(offset): \(stray.prefix(4))")
        }
    }

    /// A cell longer than the widest column wraps onto more lines instead of ending in an ellipsis, and a short cell in
    /// its row starts on its first line.
    func testALongCellWrapsAndItsRowStartsOnItsFirstLine() async throws {
        let page = try TablePage(tree: Self.wideTable)
        defer { page.close() }
        let scroll = try XCTUnwrap(page.horizontalScroll)
        let bitmap = try await page.capture()
        let table = page.frame(of: scroll)
        // The first column is as wide as its 60pt minimum and 12pt padding on each side; the long cell is next to it.
        let short = bitmap.textLines(x: table.minX + 4 ... table.minX + 80, y: table.minY ... table.maxY)
        let long = bitmap.textLines(x: table.minX + 96 ... table.minX + 316, y: table.minY ... table.maxY)
        XCTAssertEqual(short.count, 2, "The heading and the one-line cell")
        XCTAssertGreaterThanOrEqual(long.count, 3, "The heading and at least two lines of the long cell")
        guard short.count == 2, long.count >= 3 else { return }
        XCTAssertEqual(short[1].lowerBound, long[1].lowerBound, accuracy: 2, "A short cell starts on the long cell's first line")
    }
}

/// A full-screen window drawing agent bubbles 340pt wide, as on a phone.
@MainActor private struct TablePage {
    let window: UIWindow
    let original: UIWindow?

    init(tree json: String, dark: Bool = true) throws {
        let tree = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSArray)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        original = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView: VStack(alignment: .leading) {
            MarkdownBubbles(tree: tree, parts: [], tail: false).frame(width: 340, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CommaTheme.bgPrimary)
        .environment(\.colorScheme, dark ? .dark : .light))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        original?.makeKeyAndVisible()
    }

    var horizontalScroll: UIScrollView? {
        func find(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(window)
    }

    /// Where a view shows in the window (for a scroll view, its visible frame, whatever it is scrolled to).
    func frame(of view: UIView) -> CGRect { view.convert(view.bounds, to: window) }

    func capture() async throws -> Bitmap {
        try await Task.sleep(for: .milliseconds(150))
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try XCTUnwrap(Bitmap(image))
    }
}

/// RGBA pixels of a capture, addressed in points.
private struct Bitmap {
    let width: Int, height: Int, scale: CGFloat
    let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width; self.height = height; scale = image.scale
        self.bytes = bytes
    }

    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let index = (y * width + x) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    /// Points in the four corner squares of `bubble` that lie outside its continuous rounded outline (given 1pt for
    /// antialiasing) and are not the background.
    func strayPixels(around bubble: CGRect, radius: CGFloat, background: (red: Int, green: Int, blue: Int)) -> [CGPoint] {
        let outline = UIBezierPath(roundedRect: bubble.insetBy(dx: -1, dy: -1), cornerRadius: radius + 1)
        let side = radius
        let corners = [CGRect(x: bubble.minX, y: bubble.minY, width: side, height: side),
                       CGRect(x: bubble.maxX - side, y: bubble.minY, width: side, height: side),
                       CGRect(x: bubble.minX, y: bubble.maxY - side, width: side, height: side),
                       CGRect(x: bubble.maxX - side, y: bubble.maxY - side, width: side, height: side)]
        var stray: [CGPoint] = []
        for corner in corners {
            for y in Int(corner.minY * scale) ..< Int(corner.maxY * scale) {
                for x in Int(corner.minX * scale) ..< Int(corner.maxX * scale) {
                    let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                    guard !outline.contains(point) else { continue }
                    let (red, green, blue) = pixel(x, y)
                    if abs(red - background.red) > 3 || abs(green - background.green) > 3 || abs(blue - background.blue) > 3 {
                        stray.append(point)
                    }
                }
            }
        }
        return stray
    }

    /// The vertical extents, in points, of the lines of light text in a region: runs of rows with a near-white pixel.
    func textLines(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> [ClosedRange<CGFloat>] {
        var lines: [ClosedRange<Int>] = []
        for row in Int(y.lowerBound * scale) ..< Int(y.upperBound * scale) {
            let ink = (Int(x.lowerBound * scale) ..< Int(x.upperBound * scale)).contains { column in
                let (red, green, blue) = pixel(column, row)
                return min(red, green, blue) > 180
            }
            guard ink else { continue }
            if let last = lines.last, row - last.upperBound <= 2 { lines[lines.count - 1] = last.lowerBound ... row } else { lines.append(row ... row) }
        }
        return lines.map { CGFloat($0.lowerBound) / scale ... CGFloat($0.upperBound + 1) / scale }
    }
}
