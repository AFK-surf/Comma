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
/// row's id to Electron Main.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let menu = NSMenu()
    private let onSelect: (String) -> Void
    private var item: NSStatusItem?
    private var iconPath: String?
    private var menuOpen = false
    private var pendingRows: (rows: [CommaStatusMenuShowRow], width: CGFloat)?

    init(onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    /// Shows the item with these rows. Rows that arrive while the menu is open
    /// wait until it closes: replacing them would move the row under the pointer.
    func show(iconPath: String, toolTip: String, rows: [CommaStatusMenuShowRow], width: Double) {
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.menu = menu
            self.item = item
        }
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
        pendingRows = nil
        menuOpen = false
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        // AppKit sends the chosen row's action after this; rows that waited
        // are applied once it has.
        Task { @MainActor [weak self] in
            self?.applyPendingRows()
        }
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelect(id)
    }

    private func applyPendingRows() {
        guard !menuOpen, let pending = pendingRows else { return }
        pendingRows = nil
        rebuild(rows: pending.rows, width: pending.width)
    }

    private func rebuild(rows: [CommaStatusMenuShowRow], width: CGFloat) {
        let font = NSFont.menuFont(ofSize: 0)
        // AppKit's padding around a plain title, and around a title whose last
        // tab stop is at a known place. It differs between macOS versions.
        let probe = "MMMMMMMMMM"
        let plainPadding = Self.menuWidth(NSMenuItem(title: probe, action: nil, keyEquivalent: ""))
            - Self.textWidth(probe, font: font)
        let probeTab: CGFloat = 200
        let tabPadding = Self.menuWidth(Self.shortcutItem("M", shortcut: "M", tab: probeTab, font: font))
            - probeTab

        // Every shortcut ends at one edge. A shortcut row is never cut: one too
        // wide for the requested width moves the edge out instead.
        let minimumGap: CGFloat = 24
        var edge = width - tabPadding
        for row in rows where row.kind == .item {
            guard let shortcut = row.shortcut else { continue }
            edge = max(
                edge,
                Self.textWidth(row.title ?? "", font: font) + minimumGap + Self.textWidth(shortcut, font: font)
            )
        }
        // A plain title ends where the shortcuts end.
        let titleLimit = edge + tabPadding - plainPadding

        menu.removeAllItems()
        for row in rows {
            let title = row.title ?? ""
            switch row.kind {
            case .separator:
                menu.addItem(.separator())
            case .header:
                menu.addItem(.sectionHeader(title: title))
            case .item:
                let item = row.shortcut.map { Self.shortcutItem(title, shortcut: $0, tab: edge, font: font) }
                    ?? NSMenuItem(
                        title: Self.fittedTitle(title, limit: titleLimit, font: font),
                        action: nil,
                        keyEquivalent: ""
                    )
                item.target = self
                item.action = #selector(select(_:))
                item.representedObject = row.id
                menu.addItem(item)
            }
        }
    }

    private static func shortcutItem(_ title: String, shortcut: String, tab: CGFloat, font: NSFont) -> NSMenuItem {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: tab)]
        let text = NSMutableAttributedString(
            string: "\(title)\t",
            attributes: [.font: font, .paragraphStyle: style]
        )
        // A highlighted row draws secondary label color in its selected text
        // color, as it does a key equivalent.
        text.append(NSAttributedString(
            string: shortcut,
            attributes: [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor]
        ))
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
