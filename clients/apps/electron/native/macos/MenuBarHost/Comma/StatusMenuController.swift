import AppKit
import CoreText

/// The Comma item in the macOS menu bar and its menu.
///
/// AppKit tracks a menu on the main thread of the process that owns it. In
/// Electron Main that thread also runs the product runtime, and its tasks
/// delayed the hover highlight. This helper's main thread is otherwise idle.
///
/// No row has a key equivalent, so AppKit reserves no key-equivalent column: a
/// shortcut is secondary text at a right-aligned tab stop, and a Task title can
/// use the whole width. The helper runs no row itself; it reports the chosen
/// row's id to Electron Main. With a click id, a left click on the item reports
/// that id instead of opening the menu, which then opens on a right click or a
/// Control-click. With an open id, it reports that id as the menu opens, and
/// rows that Main sends back then update the open menu in place where they
/// can; with a close id, it reports that id once the menu has closed.
///
/// A meter row shows usage: its title and figure, and a bar under them. It is a
/// view, which AppKit neither highlights nor lets the person choose.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let menu = NSMenu()
    private let onSelect: (String) -> Void
    private var item: NSStatusItem?
    private var iconPath: String?
    private var clickId: String?
    private var openId: String?
    private var closeId: String?
    private var menuOpen = false
    private var pendingRows: (rows: [CommaStatusMenuShowRow], width: CGFloat)?
    /// The rows the menu shows, its items in the same order, and where their
    /// right-hand text ends.
    private var shownRows: [CommaStatusMenuShowRow] = []
    private var layout = Layout(edge: 0, tabPadding: 0, titleLimit: 0)

    init(onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    /// Shows the item with these rows. Rows that arrive while the menu is open
    /// wait until it closes: replacing them would move the row under the pointer.
    func show(
        iconPath: String,
        toolTip: String,
        rows: [CommaStatusMenuShowRow],
        width: Double,
        clickId: String?,
        openId: String?,
        closeId: String?
    ) {
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            // The menu opens as the right button goes down, as a menu-bar menu
            // does; a left click acts once the button comes up.
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseDown])
            self.item = item
        }
        self.clickId = clickId
        self.openId = openId
        self.closeId = closeId
        applyClickMode()
        if iconPath != self.iconPath {
            self.iconPath = iconPath
            item?.button?.image = Self.templateImage(at: iconPath)
        }
        item?.button?.toolTip = toolTip
        pendingRows = (rows, CGFloat(width))
        applyPendingRows()
    }

    func hide() {
        if menuOpen { menu.cancelTrackingWithoutAnimation() }
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        iconPath = nil
        clickId = nil
        openId = nil
        closeId = nil
        pendingRows = nil
        shownRows = []
        menuOpen = false
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        if let openId { onSelect(openId) }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        applyClickMode()
        // AppKit sends the chosen row's action after this; rows that waited
        // are applied, and the close reported, once it has.
        Task { @MainActor [weak self] in
            guard let self else { return }
            applyPendingRows()
            if let closeId { onSelect(closeId) }
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let item, let clickId else { return }
        if Self.isLeftClick(NSApp.currentEvent, on: sender) {
            onSelect(clickId)
            return
        }
        // A right click or Control-click, and VoiceOver or the keyboard, which
        // press the item without a mouse event: the menu, as before. AppKit
        // opens an item's own menu at the item, highlighted; the menu leaves
        // the item again once it closes (`applyClickMode`).
        item.menu = menu
        sender.performClick(nil)
    }

    /// The left button coming up on the item now, without Control. An action
    /// without a mouse event leaves `currentEvent` at whatever came before.
    private static func isLeftClick(_ event: NSEvent?, on button: NSStatusBarButton) -> Bool {
        guard let event, event.type == .leftMouseUp, event.window === button.window,
              !event.modifierFlags.contains(.control)
        else { return false }
        return ProcessInfo.processInfo.systemUptime - event.timestamp < 1
    }

    /// Without a click id the item opens its menu itself, on any click; with
    /// one, clicks come to `clicked`. An open menu stays until it closes.
    private func applyClickMode() {
        guard !menuOpen else { return }
        item?.menu = clickId == nil ? menu : nil
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelect(id)
    }

    /// Rows apply at once while the menu is closed. While it is open, they
    /// update the rows it shows in place where they can, and wait until it
    /// closes for the rest, since replacing items would move the row under
    /// the pointer.
    private func applyPendingRows() {
        guard let pending = pendingRows else { return }
        if !menuOpen {
            pendingRows = nil
            rebuild(rows: pending.rows, width: pending.width)
        } else if update(to: pending.rows) {
            pendingRows = nil
        }
    }

    private struct Layout {
        /// Where every shortcut and right-hand detail ends.
        var edge: CGFloat
        /// AppKit's padding around a title whose last tab stop is at a known place.
        var tabPadding: CGFloat
        /// Where a plain title ends.
        var titleLimit: CGFloat
        /// Where a meter's figure and bar end: a tab stop is measured from
        /// where a row's text starts.
        var meterEnd: CGFloat { MeterRowView.leftInset + edge }
        var width: CGFloat { edge + tabPadding }
    }

    private static let menuFont = NSFont.menuFont(ofSize: 0)
    /// The least space between a title and its right-hand text.
    private static let minimumGap: CGFloat = 24

    /// What an item ends with at the right: its shortcut as secondary text,
    /// or its detail (a status such as "Updated 8m ago") in a capsule.
    private static func trailing(_ row: CommaStatusMenuShowRow) -> NSAttributedString? {
        guard row.kind == .item else { return nil }
        if let shortcut = row.shortcut {
            // A highlighted row draws secondary label color in its selected
            // text color, as it does a key equivalent.
            return NSAttributedString(
                string: shortcut,
                attributes: [.font: menuFont, .foregroundColor: NSColor.secondaryLabelColor]
            )
        }
        return row.detail.map { StatusCapsule.text($0, beside: menuFont) }
    }

    /// The width a row needs up to the edge where its right-hand text ends.
    private static func neededEdge(_ row: CommaStatusMenuShowRow) -> CGFloat {
        let font = menuFont
        switch row.kind {
        case .item:
            guard let trailing = trailing(row) else { return 0 }
            return textWidth(row.title ?? "", font: font) + minimumGap + trailing.size().width.rounded(.up)
        case .meter:
            return textWidth(row.title ?? "", font: font) + MeterRowView.gap
                + MeterRowView.detailWidth(row.detail ?? "")
        case .header, .separator:
            return 0
        }
    }

    private func rebuild(rows: [CommaStatusMenuShowRow], width: CGFloat) {
        let font = Self.menuFont
        // AppKit's padding around a plain title, and around a title whose last
        // tab stop is at a known place. It differs between macOS versions.
        let probe = "MMMMMMMMMM"
        let plainPadding = Self.menuWidth(NSMenuItem(title: probe, action: nil, keyEquivalent: ""))
            - Self.textWidth(probe, font: font)
        let probeTab: CGFloat = 200
        let tabPadding = Self.menuWidth(Self.tabbedItem(
            "M", NSAttributedString(string: "M", attributes: [.font: font]), tab: probeTab, font: font
        )) - probeTab

        // Every shortcut, detail and meter figure ends at one edge. None is
        // ever cut: a row too wide for the requested width moves the edge out.
        let edge = rows.reduce(width - tabPadding) { max($0, Self.neededEdge($1)) }
        layout = Layout(edge: edge, tabPadding: tabPadding, titleLimit: edge + tabPadding - plainPadding)

        menu.removeAllItems()
        for row in rows {
            menu.addItem(makeItem(row))
        }
        shownRows = rows
    }

    private func makeItem(_ row: CommaStatusMenuShowRow) -> NSMenuItem {
        let title = row.title ?? ""
        switch row.kind {
        case .separator:
            return .separator()
        case .header:
            return .sectionHeader(title: Self.headerTitle(title))
        case .meter:
            let item = NSMenuItem(title: MeterRowView.Model(row).spoken, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.view = MeterRowView(model: MeterRowView.Model(row), width: layout.width, end: layout.meterEnd)
            return item
        case .item:
            let item = itemTitle(NSMenuItem(title: "", action: #selector(select(_:)), keyEquivalent: ""), row)
            item.target = self
            item.representedObject = row.id
            return item
        }
    }

    /// An item's title, with its shortcut or detail at the edge.
    @discardableResult
    private func itemTitle(_ item: NSMenuItem, _ row: CommaStatusMenuShowRow) -> NSMenuItem {
        let title = row.title ?? ""
        if let trailing = Self.trailing(row) {
            let styled = Self.tabbedItem(title, trailing, tab: layout.edge, font: Self.menuFont)
            item.title = styled.title
            item.attributedTitle = styled.attributedTitle
        } else {
            item.attributedTitle = nil
            item.title = Self.fittedTitle(title, limit: layout.titleLimit, font: Self.menuFont)
        }
        return item
    }

    /// Updates the open menu's items in place from `rows`: each row that an
    /// item shows already (the same id and kind, or the header or separator at
    /// its place) and whose text fits the menu's edge. A meter's bar shows only
    /// in a view made with one. True when the menu then shows `rows` exactly;
    /// false leaves the rest to wait until it closes.
    private func update(to rows: [CommaStatusMenuShowRow]) -> Bool {
        let samePlaces = rows.count == shownRows.count && rows.count == menu.items.count
        var exact = samePlaces
        for (index, row) in rows.enumerated() {
            let shown: Int? = if let id = row.id {
                shownRows.firstIndex { $0.id == id && $0.kind == row.kind }
            } else if samePlaces, shownRows[index].kind == row.kind {
                index
            } else {
                nil
            }
            guard let shown, shown < menu.items.count, fits(row, in: menu.items[shown]) else {
                exact = false
                continue
            }
            let item = menu.items[shown]
            if shown != index || row.fraction != nil && (item.view as? MeterRowView)?.hasBar != true {
                exact = false
            }
            switch row.kind {
            case .separator:
                break
            case .header:
                item.title = Self.headerTitle(row.title ?? "")
            case .meter:
                item.title = MeterRowView.Model(row).spoken
                (item.view as? MeterRowView)?.model = MeterRowView.Model(row)
            case .item:
                itemTitle(item, row)
            }
            shownRows[shown] = row
        }
        return exact
    }

    /// Whether `item` can show `row` without the menu changing size.
    private func fits(_ row: CommaStatusMenuShowRow, in item: NSMenuItem) -> Bool {
        switch row.kind {
        case .separator, .header:
            return true
        case .item:
            return Self.neededEdge(row) <= layout.edge
        case .meter:
            // The title gives way to the figure.
            return item.view is MeterRowView && MeterRowView.detailWidth(row.detail ?? "") <= layout.edge
        }
    }

    /// Section titles in capitals, as the menu's small grey labels ("PLAN
    /// USAGE"); a script without case keeps its text.
    private static func headerTitle(_ title: String) -> String {
        title.localizedUppercase
    }

    /// An item whose title is `title`, then `trailing` ending at a right tab stop.
    private static func tabbedItem(_ title: String, _ trailing: NSAttributedString, tab: CGFloat, font: NSFont) -> NSMenuItem {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: tab)]
        let text = NSMutableAttributedString(string: "\(title)\t", attributes: [.font: font])
        text.append(trailing)
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = text
        return item
    }

    private static func menuWidth(_ item: NSMenuItem) -> CGFloat {
        let menu = NSMenu()
        menu.addItem(item)
        return menu.size.width
    }

    /// The width CoreText gives `text` in the menu font, with the per-glyph
    /// fallback (CJK, emoji) the menu uses.
    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// The whole title, or its longest prefix whose "…" form fits `limit`.
    private static func fittedTitle(_ title: String, limit: CGFloat, font: NSFont) -> String {
        guard textWidth(title, font: font) > limit else { return title }
        let glyphs = Array(title)
        func truncated(_ count: Int) -> String {
            var prefix = String(glyphs[..<count])
            while prefix.last?.isWhitespace == true { prefix.removeLast() }
            return prefix + "…"
        }
        // Binary search: `fits` always fits, `tooLong` never does.
        var fits = 0
        var tooLong = glyphs.count
        while tooLong - fits > 1 {
            let middle = (fits + tooLong) / 2
            if textWidth(truncated(middle), font: font) <= limit {
                fits = middle
            } else {
                tooLong = middle
            }
        }
        return truncated(fits)
    }

    /// A template image from a PNG and, when it exists, its "@2x" sibling.
    private static func templateImage(at path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url), let base = NSBitmapImageRep(data: data) else {
            return nil
        }
        let size = NSSize(width: base.pixelsWide, height: base.pixelsHigh)
        base.size = size
        let image = NSImage(size: size)
        image.addRepresentation(base)
        let retinaURL = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent)@2x.\(url.pathExtension)"
        )
        if let retinaData = try? Data(contentsOf: retinaURL), let retina = NSBitmapImageRep(data: retinaData) {
            retina.size = size
            image.addRepresentation(retina)
        }
        image.isTemplate = true
        return image
    }
}

/// A usage row: its title and figure on one line and, when it has a fraction,
/// a bar filled to it under them. Text sits where the menu's titles and
/// shortcuts sit, whatever width a long header gives the menu.
private final class MeterRowView: NSView {
    struct Model: Equatable {
        var title: String
        var detail: String
        var fraction: Double?
        var critical: Bool

        init(_ row: CommaStatusMenuShowRow) {
            title = row.title ?? ""
            detail = row.detail ?? ""
            fraction = row.fraction
            critical = row.tone == .critical
        }

        /// What VoiceOver reads, and the item's title.
        var spoken: String { detail.isEmpty ? title : "\(title), \(detail)" }
    }

    /// Where a row's text starts: AppKit's title field at 14 pt and the
    /// field's own 2 pt inset, as macOS 26 draws a menu without images.
    static let leftInset: CGFloat = 16
    /// The least space between the title and the figure.
    static let gap: CGFloat = 8
    /// A row with a bar: its title line, the bar well under it, and room
    /// before the next row.
    private static let barRowHeight: CGFloat = 52
    private static let barTop: CGFloat = 30
    private static let barHeight: CGFloat = 8

    static func detailFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
    }

    static func detailWidth(_ detail: String) -> CGFloat {
        NSAttributedString(string: detail, attributes: [.font: detailFont()]).size().width.rounded(.up)
    }

    var model: Model {
        didSet {
            guard model != oldValue else { return }
            needsDisplay = true
            setAccessibilityLabel(model.spoken)
        }
    }

    /// Where the figure and the bar end.
    private let end: CGFloat
    /// The row has room for a bar: one made with a bar keeps its height when
    /// an update takes the bar away.
    let hasBar: Bool

    init(model: Model, width: CGFloat, end: CGFloat) {
        self.model = model
        self.end = end
        hasBar = model.fraction != nil
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: hasBar ? Self.barRowHeight : 24))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(model.spoken)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let left = Self.leftInset
        let detail = NSAttributedString(
            string: model.detail,
            attributes: [.font: Self.detailFont(), .foregroundColor: NSColor.secondaryLabelColor]
        )
        let detailWidth = Self.detailWidth(model.detail)
        detail.draw(at: NSPoint(x: end - detailWidth, y: 4))

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        NSAttributedString(
            string: model.title,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        ).draw(in: NSRect(x: left, y: 4, width: max(0, end - detailWidth - Self.gap - left), height: 18))

        guard hasBar, let fraction = model.fraction else { return }
        let radius = Self.barHeight / 2
        let track = NSRect(x: left, y: Self.barTop, width: max(0, end - left), height: Self.barHeight)
        // A faint track with a hairline edge; nothing used is a dot at its start.
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let edge = NSBezierPath(roundedRect: track.insetBy(dx: 0.25, dy: 0.25), xRadius: radius - 0.25, yRadius: radius - 0.25)
        edge.lineWidth = 0.5
        NSColor.labelColor.withAlphaComponent(0.06).setStroke()
        edge.stroke()
        var filled = track
        filled.size.width = max(Self.barHeight, track.width * min(1, max(0, fraction)))
        (model.critical ? NSColor.systemRed : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

/// An item's status at the right edge, in a grey capsule: "Updated 8m ago".
private enum StatusCapsule {
    private static let height: CGFloat = 16
    private static let padding: CGFloat = 9

    private static func font(beside font: NSFont) -> NSFont {
        NSFont.systemFont(ofSize: font.pointSize - 3, weight: .medium)
    }

    /// The capsule as text: an image attachment centred on the line of `font`.
    static func text(_ status: String, beside font: NSFont) -> NSAttributedString {
        let label = NSAttributedString(
            string: status,
            attributes: [.font: Self.font(beside: font), .foregroundColor: NSColor.labelColor]
        )
        let labelSize = label.size()
        let size = NSSize(width: (labelSize.width + padding * 2).rounded(.up), height: height)
        // Drawn as the menu draws, in its appearance.
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.tertiarySystemFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
            label.draw(at: NSPoint(x: (rect.width - labelSize.width) / 2, y: (rect.height - labelSize.height) / 2))
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(
            x: 0, y: ((font.capHeight - height) / 2).rounded(), width: size.width, height: size.height
        )
        return NSAttributedString(attachment: attachment)
    }
}
