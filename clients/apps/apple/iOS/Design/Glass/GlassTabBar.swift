import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Liquid Glass overflow menu overlay presented from a real `UITabBarController`'s 4th slot (`More`).
///
/// Resting, tab tapping, tab dragging, Duo vertical side-bar widening (`48pt <-> 72.5pt`), and the single-element
/// 120 Hz `_UILiquidLensView` across all 5 postures are owned 100 % natively by `UITabBarController`. This view stays
/// hidden (`isHidden = true`, zero `CADisplayLink` ticks) until the user taps or drags onto the overflow slot, at which
/// point `bar` (`UIGlassEffect(.regular)`) takes over seamlessly at the native platter's exact live frame, grows into
/// the overflow row panel, and folds back cleanly before handing back to `UITabBarController`.
@available(iOS 26.0, *)
final class TabOverflowMenuView: UIView {
    struct Item: Equatable {
        let id: String
        let title: String
        let image: UIImage?
        var selectedImage: UIImage?
    }

    enum Orientation: Equatable {
        case horizontal
        case vertical(trailing: Bool)
    }

    struct Anchor {
        /// Native resting primary tab platter rect in `TabOverflowMenuView`'s coordinates.
        let platterFrame: CGRect
        /// Native resting slot button rects (`0..<primaryItems.count + 1`) in `TabOverflowMenuView`'s coordinates.
        let slotFrames: [CGRect]
        let orientation: Orientation
        let selectedSlot: Int
        let overflowSelected: Bool
        /// Live presentation rect and lift (`0...1`) of the native selection lens, in `TabOverflowMenuView`'s
        /// coordinates, when handing off mid-drag.
        let handoffLens: (frame: CGRect, lift: CGFloat)?
        /// Optional live minor-axis thickness (e.g. a widened Duo vertical rail during drag) so the opening morph
        /// starts from the live bar width and closes back to the resting `platterFrame` thickness.
        var initialThickness: CGFloat? = nil
        /// Native resting selection pill size in screen points (e.g. `76×54` portrait, `66×36` compact, `44×58` Duo
        /// vertical) so the closing morph lands at 0.0 pt against the native selection pill.
        var restingPillSize: CGSize? = nil
        /// Native outer-slot edge inset along the bar's major axis (from platter edge to resting selection pill),
        /// measured directly from `UITabBar` so outer-slot handoffs land at 0.0 px horizontally and vertically.
        var restingPillEdgeInset: CGFloat? = nil
    }

    enum Metrics {
        static let menuRow: CGFloat = 48
        static let menuPadding: CGFloat = 8
        static let sideMenuWidth: CGFloat = 224
        static let glyph: CGFloat = 24
        /// How far the outgoing and incoming contents blur while the bar turns into the menu and back.
        static let morphBlur: CGFloat = 12
        static let morphDuration: TimeInterval = 0.35
        static let morphBounce: CGFloat = 0.28
        /// Peak major-axis squeeze ratio during opening (`20%` narrower at peak) driven by a critically-damped
        /// spring ease-out (`squeezeResponse`) so the glass pulls in briskly and blooms back out smoothly.
        static let morphSqueeze: CGFloat = 0.20
        static let squeezeResponse: TimeInterval = 0.50
        /// Peak major-axis squeeze ratio during closing (`18%` narrower at peak) with a critically-damped spring
        /// ease-out (`squeezeCloseResponse`) so closing mirrors opening's elastic pinch and settles at 0.0 px.
        static let closeSqueeze: CGFloat = 0.18
        static let squeezeCloseResponse: TimeInterval = 0.36
        /// Closing settles briskly without bouncing below bar thickness, paired with `closeSqueeze`.
        static let closeDuration: TimeInterval = 0.28
        static let closeDamping: CGFloat = 0.94
        /// Each row rises from this far below, overshoots a little and settles, one after another from the bottom.
        static let rowRise: CGFloat = 14
        static let rowStagger: TimeInterval = 0.032
        static let rowDelay: TimeInterval = 0.045
        static let rowSpring = Animation.spring(duration: 0.38, bounce: 0.42)
        static let rowFade = Animation.easeOut(duration: 0.16)
        /// The menu indicator: how fast it follows the finger to a new row and fades in or out, and by how far into
        /// the glass's growth a lens it starts from has turned grey.
        static let indicatorFollow: TimeInterval = 0.05
        static let indicatorFade: TimeInterval = 0.08
        static let lensToGrey: CGFloat = 0.35
        /// How far a finger that opened the menu moves off the bar before picking rows.
        static let menuReach: CGFloat = 20
        /// How long a dragging finger rests on the last slot before the menu opens.
        static let menuDwell: TimeInterval = 0.3
        static let dwellSlop: CGFloat = 8
    }

    // MARK: Model

    var primaryItems: [Item] = []
    var overflow: [Item] = [] { didSet { if overflow != oldValue { rebuildMenu() } } }
    /// Exact `moreTab.image` / `moreTab.selectedImage` rendered by `UITabBar`, drawn 1:1 in `tabRowImage` and
    /// `handoffGlyph` so the 4th slot's icon and chevron have 0.0 pt jump when handing off to/from native `UITabBar`.
    var moreTabArt: (normal: UIImage?, selected: UIImage?)?
    var selectedID = "" { didSet { if selectedID != oldValue { refreshRows() } } }
    var overflowID = "" { didSet { if overflowID != oldValue { refreshRows() } } }
    var itemValues: [String: String] = [:] { didSet { if itemValues != oldValue { refreshRows() } } }
    var onPick: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    /// Called with `true` the frame the overlay takes over the native platter, and `false` once the closing morph lands.
    var onVisibilityChange: ((Bool) -> Void)?
    /// Called with `true` while the menu is open (modal) and `false` as soon as closing starts (so AX is restored before close lands).
    var onOpenChange: ((Bool) -> Void)?
    /// Called each morph frame with how visible the resting tab row is (`1` at rest, `0` when open) so unread dots fade cleanly.
    var onTabsShownChange: ((CGFloat) -> Void)?

    private(set) var isOpen = false
    private(set) var isMorphing = false
    private(set) var isTracking = false
    var isActive: Bool { isOpen || isMorphing }
    private(set) var tabsShown: CGFloat = 1
    /// Current major-axis scale factor of the squeezing glass platter (`1.0` at rest, `< 1.0` while pinched).
    var barMajorScale: CGFloat {
        barFrame.width > 0 ? max(bar.bounds.width / barFrame.width, 0.01) : 1
    }

    // MARK: Orientation & Anchor Geometry

    private var orientation: Orientation = .horizontal
    private var isVertical: Bool { orientation != .horizontal }
    private var mirrored: Bool { orientation == .vertical(trailing: true) }
    private var canvasAngle: CGFloat {
        switch orientation {
        case .horizontal: 0
        case .vertical(let trailing): trailing ? -.pi / 2 : .pi / 2
        }
    }
    private let canvas = UIView()
    /// Native platter frame in `canvas` coordinates.
    private var barFrame: CGRect = .zero
    /// Native slot rects in `barFrame`-local coordinates.
    private var slotFramesInBar: [CGRect] = []
    private var restingPillSizeInBar: CGSize?
    private var restingPillEdgeInsetInBar: CGFloat?
    private var anchorSelectedSlot = 0
    private var anchorOverflowSelected = false

    private var thickness: CGFloat { max(barFrame.height, 44) }

    /// The bar grown into the menu: as long as the bar, anchored to its outer edge (`barFrame.maxY` in `canvas`).
    private var menuFrame: CGRect {
        let bar = barFrame
        let height = isVertical
            ? Metrics.sideMenuWidth
            : max(bar.height, CGFloat(overflow.count) * Metrics.menuRow + Metrics.menuPadding * 2)
        return CGRect(x: bar.minX, y: bar.maxY - height, width: bar.width, height: height)
    }

    private func canvasPoint(_ point: CGPoint) -> CGPoint { convert(point, to: canvas) }

    // MARK: Views

    private let bar = UprightGlass(effect: {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        return glass
    }())
    /// Unclipped clear Liquid Glass lens sitting ABOVE `bar.glass` during the opening handoff (`0...lensToGrey`) so a
    /// lifted native lens stays pixel-continuous across the takeover frame (never sliced by `menuClip`) while crossfading
    /// into the frosted grey `menuIndicator`. `handoffGlyph` draws the magnified `More` icon inside `handoffGlass` (above
    /// its refraction layer) so `UIGlassEffect(.clear)` never smears the blue avatar onto the lens rim.
    private let handoffGlass = UprightGlass(effect: {
        let glass = UIGlassEffect(style: .clear)
        glass.isInteractive = false
        return glass
    }())
    private let handoffGlyph: UIImageView = {
        let view = UIImageView()
        view.contentMode = .center
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }()
    private var handoffGlyphOffset: CGPoint = .zero
    private let tabContent = UIView()
    private let pill = UIView()
    private let menuClip = UIView()
    private let menuIndicator = UIView()
    private let indicatorFill = UIView()
    private let indicatorFrost = TabOverflowMenuView.makeSelectionFrost()
    /// Clean native-matched pill fill crossfaded in as `menuIndicator` lands on the 4th slot (and out when opening
    /// from an overflow tab) so the final closing frame matches Apple's native `UITabBar` pill in both Light & Dark.
    private let indicatorNativeFill = UIView()
    private let menuRows = UIView()
    private var rowViews: [MenuRow] = []
    private let menu = MenuModel()
    private lazy var menuRowsView: UIView = Self.host(MenuRowsLayer(model: menu))
    private lazy var tabSnapshotView: UIView = Self.host(TabSnapshotLayer(model: menu))

    private static func host<Content: View>(_ content: Content) -> UIView {
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        return host.view
    }

    private var link: CADisplayLink?
    private var trackUntil: CFTimeInterval = 0
    private let selection = UISelectionFeedbackGenerator()

    // MARK: Tracking State

    private var hoveredRow: Int?
    private var menuOpenPoint: CGPoint?
    private var fingerInRows = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isHidden = true
        isUserInteractionEnabled = false

        canvas.isUserInteractionEnabled = false
        addSubview(canvas)

        bar.canvas = canvas
        bar.glass.accessibilityIdentifier = "glassTabBar.bar"
        bar.cornerConfiguration = .uniformCorners(radius: .fixed(31))
        addSubview(bar.glass)

        handoffGlass.canvas = canvas
        handoffGlass.glass.accessibilityIdentifier = "glassTabBar.handoffLens"
        handoffGlass.glass.isUserInteractionEnabled = false
        handoffGlass.glass.alpha = 0
        handoffGlass.isHidden = true
        handoffGlass.cornerConfiguration = .capsule()
        handoffGlass.contentView.addSubview(handoffGlyph)
        addSubview(handoffGlass.glass)

        pill.accessibilityIdentifier = "glassTabBar.pill"
        pill.isUserInteractionEnabled = false
        pill.clipsToBounds = true
        pill.layer.cornerCurve = .continuous
        pill.backgroundColor = Self.nativePillFill
        tabContent.isUserInteractionEnabled = false
        tabContent.accessibilityElementsHidden = true
        tabContent.addSubview(pill)
        tabContent.autoresizingMask = []
        bar.contentView.addSubview(tabContent)

        menuClip.isUserInteractionEnabled = false
        menuClip.clipsToBounds = true
        menuClip.layer.cornerCurve = .continuous
        menuClip.layer.cornerRadius = 31
        menuClip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        for layer in [menuRowsView, tabSnapshotView] {
            layer.backgroundColor = .clear
            layer.isUserInteractionEnabled = false
            menuClip.addSubview(layer)
        }
        menuRowsView.autoresizingMask = []
        tabSnapshotView.autoresizingMask = []
        bar.contentView.addSubview(menuClip)

        // Clipped inside `menuClip` below `menuRowsView` so the indicator never protrudes during `morphSqueeze`.
        // `indicatorFrost` keeps constant non-resizing bounds covering both horizontal and rotated vertical rows so
        // `CABackdropLayer` never reallocates GPU surfaces per frame and never clips vertical rows.
        menuIndicator.accessibilityIdentifier = "glassTabBar.menuIndicator"
        menuIndicator.isUserInteractionEnabled = false
        menuIndicator.alpha = 0
        menuIndicator.isHidden = true
        indicatorFill.clipsToBounds = true
        indicatorFill.layer.cornerCurve = .continuous
        indicatorFill.frame = menuIndicator.bounds
        indicatorFill.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        indicatorFrost.autoresizingMask = []
        indicatorFrost.frame = CGRect(origin: .zero, size: CGSize(width: 360, height: 260))
        indicatorFill.addSubview(indicatorFrost)
        indicatorNativeFill.backgroundColor = Self.nativePillFill
        indicatorNativeFill.isUserInteractionEnabled = false
        indicatorNativeFill.alpha = 0
        indicatorNativeFill.frame = indicatorFill.bounds
        indicatorNativeFill.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        indicatorFill.addSubview(indicatorNativeFill)
        menuIndicator.addSubview(indicatorFill)
        menuClip.insertSubview(menuIndicator, belowSubview: menuRowsView)

        menuRows.isHidden = true
        menuRows.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bar.contentView.addSubview(menuRows)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, isOpen else { return nil }
        return self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCanvasBounds()
        guard isActive else { return }
        if !isMorphing {
            glassHeight = isOpen ? menuFrame.height : thickness
            glassInset = 0
        }
        bar.bounds = CGRect(x: 0, y: 0, width: barFrame.width - glassInset * 2, height: glassHeight)
        bar.center = CGPoint(x: barFrame.midX, y: barFrame.maxY - glassHeight / 2)
        layoutGlassContent()
    }

    private func applyCanvasBounds() {
        canvas.transform = .identity
        canvas.bounds = isVertical ? CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width) : bounds
        canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
        canvas.transform = CGAffineTransform(rotationAngle: canvasAngle)
        bar.angle = canvasAngle
        handoffGlass.angle = canvasAngle
    }

    // MARK: Public Control

    func open(anchor: Anchor, tracking: Bool, at point: CGPoint?) {
        guard !isOpen, !overflow.isEmpty else { return }
        orientation = anchor.orientation
        applyCanvasBounds()
        barFrame = canvas.convert(anchor.platterFrame, from: self)
        slotFramesInBar = anchor.slotFrames.map { rect in
            canvas.convert(rect, from: self).offsetBy(dx: -barFrame.minX, dy: -barFrame.minY)
        }
        restingPillSizeInBar = anchor.restingPillSize.map { sz in
            isVertical ? CGSize(width: sz.height, height: sz.width) : sz
        }
        restingPillEdgeInsetInBar = anchor.restingPillEdgeInset
        anchorSelectedSlot = anchor.selectedSlot
        anchorOverflowSelected = anchor.overflowSelected

        let radius = thickness / 2
        bar.cornerConfiguration = .uniformCorners(radius: .fixed(radius))
        handoffGlass.cornerConfiguration = isVertical ? .capsule(maximumRadius: 37) : .capsule()
        menuClip.layer.cornerRadius = radius
        if !isMorphing {
            let startHeight = max(thickness, anchor.initialThickness ?? thickness)
            glassHeight = startHeight
            glassTarget = startHeight
            glassVelocity = 0
            glassSqueeze = 0
            glassSqueezeVelocity = 0
            glassInset = 0
        }

        let handoffInBar: (frame: CGRect, lift: CGFloat)? = anchor.handoffLens.map { lens in
            let rect = canvas.convert(lens.frame, from: self).offsetBy(dx: -barFrame.minX, dy: -barFrame.minY)
            return (rect, lens.lift)
        }

        isOpen = true
        isTracking = tracking
        fingerInRows = false
        menuOpenPoint = tracking ? point.map(canvasPoint) : nil
        hoveredRow = nil

        isHidden = false
        isUserInteractionEnabled = true
        accessibilityViewIsModal = true
        if !isMorphing {
            setMenuState { menu.tabs = tabRowImage(handoffLens: handoffInBar) }
        }
        if let lens = handoffInBar, lens.lift > 0.05 {
            let moreRect = restingSlotFrame(primaryItems.count)
            let zoom = 1 + 0.18 * lens.lift
            let img = overflowGlyphImage(zoom: zoom)
            handoffGlyph.image = img
            handoffGlyph.bounds = CGRect(origin: .zero, size: img?.size ?? .zero)
            handoffGlyphOffset = CGPoint(x: moreRect.midX - lens.frame.midX, y: moreRect.midY - lens.frame.midY)
            handoffGlyph.alpha = 1
        } else {
            handoffGlyph.image = nil
            handoffGlyph.alpha = 0
            handoffGlyphOffset = .zero
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.bounds = CGRect(origin: .zero, size: CGSize(width: barFrame.width - glassInset * 2, height: glassHeight))
        bar.center = CGPoint(x: barFrame.midX, y: barFrame.maxY - glassHeight / 2)
        layoutGlassContent()
        let lift = handoffInBar?.lift ?? 0
        if !anchorOverflowSelected, lift <= 0.05 {
            placeMorphPillAtSelectedSlot()
            setPillAlpha(1)
        } else {
            setPillAlpha(0)
        }
        tabContent.isHidden = anchorOverflowSelected || lift > 0.05
        menuClip.layoutIfNeeded()
        tabSnapshotView.layoutIfNeeded()
        CATransaction.commit()

        onOpenChange?(true)
        onVisibilityChange?(true)
        startIndicator(tracking: tracking, handoffLens: handoffInBar)
        selection.selectionChanged()
        startOpeningSqueeze()
        startMorph(to: menuFrame.height, response: Metrics.morphDuration, damping: 1 - Metrics.morphBounce)
        riseRows()
    }

    func beginTracking(at point: CGPoint) {
        guard isOpen else { return }
        isTracking = true
        fingerInRows = false
        menuOpenPoint = nil
        trackMenu(canvasPoint(point))
    }

    func updateTracking(at point: CGPoint) {
        guard isOpen, isTracking else { return }
        trackMenu(canvasPoint(point))
    }

    func endTracking(at point: CGPoint) {
        guard isOpen, isTracking else { return }
        let local = canvasPoint(point)
        isTracking = false
        if menuOpenPoint != nil {
            menuOpenPoint = nil
            openRow = nil
            return
        }
        if let row = row(at: local) {
            pickRow(row)
            return
        }
        close()
    }

    func cancelTracking() {
        guard isOpen else { return }
        isTracking = false
        close()
    }

    func close(anchor: Anchor? = nil) {
        guard isOpen else { return }
        if let anchor {
            anchorSelectedSlot = anchor.selectedSlot
            anchorOverflowSelected = anchor.overflowSelected
        }
        isOpen = false
        isTracking = false
        menuOpenPoint = nil
        menuRows.isHidden = true
        accessibilityViewIsModal = false
        onOpenChange?(false)
        setMenuState { menu.closing = true }
        endIndicator()
        if !anchorOverflowSelected {
            placeMorphPillAtSelectedSlot()
            tabContent.isHidden = false
        }
        if !isMorphing {
            setMenuState { menu.tabs = tabRowImage() }
        }
        startClosingSqueeze()
        startMorph(to: thickness, response: Metrics.closeDuration, damping: Metrics.closeDamping)
    }

    func dismissImmediately() {
        guard isActive else { return }
        let wasOpen = isOpen
        isOpen = false
        isTracking = false
        isMorphing = false
        glassSqueeze = 0
        glassSqueezeVelocity = 0
        glassInset = 0
        menuOpenPoint = nil
        menuRows.isHidden = true
        accessibilityViewIsModal = false
        if wasOpen { onOpenChange?(false) }
        link?.invalidate()
        link = nil
        setPillAlpha(0)
        setMenuIndicatorAlpha(0)
        handoffGlass.glass.alpha = 0
        handoffGlass.isHidden = true
        handoffGlyph.image = nil
        handoffGlyph.alpha = 0
        indicatorLeg = nil
        indicatorTarget = nil
        hoveredRow = nil
        openRow = nil
        lastPickedRow = nil
        setMenuState {
            menu.closing = true
            menu.progress = 0
            menu.tabs = nil
        }
        tabsShown = 1
        onTabsShownChange?(1)
        isHidden = true
        isUserInteractionEnabled = false
        onVisibilityChange?(false)
    }

    // MARK: Rows & Snapshot

    private func rebuildMenu() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = overflow.enumerated().map { index, item in
            let row = MenuRow(title: item.title)
            row.accessibilityIdentifier = item.id
            row.onActivate = { [weak self] in self?.pickRow(index) }
            menuRows.addSubview(row)
            return row
        }
        refreshRows()
        setNeedsLayout()
    }

    private func refreshRows() {
        rowViews.enumerated().forEach { index, row in
            guard index < overflow.count else { return }
            row.accessibilityTraits = overflow[index].id == selectedID ? [.button, .selected] : .button
            row.accessibilityValue = itemValues[overflow[index].id]
        }
        let rows = overflow.map { item in
            MenuModel.Row(id: item.id, title: item.title,
                          icon: item.id == selectedID ? (item.selectedImage ?? item.image) : item.image)
        }
        if menu.rows != rows { menu.rows = rows }
    }

    private func layoutGlassContent() {
        let width = bar.bounds.width
        let height = bar.bounds.height
        let scaleX = barMajorScale
        tabContent.frame = CGRect(x: 0, y: height - thickness, width: width, height: thickness)
        if !tabContent.isHidden {
            placeMorphPillAtSelectedSlot()
        }
        let size = menuFrame.size
        menuRows.frame = CGRect(x: -glassInset, y: height - size.height, width: size.width, height: size.height)
        for (i, row) in rowViews.enumerated() { row.frame = rowFrame(i) }
        menuClip.frame = bar.contentView.bounds
        let rowsFrame = CGRect(x: -glassInset, y: 0, width: size.width, height: size.height)
        let upright = CGAffineTransform(rotationAngle: -canvasAngle)
        if menuRowsView.transform != upright { menuRowsView.transform = upright }
        menuRowsView.bounds = CGRect(origin: .zero, size: isVertical ? CGSize(width: size.height, height: size.width) : size)
        menuRowsView.center = CGPoint(x: rowsFrame.midX, y: rowsFrame.midY)
        let snapTransform = scaleX < 0.9995 ? CGAffineTransform(scaleX: scaleX, y: 1) : .identity
        if tabSnapshotView.transform != snapTransform { tabSnapshotView.transform = snapTransform }
        tabSnapshotView.bounds = CGRect(origin: .zero, size: CGSize(width: size.width, height: thickness))
        tabSnapshotView.center = CGPoint(x: width / 2, y: height - thickness / 2)
        let frostSize = CGSize(
            width: max(size.width, barFrame.width, 360),
            height: max(size.height, Metrics.menuRow, thickness, Metrics.sideMenuWidth, 260)
        )
        if indicatorFrost.bounds.size != frostSize {
            indicatorFrost.frame = CGRect(origin: .zero, size: frostSize)
        }
    }

    private func restingSlotFrame(_ index: Int) -> CGRect {
        guard index >= 0, index < slotFramesInBar.count else {
            return CGRect(x: 4, y: 4, width: max(44, barFrame.width - 8), height: max(36, thickness - 8))
        }
        return slotFramesInBar[index]
    }

    /// Exact resting selection pill frame inside `bar` (in canvas coordinates), matching Apple's native resting pill
    /// size (`76×54` portrait, `66×36` compact, `44×58` Duo vertical) and flush-to-edge placement for outer slots so
    /// the closing morph lands at 0.0 pt against the native pill.
    private func restingPillFrame(_ index: Int) -> CGRect {
        let slot = restingSlotFrame(index)
        let insetX: CGFloat = restingPillEdgeInsetInBar ?? (isVertical ? 1.5 : (thickness >= 54 ? 10.0 / 3.0 : 4))
        let insetY: CGFloat = isVertical ? 2 : 4
        let maxW = max(1, barFrame.width - insetX * 2)
        let maxH = max(1, thickness - insetY * 2)
        let pillSize: CGSize
        if let measured = restingPillSizeInBar, measured.width > 1, measured.height > 1 {
            pillSize = CGSize(width: min(measured.width, maxW), height: min(measured.height, maxH))
        } else {
            pillSize = CGSize(width: min(slot.width, maxW), height: min(slot.height, maxH))
        }
        let minX = insetX
        let maxX = max(insetX, barFrame.width - insetX - pillSize.width)
        let x: CGFloat
        if index == 0 || index == primaryItems.count {
            // Flush outer slot pills to whichever canvas edge the slot sits on (invariant across LTR, RTL, Duo trailing & leading).
            x = slot.midX < barFrame.width / 2 ? minX : maxX
        } else {
            x = min(max(slot.midX - pillSize.width / 2, minX), maxX)
        }
        let y = (thickness - pillSize.height) / 2
        return CGRect(x: x, y: y, width: pillSize.width, height: pillSize.height)
    }

    private func placeMorphPillAtSelectedSlot() {
        let rest = restingPillFrame(anchorSelectedSlot)
        let s = barMajorScale
        let scaled = CGRect(x: rest.minX * s, y: rest.minY, width: rest.width * s, height: rest.height)
        pill.transform = .identity
        pill.bounds = CGRect(origin: .zero, size: scaled.size)
        pill.center = CGPoint(x: scaled.midX, y: scaled.midY)
        pill.layer.cornerRadius = min(scaled.width, scaled.height) / 2
    }

    /// Draws the resting tab row's glyphs at the native platter's exact live slot centers so the blur-out / blur-in
    /// snapshot aligns to 0.0 pt with Apple's native `UITabBar` across all 5 postures. When handing off from a lifted
    /// native drag lens (`handoffLens.lift > 0.05`), keeps non-overflow tabs unfilled (matching UIKit's active-drag
    /// appearance) and zooms the glyph under the lens so the takeover frame is pixel-continuous.
    private func tabRowImage(handoffLens: (frame: CGRect, lift: CGFloat)? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat(for: traitCollection)
        let overflowItem = overflow.first { $0.id == overflowID } ?? overflow.first
        let slotCount = primaryItems.count + (overflowItem == nil ? 0 : 1)
        let chevronCfg = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        let chevron = UIImage(systemName: "chevron.up", withConfiguration: chevronCfg)
        let chevronFirst = canvasAngle < 0
        let lensLift = handoffLens?.lift ?? 0
        return UIGraphicsImageRenderer(size: barFrame.size, format: format).image { ctx in
            let cg = ctx.cgContext
            for i in 0..<slotCount {
                let isOverflow = i == primaryItems.count
                // During a lifted-lens handoff, `More`'s zoomed glyph renders inside `handoffGlass.contentView` (above
                // its glass refraction layer) so `UIGlassEffect(.clear)` never smears the blue avatar onto the lens rim.
                if isOverflow, lensLift > 0.05 { continue }
                guard let item = isOverflow ? overflowItem : primaryItems[i] else { continue }
                let selected = lensLift > 0.05 ? false : (i == anchorSelectedSlot)
                let source = selected ? (item.selectedImage ?? item.image) : item.image
                guard let source else { continue }
                let rect = restingSlotFrame(i)
                var zoom: CGFloat = 1
                if let lens = handoffLens, lens.lift > 0.05 {
                    let half = lens.frame.width / 2
                    let reach = abs(rect.midX - lens.frame.midX)
                    if half > 0, reach < half {
                        let u = 1 - reach / half
                        zoom = 1 + (0.18 * lens.lift) * (u * u * (3 - 2 * u))
                    }
                }
                let color = (selected ? UIColor(CommaTheme.textPrimary) : Self.restingGlyph).resolvedColor(with: traitCollection)
                let isOriginal = source.renderingMode == .alwaysOriginal
                let drawSize: CGSize
                if isOriginal, source.size.width > 0, source.size.height > 0 {
                    drawSize = source.size
                } else if source.size.width > 0, source.size.height > 0 {
                    let maxSide = max(source.size.width, source.size.height)
                    let fit = maxSide > Metrics.glyph ? Metrics.glyph / maxSide : 1
                    drawSize = CGSize(width: source.size.width * fit, height: source.size.height * fit)
                } else {
                    drawSize = CGSize(width: Metrics.glyph, height: Metrics.glyph)
                }
                let tintedGlyph = isOriginal ? source : source.withTintColor(color, renderingMode: .alwaysOriginal)
                cg.saveGState()
                if zoom > 1.001 {
                    cg.translateBy(x: rect.midX, y: rect.midY)
                    cg.scaleBy(x: zoom, y: zoom)
                    cg.translateBy(x: -rect.midX, y: -rect.midY)
                }
                if isOverflow, let art = (selected ? moreTabArt?.selected : moreTabArt?.normal) ?? moreTabArt?.normal {
                    let drawn = art.renderingMode == .alwaysOriginal
                        ? art
                        : art.withTintColor(color, renderingMode: .alwaysOriginal)
                    cg.saveGState()
                    cg.translateBy(x: rect.midX, y: rect.midY)
                    cg.rotate(by: -canvasAngle)
                    drawn.draw(in: CGRect(x: -art.size.width / 2, y: -art.size.height / 2,
                                          width: art.size.width, height: art.size.height))
                    cg.restoreGState()
                } else if isOverflow, let chevron {
                    let chevSize = chevron.size
                    let gap: CGFloat = 3
                    let total = Metrics.glyph + gap + chevSize.width
                    let start = rect.midX - total / 2
                    let iconCenterX = chevronFirst
                        ? start + chevSize.width + gap + Metrics.glyph / 2
                        : start + Metrics.glyph / 2
                    let chevCenterX = chevronFirst
                        ? start + chevSize.width / 2
                        : start + Metrics.glyph + gap + chevSize.width / 2
                    cg.saveGState()
                    cg.translateBy(x: iconCenterX, y: rect.midY)
                    cg.rotate(by: -canvasAngle)
                    tintedGlyph.draw(in: CGRect(x: -drawSize.width / 2, y: -drawSize.height / 2,
                                                width: drawSize.width, height: drawSize.height))
                    cg.restoreGState()
                    chevron.withTintColor(color, renderingMode: .alwaysOriginal)
                        .draw(in: CGRect(x: chevCenterX - chevSize.width / 2, y: rect.midY - chevSize.height / 2,
                                         width: chevSize.width, height: chevSize.height))
                } else {
                    cg.saveGState()
                    cg.translateBy(x: rect.midX, y: rect.midY)
                    cg.rotate(by: -canvasAngle)
                    tintedGlyph.draw(in: CGRect(x: -drawSize.width / 2, y: -drawSize.height / 2,
                                                width: drawSize.width, height: drawSize.height))
                    cg.restoreGState()
                }
                cg.restoreGState()
            }
        }
    }

    /// Renders the 4th (`More`) slot's zoomed `glyph/avatar + chevron` for `handoffGlass.contentView` during a lifted
    /// drag handoff, using the exact same canvas-space orientation as `tabRowImage`.
    private func overflowGlyphImage(zoom: CGFloat) -> UIImage? {
        let color = Self.restingGlyph.resolvedColor(with: traitCollection)
        if let art = moreTabArt?.normal {
            let drawn = art.renderingMode == .alwaysOriginal
                ? art
                : art.withTintColor(color, renderingMode: .alwaysOriginal)
            let baseW = ceil(max(art.size.width, art.size.height) + 8)
            let size = CGSize(width: ceil(baseW * zoom), height: ceil(baseW * zoom))
            let format = UIGraphicsImageRendererFormat(for: traitCollection)
            return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                let cg = ctx.cgContext
                cg.translateBy(x: size.width / 2, y: size.height / 2)
                cg.scaleBy(x: zoom, y: zoom)
                cg.rotate(by: -canvasAngle)
                drawn.draw(in: CGRect(x: -art.size.width / 2, y: -art.size.height / 2,
                                      width: art.size.width, height: art.size.height))
            }
        }
        guard let item = overflow.first(where: { $0.id == overflowID }) ?? overflow.first,
              let source = item.image else { return nil }
        let chevronCfg = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        let chevron = UIImage(systemName: "chevron.up", withConfiguration: chevronCfg)
        let chevronFirst = canvasAngle < 0
        let isOriginal = source.renderingMode == .alwaysOriginal
        let drawSize: CGSize
        if isOriginal, source.size.width > 0, source.size.height > 0 {
            drawSize = source.size
        } else if source.size.width > 0, source.size.height > 0 {
            let maxSide = max(source.size.width, source.size.height)
            let fit = maxSide > Metrics.glyph ? Metrics.glyph / maxSide : 1
            drawSize = CGSize(width: source.size.width * fit, height: source.size.height * fit)
        } else {
            drawSize = CGSize(width: Metrics.glyph, height: Metrics.glyph)
        }
        let tintedGlyph = isOriginal ? source : source.withTintColor(color, renderingMode: .alwaysOriginal)
        let chevSize = chevron?.size ?? .zero
        let gap: CGFloat = chevron == nil ? 0 : 3
        let total = Metrics.glyph + gap + chevSize.width
        let baseW = ceil(max(total, drawSize.width) + 8)
        let baseH = ceil(max(Metrics.glyph, drawSize.height, chevSize.height) + 8)
        let size = CGSize(width: ceil(baseW * zoom), height: ceil(baseH * zoom))
        let format = UIGraphicsImageRendererFormat(for: traitCollection)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let cx = size.width / 2, cy = size.height / 2
            cg.translateBy(x: cx, y: cy)
            cg.scaleBy(x: zoom, y: zoom)
            let start = -total / 2
            let iconCenterX = chevronFirst
                ? start + chevSize.width + gap + Metrics.glyph / 2
                : start + Metrics.glyph / 2
            let chevCenterX = chevronFirst
                ? start + chevSize.width / 2
                : start + Metrics.glyph + gap + chevSize.width / 2
            cg.saveGState()
            cg.translateBy(x: iconCenterX, y: 0)
            cg.rotate(by: -canvasAngle)
            tintedGlyph.draw(in: CGRect(x: -drawSize.width / 2, y: -drawSize.height / 2,
                                        width: drawSize.width, height: drawSize.height))
            cg.restoreGState()
            if let chevron {
                chevron.withTintColor(color, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: chevCenterX - chevSize.width / 2, y: -chevSize.height / 2,
                                     width: chevSize.width, height: chevSize.height))
            }
        }
    }

    private func riseRows() {
        let count = menu.rows.count
        setMenuState {
            menu.closing = false
            menu.rise = Array(repeating: Metrics.rowRise, count: count)
            menu.shown = Array(repeating: 0, count: count)
        }
        for order in 0..<count {
            let index = count - 1 - order
            let delay = Metrics.rowDelay + Metrics.rowStagger * Double(order)
            withAnimation(Metrics.rowSpring.delay(delay)) { menu.rise[index] = 0 }
            withAnimation(Metrics.rowFade.delay(delay)) { menu.shown[index] = 1 }
        }
    }

    private func setMenuState(_ change: () -> Void) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still, change)
    }

    // MARK: Morph Spring & Display Link (Active ONLY while menu open/morphing)

    private var glassHeight: CGFloat = 62
    private var glassVelocity: CGFloat = 0
    private var glassTarget: CGFloat = 62
    private var springStiffness: CGFloat = 0
    private var springDamping: CGFloat = 0
    private var lastMorphStep: CFTimeInterval = 0
    private var glassSqueeze: CGFloat = 0
    private var glassSqueezeVelocity: CGFloat = 0
    private var squeezeStiffness: CGFloat = 0
    private var squeezeDamping: CGFloat = 0
    private var glassInset: CGFloat = 0

    private var morphProgress: CGFloat {
        let span = menuFrame.height - thickness
        return span > 0 ? min(max((glassHeight - thickness) / span, 0), 1) : 0
    }

    /// Launches the major-axis opening squeeze with an impulse-driven critically-damped spring (`ζ = 1`):
    /// peaks cleanly at `Metrics.morphSqueeze` (~80 ms) and eases back out to full width over ~0.50 s with zero
    /// overshoot into the adjacent router circle.
    private func startOpeningSqueeze() {
        let omega = 2 * .pi / CGFloat(Metrics.squeezeResponse)
        squeezeStiffness = omega * omega
        squeezeDamping = 2 * omega
        glassSqueezeVelocity = Metrics.morphSqueeze * omega * exp(1)
    }

    /// Launches a symmetric major-axis squeeze when closing via an impulse-driven critically-damped spring (`ζ = 1`):
    /// pinches inward cleanly at mid-collapse (~58 ms) and springs smoothly back out to full bar width (`0.0 px`
    /// landing) before `finishMorph()` hands back to native `UITabBar`.
    private func startClosingSqueeze() {
        let omega = 2 * .pi / CGFloat(Metrics.squeezeCloseResponse)
        squeezeStiffness = omega * omega
        squeezeDamping = 2 * omega
        let impulse = Metrics.closeSqueeze * omega * exp(1)
        let headroom = max(0, 1 - glassSqueeze / Metrics.closeSqueeze)
        glassSqueezeVelocity = max(glassSqueezeVelocity, impulse * headroom)
    }

    private func startMorph(to height: CGFloat, response: TimeInterval, damping ratio: CGFloat) {
        glassTarget = height
        springStiffness = pow(2 * .pi / CGFloat(response), 2)
        springDamping = 2 * ratio * sqrt(springStiffness)
        if !isMorphing { lastMorphStep = CACurrentMediaTime() }
        isMorphing = true
        track(for: 0.1)
    }

    private func track(for seconds: CFTimeInterval) {
        trackUntil = max(trackUntil, CACurrentMediaTime() + seconds)
        guard link == nil else { return }
        let link = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func tick(_ displayLink: CADisplayLink) {
        if isMorphing { stepMorph() }
        updateIndicator()
        if CACurrentMediaTime() > trackUntil, !isMorphing, !isOpen {
            link?.invalidate()
            link = nil
        }
    }

    private func stepMorph() {
        let now = CACurrentMediaTime()
        var remaining = min(max(now - lastMorphStep, 0), 0.05)
        lastMorphStep = now
        let step = 1.0 / 480
        while remaining > 0 {
            let dt = CGFloat(min(step, remaining))
            let force = -springStiffness * (glassHeight - glassTarget) - springDamping * glassVelocity
            glassVelocity += force * dt
            glassHeight += glassVelocity * dt
            if squeezeStiffness > 0 {
                let squeezeForce = -squeezeStiffness * glassSqueeze - squeezeDamping * glassSqueezeVelocity
                glassSqueezeVelocity += squeezeForce * dt
                glassSqueeze += glassSqueezeVelocity * dt
            }
            remaining -= Double(dt)
        }
        let heightSettled = abs(glassHeight - glassTarget) < 0.2 && abs(glassVelocity) < 2
        let squeezeSettled = abs(glassSqueeze) < 0.003 && abs(glassSqueezeVelocity) < 0.02
        if heightSettled {
            glassHeight = glassTarget
            glassVelocity = 0
        }
        if squeezeSettled {
            glassSqueeze = 0
            glassSqueezeVelocity = 0
        }
        let settled = heightSettled && squeezeSettled
        applyGlassHeight()
        if settled { finishMorph() }
    }

    private func applyGlassHeight() {
        let base = barFrame
        glassInset = base.width * max(glassSqueeze, 0) / 2
        bar.bounds = CGRect(x: 0, y: 0, width: base.width - glassInset * 2, height: glassHeight)
        bar.center = CGPoint(x: base.midX, y: base.maxY - glassHeight / 2)
        bar.contentView.layoutIfNeeded()
        layoutGlassContent()
        let progress = Double(morphProgress)
        if menu.progress != progress { setMenuState { menu.progress = progress } }
        let rowShown = CGFloat(MenuMorph.tabsOpacity(progress))
        if abs(tabsShown - rowShown) > 0.001 || (rowShown > 0.001 && glassInset > 0.05) {
            tabsShown = rowShown
            onTabsShownChange?(rowShown)
        }
        let pillTarget: CGFloat = anchorOverflowSelected ? 0 : (isOpen ? min(pill.alpha, rowShown) : rowShown)
        setPillAlpha(pillTarget)
    }

    private func finishMorph() {
        isMorphing = false
        if isOpen {
            tabContent.isHidden = true
            menuRows.isHidden = false
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setPillAlpha(0)
            setMenuIndicatorAlpha(0)
            handoffGlass.glass.alpha = 0
            handoffGlass.isHidden = true
            handoffGlyph.image = nil
            handoffGlyph.alpha = 0
            isHidden = true
            isUserInteractionEnabled = false
            CATransaction.commit()
            indicatorLeg = nil
            indicatorTarget = nil
            hoveredRow = nil
            openRow = nil
            lastPickedRow = nil
            tabsShown = 1
            onTabsShownChange?(1)
            onVisibilityChange?(false)
            onDismiss?()
        }
        setMenuState { menu.tabs = nil }
    }

    // MARK: Menu Indicator

    private struct Anchored {
        var rect: CGRect
        var fromBottom: Bool

        static func top(_ rect: CGRect) -> Anchored { Anchored(rect: rect, fromBottom: false) }
        static func bottom(_ rect: CGRect, height: CGFloat) -> Anchored {
            Anchored(rect: CGRect(x: rect.minX, y: height - rect.minY, width: rect.width, height: rect.height), fromBottom: true)
        }

        func resolve(_ height: CGFloat) -> CGRect {
            fromBottom ? CGRect(x: rect.minX, y: height - rect.minY, width: rect.width, height: rect.height) : rect
        }
    }

    private struct IndicatorLeg {
        var from: Anchored
        var fromProgress: CGFloat
        var to: Anchored?
        var toProgress: CGFloat
        var startAlpha: CGFloat
        var fromGlass = false
        var closing = false
        var intoSelection = false
    }

    private var indicatorLeg: IndicatorLeg?
    private var indicatorTarget: CGRect?
    private var indicatorShown: CGFloat = 0
    private var lastIndicatorStep: CFTimeInterval = 0
    private var openRow: Int?
    private var lastPickedRow: Int?

    private var indicatorFrame: CGRect {
        let s = barMajorScale
        let f = menuIndicator.frame
        return CGRect(x: f.minX / s, y: f.minY, width: f.width / s, height: f.height)
    }
    private var activeRow: Int? { overflow.firstIndex { $0.id == selectedID } }
    private var indicatorRow: Int? {
        guard isOpen else { return nil }
        if isTracking, fingerInRows { return hoveredRow }
        return hoveredRow ?? openRow ?? activeRow
    }

    private func startIndicator(tracking: Bool, handoffLens: (frame: CGRect, lift: CGFloat)?) {
        let height = bar.bounds.height
        let offset = CGPoint(x: 0, y: tabContent.frame.minY)
        let progress = morphProgress
        let lift = handoffLens?.lift ?? 0
        lastPickedRow = nil
        openRow = tracking && lift > 0.05 ? (activeRow ?? overflow.count - 1) : nil
        indicatorTarget = nil
        if menuIndicator.alpha > 0.01, indicatorLeg != nil {
            indicatorLeg = IndicatorLeg(from: .bottom(indicatorFrame, height: height), fromProgress: progress,
                                        to: nil, toProgress: 1, startAlpha: menuIndicator.alpha)
        } else if let lens = handoffLens, lens.lift > 0.05 {
            indicatorLeg = IndicatorLeg(from: .bottom(lens.frame.offsetBy(dx: offset.x, dy: offset.y), height: height),
                                        fromProgress: progress, to: nil, toProgress: 1, startAlpha: 1, fromGlass: true)
            setPillAlpha(0)
        } else if anchorOverflowSelected {
            let startRect = restingPillFrame(primaryItems.count).offsetBy(dx: offset.x, dy: offset.y)
            indicatorLeg = IndicatorLeg(from: .bottom(startRect, height: height),
                                        fromProgress: progress, to: nil, toProgress: 1, startAlpha: 1)
            setPillAlpha(0)
        } else {
            indicatorLeg = nil
        }
        indicatorShown = indicatorLeg == nil ? 0 : 1
        lastIndicatorStep = CACurrentMediaTime()
        updateIndicator()
    }

    private func endIndicator() {
        let progress = morphProgress
        guard progress > 0.01 else {
            setMenuIndicatorAlpha(0)
            handoffGlass.glass.alpha = 0
            handoffGlass.isHidden = true
            indicatorLeg = nil
            return
        }
        if anchorOverflowSelected {
            let fromRect: CGRect
            let startAlpha: CGFloat
            if menuIndicator.alpha > 0.05 {
                fromRect = indicatorFrame
                startAlpha = menuIndicator.alpha
            } else if let row = lastPickedRow ?? hoveredRow ?? activeRow {
                let anchored = Anchored.bottom(rowFrame(row), height: menuFrame.height)
                fromRect = anchored.resolve(bar.bounds.height)
                startAlpha = 0
            } else {
                fromRect = restingPillFrame(primaryItems.count).offsetBy(dx: 0, dy: bar.bounds.height - thickness)
                startAlpha = 0
            }
            let rest = restingPillFrame(primaryItems.count).offsetBy(dx: 0, dy: bar.bounds.height - thickness)
            indicatorLeg = IndicatorLeg(
                from: .bottom(fromRect, height: bar.bounds.height),
                fromProgress: progress,
                to: .bottom(rest, height: bar.bounds.height),
                toProgress: 0,
                startAlpha: startAlpha,
                closing: true,
                intoSelection: true
            )
            return
        }
        guard menuIndicator.alpha > 0.01 else {
            setMenuIndicatorAlpha(0)
            handoffGlass.glass.alpha = 0
            handoffGlass.isHidden = true
            indicatorLeg = nil
            return
        }
        let current = Anchored.top(indicatorFrame)
        indicatorLeg = IndicatorLeg(from: current, fromProgress: progress, to: current, toProgress: 0,
                                    startAlpha: menuIndicator.alpha, closing: true)
    }

    private func updateIndicator() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastIndicatorStep, 0), 0.05)
        lastIndicatorStep = now
        let height = bar.bounds.height
        let progress = morphProgress
        if let row = indicatorRow {
            let want = Anchored.bottom(rowFrame(row), height: menuFrame.height).rect
            let ease = 1 - exp(-dt / Metrics.indicatorFollow)
            indicatorTarget = indicatorTarget.map { lerp($0, want, ease) } ?? want
        }
        let target = indicatorTarget.map { Anchored(rect: $0, fromBottom: true).resolve(height) }
        guard isOpen || indicatorLeg?.closing == true else { return }

        var frame = indicatorFrame
        var alpha: CGFloat
        var grey: CGFloat = 1
        var glassAlpha: CGFloat = 0
        var nativeBlend: CGFloat = 0
        if let leg = indicatorLeg {
            let span = leg.toProgress - leg.fromProgress
            let t = span == 0 ? 1 : min(max((progress - leg.fromProgress) / span, 0), 1)
            let start = leg.from.resolve(height)
            let end = leg.to?.resolve(height) ?? target ?? start
            frame = lerp(start, end, t)
            if leg.closing {
                if leg.intoSelection {
                    // Always ease cleanly to full 1.0 alpha and crossfade into the native-matched pill fill before
                    // landing on the 4th slot so the handoff back to `UITabBar` has zero luminance or blur-halo jump.
                    alpha = leg.startAlpha + (1 - leg.startAlpha) * smoothstep(0, 0.45, t)
                    nativeBlend = smoothstep(0.35, 0.85, t)
                } else {
                    alpha = leg.startAlpha * min(1, (1 - t) * 1.5)
                }
            } else {
                indicatorShown += ((indicatorRow == nil ? 0 : 1) - indicatorShown) * (1 - exp(-dt / Metrics.indicatorFade))
                alpha = leg.startAlpha + (indicatorShown - leg.startAlpha) * t
                if leg.fromGlass {
                    grey = smoothstep(0, Metrics.lensToGrey, t)
                    glassAlpha = 1 - grey
                } else if anchorOverflowSelected {
                    nativeBlend = 1 - smoothstep(0, 0.45, t)
                }
            }
        } else {
            if let target { frame = target }
            indicatorShown += ((indicatorRow == nil ? 0 : 1) - indicatorShown) * (1 - exp(-dt / Metrics.indicatorFade))
            alpha = indicatorShown * CGFloat(MenuMorph.rowsOpacity(Double(progress)))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scaleX = barMajorScale
        let fitted = CGRect(x: frame.minX * scaleX, y: frame.minY, width: frame.width * scaleX, height: frame.height)
        menuIndicator.frame = fitted
        indicatorFill.layer.cornerRadius = min(fitted.width, fitted.height) / 2
        indicatorFill.alpha = grey
        let clampedNative = min(max(nativeBlend, 0), 1)
        if abs(indicatorNativeFill.alpha - clampedNative) > 0.001 { indicatorNativeFill.alpha = clampedNative }
        let frostAlpha = 1 - clampedNative
        if abs(indicatorFrost.alpha - frostAlpha) > 0.001 { indicatorFrost.alpha = frostAlpha }
        let clampedGlass = min(max(glassAlpha * alpha, 0), 1)
        if clampedGlass > 0.01 {
            let frameInCanvas = fitted.offsetBy(dx: barFrame.minX + glassInset, dy: barFrame.maxY - glassHeight)
            handoffGlass.frame = frameInCanvas
            let contentBounds = handoffGlass.contentView.bounds
            handoffGlyph.center = CGPoint(
                x: contentBounds.midX + handoffGlyphOffset.x * clampedGlass,
                y: contentBounds.midY + handoffGlyphOffset.y * clampedGlass
            )
            let glyphAlpha = tabsShown * clampedGlass
            if abs(handoffGlyph.alpha - glyphAlpha) > 0.001 { handoffGlyph.alpha = glyphAlpha }
            if abs(handoffGlass.glass.alpha - clampedGlass) > 0.001 { handoffGlass.glass.alpha = clampedGlass }
            if handoffGlass.isHidden { handoffGlass.isHidden = false }
        } else {
            if abs(handoffGlass.glass.alpha) > 0.001 { handoffGlass.glass.alpha = 0 }
            if abs(handoffGlyph.alpha) > 0.001 { handoffGlyph.alpha = 0 }
            if !handoffGlass.isHidden { handoffGlass.isHidden = true }
        }
        setMenuIndicatorAlpha(alpha)
        CATransaction.commit()
    }

    // MARK: Row Geometry & Tracking

    private func rowFrame(_ i: Int) -> CGRect {
        let size = menuFrame.size, pad = Metrics.menuPadding, row = Metrics.menuRow
        guard isVertical else {
            return CGRect(x: pad, y: pad + CGFloat(i) * row, width: size.width - pad * 2, height: row)
        }
        let along = mirrored ? size.width - pad - row * CGFloat(i + 1) : pad + row * CGFloat(i)
        return CGRect(x: along, y: pad, width: row, height: size.height - pad * 2)
    }

    private func row(at point: CGPoint) -> Int? {
        guard !overflow.isEmpty else { return nil }
        let frame = menuFrame
        guard frame.insetBy(dx: isVertical ? 0 : -24, dy: isVertical ? -24 : 0).contains(point) else { return nil }
        let along: CGFloat
        if isVertical {
            let x = point.x - frame.minX
            along = mirrored ? frame.width - Metrics.menuPadding - x : x - Metrics.menuPadding
        } else {
            along = point.y - frame.minY - Metrics.menuPadding
        }
        return min(max(Int(floor(along / Metrics.menuRow)), 0), overflow.count - 1)
    }

    private func trackMenu(_ point: CGPoint) {
        if let start = menuOpenPoint {
            let movedIntoMenu = start.y - point.y > Metrics.menuReach / 2
                || (isVertical && abs(point.x - start.x) > Metrics.menuRow / 2)
            guard movedIntoMenu else { return }
            menuOpenPoint = nil
            openRow = nil
        }
        let row = row(at: point)
        guard row != hoveredRow else { return }
        hoveredRow = row
        if row != nil {
            fingerInRows = true
            selection.selectionChanged()
        }
    }

    private func pickRow(_ index: Int) {
        guard index >= 0, index < overflow.count else { return }
        let item = overflow[index]
        lastPickedRow = index
        selectedID = item.id
        overflowID = item.id
        anchorSelectedSlot = primaryItems.count
        anchorOverflowSelected = true
        // Notify owner first so `moreTabArt` updates to the newly picked tab before `close()` snapshots `tabRowImage()`.
        onPick?(item.id)
        close()
    }

    // MARK: Styling Helpers

    private static let selectionFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.30) : UIColor(white: 0, alpha: 0.05)
    }

    /// Matches Apple's native iOS 26/27 resting `UITabBar` selection pill tint over `UIGlassEffect(.regular)`:
    /// light mode produces `RGB 234` over the `252` glass platter (`black @ 0.072`), and dark mode produces
    /// the native recessed dark well (`RGB 23` over `46` Drive / `30` over `58` Settings / `22` over `43` compact,
    /// `black @ 0.48`) with zero blur halo.
    private static let nativePillFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.48) : UIColor(white: 0, alpha: 0.072)
    }

    private static let restingGlyph = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.99) : UIColor(white: 0, alpha: 0.94)
    }

    private static func makeSelectionFrost() -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        view.isUserInteractionEnabled = false
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.contentView.backgroundColor = selectionFill
        return view
    }

    private func setPillAlpha(_ alpha: CGFloat) {
        let clamped = min(max(alpha, 0), 1)
        if abs(pill.alpha - clamped) > 0.001 { pill.alpha = clamped }
        let hidden = clamped <= 0.015
        if pill.isHidden != hidden { pill.isHidden = hidden }
    }

    private func setMenuIndicatorAlpha(_ alpha: CGFloat) {
        let clamped = min(max(alpha, 0), 1)
        if abs(menuIndicator.alpha - clamped) > 0.001 { menuIndicator.alpha = clamped }
        let hidden = clamped <= 0.001
        if menuIndicator.isHidden != hidden { menuIndicator.isHidden = hidden }
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    private func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Preserved Custom GlassTabBar (Cross-Platform Reference for Android)

/// Preserved custom Liquid Glass tab bar implementation (120 Hz fitted tap/drag spring & deformation curves,
/// Duo vertical widening `48pt <-> 72.5pt`, corner radius `24pt <-> 30.8pt`, pill crossfade, and overflow morph).
/// iOS 26/27 runtime uses native `UITabBarController` + `TabOverflowMenuView` above; this full custom
/// implementation is intentionally kept intact and type-checked as the behavioral reference for Android.
/// A tab bar that matches the iOS 27 system bar frame for frame, with an overflow slot the system bar cannot have:
/// the last slot shows the current overflow page's glyph and a chevron, and opens into a menu of the overflow pages.
///
/// What it takes from the system, measured against `UITabBarController` in the glass lab:
/// - The bar is interactive glass. A press grows it by 1.0486 and brightens it exactly as the system bar's platter.
/// - The lens is a `UISegmentedControl`'s, the same liquid lens the system bar lifts. The control is scaled so the
///   lens lifts to the system bar's 96×74 and its segment centres fall on the bar's slots; its own track and
///   glyphs are hidden.
/// What it draws itself, as the system bar does under its lens:
/// - The glyphs. Under the lens they are cut out and drawn again 1.15× larger (the system's destination-out view
///   and portal), the selected one filled.
/// - The selection pill, which rides the lens: it fades out over 0.25 s as the lens lifts and back in over 0.35 s as
///   it lands. Its colour is the closest public effect to the system's backdrop colour matrix.
///
/// The menu is the bar itself: its glass grows up into a panel of rows, and the glyphs blur out as the rows blur in.
/// Dragging onto the overflow slot opens it, and dragging on into it picks a row. Tapping the overflow slot opens it
/// and leaves it open until a row or the outside is tapped. The view fills its host; touches
/// pass through except where the glass is, or anywhere while the menu is open.
@available(iOS 26.0, *)
final class GlassTabBar: UIView, UIGestureRecognizerDelegate {
    struct Item: Equatable {
        let id: String
        let title: String
        let image: UIImage?
        var selectedImage: UIImage?
    }

    enum Metrics {
        static let height: CGFloat = 62
        static let margin: CGFloat = 21
        static let inset: CGFloat = 4
        static let itemWidth: CGFloat = 76
        static let accessoryGap: CGFloat = 8
        static let glyph: CGFloat = 24
        /// The system lens at rest and lifted, in the bar's own coordinates. On screen it lifts to 96.5×73.4, which
        /// includes the 1.0486 the pressed glass grows by.
        static let restLens = CGSize(width: 76, height: 54)
        static let liftedLens = CGSize(width: 92, height: 70)
        /// What the segmented control's lens adds to a segment when it lifts, and takes off it at rest, in the
        /// control's own coordinates.
        static let segmentLift = CGSize(width: 24, height: 16)
        static let segmentInset = CGSize(width: 4, height: 4)
        /// Glyphs under the lifted lens, on top of the bar's own growth.
        static let lensZoom: CGFloat = 1.15
        /// Half a glyph's width: the zoom fades in smoothly over this either side of the lens's edge.
        static let glyphHalf: CGFloat = 14
        /// Bounds on the segmented control's static uniform scale so its lifted lens reaches the system bar's exact
        /// size across compact (`0.85`), iPhone (`1.17`), Duo vertical side-bar (`1.50`), and Duo unfolded portrait (`1.70`).
        static let minLensScale: CGFloat = 0.85
        static let maxLensScale: CGFloat = 1.75
        /// How long the lens must have been still before the display link stops following it.
        static let lensSettle: TimeInterval = 0.35
        /// Critically-damped spring responses for the resting selection pill fading out as the liquid lens lifts and
        /// back in as it lands, fitted at 120 Hz against native iOS 27 `_UITabSelectionView` (RMSE 0.004 out, 0.003 in).
        static let pillFadeOut: TimeInterval = 0.25
        static let pillFadeIn: TimeInterval = 0.40
        /// Minimum lift before unmasking `UISegmentedControl`'s liquid lens, hiding its narrower resting capsule
        /// (`~63pt`) during takeoff and landing so only one unified capsule silhouette is ever drawn.
        static let lensRevealLift: CGFloat = 0.16
        static let menuRow: CGFloat = 48
        static let menuPadding: CGFloat = 8
        /// How far the outgoing and incoming contents blur while the bar turns into the menu and back.
        static let morphBlur: CGFloat = 12
        static let morphDuration: TimeInterval = 0.46
        static let morphBounce: CGFloat = 0.3
        /// How close the bar and the circle come before their glass runs together.
        static let merge: CGFloat = 8
        /// How much narrower the glass gets early in its growth before it stretches out to full width.
        static let morphSqueeze: CGFloat = 0.14
        /// Closing settles without a bounce and slower than opening, so the glass is seen folding back into the bar.
        static let closeDuration: TimeInterval = 0.3
        /// Each row rises from this far below, overshoots a little and settles, one after another from the bottom.
        static let rowRise: CGFloat = 14
        static let rowStagger: TimeInterval = 0.05
        static let rowDelay: TimeInterval = 0.08
        static let rowSpring = Animation.spring(duration: 0.5, bounce: 0.45)
        static let rowFade = Animation.easeOut(duration: 0.22)
        /// The menu indicator: how fast it follows the finger to a new row and fades in or out, and by how far into
        /// the glass's growth a lens it starts from has turned grey.
        static let indicatorFollow: TimeInterval = 0.05
        static let indicatorFade: TimeInterval = 0.08
        static let lensToGrey: CGFloat = 0.35
        /// How far the lens has come down when an opening menu clears it, so it fades rather than settling as a ring.
        static let lensDrop: CGFloat = 0.35
        /// How close to the last slot's middle a dragging finger comes before the menu opens.
        static let menuReach: CGFloat = 20
        /// How long a dragging finger rests on the last slot before the menu opens.
        static let menuDwell: TimeInterval = 0.3
        static let dwellSlop: CGFloat = 8

        /// The iPhone Duo's vertical bar, measured against the system's: 48pt across, 24pt from the screen's edge and
        /// its bottom, slots 58 along and 44 across, 50pt apart, 1.5pt in from the bar's ends, the circle 13pt below. Its lens lifts to
        /// about 78pt along the bar on screen; across, the segmented lens stays narrower than the system's 94pt, as it
        /// cannot be wider than long at the bar's spacing.
        static let sideThickness: CGFloat = 48
        static let sideMargin: CGFloat = 24
        static let sideGap: CGFloat = 13
        static let sideInsetAlong: CGFloat = 1.5
        static let sideStride: CGFloat = 50
        static let sideItem: CGFloat = 58
        static let sideInsetAcross: CGFloat = 2
        static let sideRestLens = CGSize(width: 58, height: 44)
        static let sideLiftedAlong: CGFloat = 80
        /// Pressed, the system's vertical bar grows across from 48 to 72.5pt and along from 211 to 216pt about its
        /// middle, and its lens lifts to ~61.5pt across initially and ~88pt across (100% uniform scale) a quarter
        /// second after the press.
        static let sidePressedThickness: CGFloat = 72.5
        static let sidePressedLengthening: CGFloat = 5
        /// Corner radius of the widened vertical bar (measured at 60 Hz against iOS 27 Native Duo: 30.76pt steady,
        /// 31.71pt overshoot peak, transitioning smoothly from 24pt at rest with the same spring curve).
        static let sidePressedCornerRadius: CGFloat = 30.8
        static let sidePreWidenAcross: CGFloat = 61.5
        static let sideLiftedAcross: CGFloat = 87.8
        static let sideWidenDelay: TimeInterval = 0.22
        /// The corner radius of the system's lifted side-bar lens in bar coordinates.
        static let sideLensCorner: CGFloat = 37
        /// How long the side bar takes to widen under a press, and to narrow again (fitted at 60 Hz against iOS 27
        /// Native Duo vertical `UITabBar`: widening RMSE 0.25pt with +16% overshoot, narrowing RMSE 0.33pt with -3%
        /// undershoot).
        static let sideWidening: TimeInterval = 0.40
        static let sideWideningBounce: CGFloat = 0.50
        static let sideNarrowing: TimeInterval = 0.37
        static let sideNarrowingBounce: CGFloat = 0.26
        /// The bottom bar's largest size, measured on the system's in the iPhone Duo held upright: 94pt slots 76pt
        /// apart. Where the screen leaves less room, as on an iPhone, the slots are 76pt and closer together. Smaller
        /// than the room, the bar and the circle stand together in the middle of the screen.
        static let maxItemWidth: CGFloat = 94
        static let maxStride: CGFloat = 76
        /// An iPhone held sideways: the system's bar is 44pt high with 66×36 slots 70pt apart, 38pt in from the
        /// leading edge and 20pt up, the circle 44pt at the trailing edge. Its lens lifts to about 82×52.
        static let compactHeight: CGFloat = 44
        static let compactItem: CGFloat = 66
        static let compactStride: CGFloat = 70
        static let compactSide: CGFloat = 38
        static let compactBottom: CGFloat = 20
        static let compactLifted = CGSize(width: 82, height: 52)
        /// How far the vertical bar grows into the menu, across the screen.
        static let sideMenuWidth: CGFloat = 224
    }

    // MARK: Model

    var items: [Item] = [] { didSet { rebuildSlots() } }
    var overflow: [Item] = [] { didSet { rebuildSlots(); rebuildMenu() } }
    private(set) var selectedID = ""
    /// The overflow page the last slot stands for.
    private(set) var overflowID = ""
    var accessoryImage: UIImage? { didSet { accessoryIcon.image = accessoryImage; setNeedsLayout() } }
    var accessoryLabel: String? { didSet { accessory.glass.accessibilityLabel = accessoryLabel } }
    var accessoryIdentifier: String? { didSet { accessory.glass.accessibilityIdentifier = accessoryIdentifier } }
    var accessoryHint: String? { didSet { accessory.glass.accessibilityHint = accessoryHint } }
    var accessoryValue: String? { didSet { accessory.glass.accessibilityValue = accessoryValue } }
    /// What VoiceOver says after an item's title, by item id, as "Unread" where the owner draws a dot. The menu's
    /// slot says what the pages in the menu say.
    var itemValues: [String: String] = [:] { didSet { if itemValues != oldValue { refreshSlots() } } }
    var onSelect: ((String) -> Void)?
    var onReselect: ((String) -> Void)?
    var onAccessory: (() -> Void)?
    /// Runs after each layout, and each frame the bar turns into the menu or back: the owner places what it draws
    /// over the bar.
    var onLayout: (() -> Void)?
    /// How much of the tab row shows, 1 at rest and 0 while the bar is the menu: what the owner draws on a tab's
    /// glyph shows as much.
    private(set) var tabsShown: CGFloat = 1

    /// The circle beside the bar, in this view's coordinates; nil while there is none.
    var accessoryRect: CGRect? {
        accessoryImage == nil ? nil : canvas.convert(accessoryFrame, to: self)
    }

    /// Where `id`'s glyph is drawn, in this view's coordinates: its slot, or the menu slot for a page in the menu.
    func glyphRect(for id: String) -> CGRect? {
        let index = items.firstIndex { $0.id == id } ?? (overflow.contains { $0.id == id } ? overflowSlot : nil)
        guard let index, index < slotCount else { return nil }
        return canvas.convert(slotFrame(index).offsetBy(dx: barFrame.minX, dy: barFrame.minY), to: self)
    }

    /// The room the bar takes from the pages under it, beyond `safeArea`: a bar along the bottom takes its height and
    /// the gap under it; the iPhone Duo's side bar stands in the status column, which is no page's.
    func contentInsets(beyond safeArea: UIEdgeInsets) -> UIEdgeInsets {
        guard !isVertical else { return .zero }
        return UIEdgeInsets(top: 0, left: 0, bottom: max(0, bounds.height - barFrame.minY - safeArea.bottom), right: 0)
    }

    // MARK: Orientation

    /// Along the bottom, or the iPhone Duo's vertical bar on one side of the screen. Vertical, everything is laid out as
    /// the horizontal bar in a canvas turned a quarter: the menu grows towards the content, the circle is below the
    /// bar, and glyphs and rows are turned back upright. On the trailing side the canvas is mirrored so Home stays on
    /// top.
    private enum Orientation: Equatable { case horizontal, vertical(trailing: Bool) }
    private var orientation: Orientation = .horizontal
    private var isVertical: Bool { orientation != .horizontal }
    /// Along the bottom of a screen with little height: an iPhone held sideways.
    private var isCompact = false
    private var mirrored: Bool { orientation == .vertical(trailing: true) }
    /// The canvas's turn on screen, which glyphs and rows undo.
    private var canvasAngle: CGFloat {
        switch orientation {
        case .horizontal: 0
        case .vertical(let trailing): trailing ? -.pi / 2 : .pi / 2
        }
    }
    private let canvas = UIView()
    /// 0 at rest, 1 while a press widens the vertical bar, eased frame by frame.
    private var widen: CGFloat = 0
    /// The widening the bar is laid out at. Outside a morph it goes to its end in one step and the layout it
    /// changes is animated once, so the system draws the frames between: laying the glass and the control out
    /// again on every frame of a press costs more than a frame has at 120 Hz.
    private var widenLaid: CGFloat = 0
    private var widenSince: CFTimeInterval?

    private var thickness: CGFloat {
        isVertical ? Metrics.sideThickness : isCompact ? Metrics.compactHeight : Metrics.height
    }
    private var edgeMargin: CGFloat { isVertical ? Metrics.sideMargin : Metrics.margin }
    private var accessoryGap: CGFloat { isVertical ? Metrics.sideGap : Metrics.accessoryGap }
    private var restLensSize: CGSize {
        if isCompact { return CGSize(width: Metrics.compactItem, height: Metrics.compactHeight - Metrics.inset * 2) }
        return isVertical ? Metrics.sideRestLens : CGSize(width: itemLength, height: Metrics.restLens.height)
    }
    /// The system's lifted lens: along the bar, and across it before a side bar widens.
    private var systemLiftedLens: CGSize {
        if isCompact { return Metrics.compactLifted }
        guard isVertical else {
            let grow = Metrics.liftedLens.width - Metrics.restLens.width
            return CGSize(width: itemLength + grow, height: Metrics.liftedLens.height)
        }
        return CGSize(width: Metrics.sideLiftedAlong, height: Metrics.sideLiftedAcross)
    }

    /// The control's static uniform scale. Its lens lifts by 24×16 in its own coordinates over an inset of 4×4, so
    /// scaling statically sets how much longer than a slot the lifted lens is while leaving Core Animation's Render
    /// Server free to drive liquid stretch and landing bounce at 120 Hz without per-frame sublayer transforms.
    private var lensScale: CGFloat {
        let grow = Metrics.segmentLift.width - Metrics.segmentInset.width
        let natural = (systemLiftedLens.width - slotStride) / max(grow, 1)
        return min(max(natural, Metrics.minLensScale), Metrics.maxLensScale)
    }

    /// The control's segment and lens dimensions in its own coordinates, sized statically so its segment centres fall
    /// on the bar's slots and its lifted height equals `systemLiftedLens.height` across every device and posture.
    private struct LensGeometry {
        var segment: CGSize
        var rest: CGSize
        var lifted: CGSize
    }

    private func lensGeometry() -> LensGeometry? {
        let n = slotCount, scale = lensScale
        guard n > 0, slotStride > 0, scale.isFinite, scale > 0.1 else { return nil }
        let lifted = systemLiftedLens
        let inset = Metrics.segmentInset, lift = Metrics.segmentLift
        let width = slotStride / scale
        // For the vertical side bar, segment bounds stay constant and sized for the widened lifted lens (`87.8pt` across
        // at uniform `scaleX == scaleY == scale`), so widened dragging has 100% circular bevels and zero mid-press
        // layout reset; before widening (`0..0.22s`), `segments.transform` scales Y down to `sidePreWidenAcross`.
        let height = max(inset.height + 8, lifted.height / scale - (lift.height - inset.height))
        let restLens = CGSize(width: width - inset.width, height: height - inset.height)
        let liftedLens = CGSize(width: restLens.width + lift.width, height: restLens.height + lift.height)
        return LensGeometry(segment: CGSize(width: width, height: height), rest: restLens, lifted: liftedLens)
    }

    private func resolveOrientation() -> Orientation {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            switch traitCollection.verticalBarEdge {
            case .leading: return .vertical(trailing: rtl)
            case .trailing: return .vertical(trailing: !rtl)
            default: break
            }
        }
        #endif
        return .horizontal
    }

    /// Turns the canvas for `orientation` and sets what depends on it.
    private func applyOrientation(_ next: Orientation) {
        let compact = next == .horizontal && traitCollection.verticalSizeClass == .compact
        let changed = next != orientation || compact != isCompact
        orientation = next
        isCompact = compact
        canvas.transform = .identity
        canvas.bounds = isVertical ? CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width) : bounds
        canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
        canvas.transform = CGAffineTransform(rotationAngle: canvasAngle)
        bar.angle = canvasAngle
        accessory.angle = canvasAngle
        guard changed else { return }
        if menuOpen { closeMenu() }
        let radius = thickness / 2
        bar.cornerConfiguration = .uniformCorners(radius: .fixed(radius))
        menuClip.layer.cornerRadius = radius
        // A turn lands the glass at the new bar at once: a spring still heading for the old thickness would leave
        // the bar at the old size.
        glassHeight = thickness
        glassTarget = thickness
        glassVelocity = 0
        if morphing {
            applyGlassHeight()
            finishMorph()
        }
        uprightGlyphs()
    }

    /// Glyphs stand upright on screen whichever way the canvas is turned; the chevron turns with the bar, pointing
    /// where the menu opens.
    private func uprightGlyphs() {
        let upright = CGAffineTransform(rotationAngle: -canvasAngle)
        for slot in slots {
            slot.icon.transform = upright
            // Trailing, the canvas runs bottom to top on screen, so before the glyph is below it.
            slot.chevronFirst = canvasAngle < 0
        }
        accessoryIcon.transform = upright
    }

    /// A point in this view, in the canvas's coordinates.
    private func canvasPoint(_ point: CGPoint) -> CGPoint { convert(point, to: canvas) }

    // MARK: Views

    /// The bar and the circle share one container, as the system's do: 8pt apart at rest they stand apart, and when
    /// the pressed bar grows up to the circle the two run together.
    private let container = UIVisualEffectView(effect: {
        let effect = UIGlassContainerEffect()
        effect.spacing = Metrics.merge
        return effect
    }())
    /// Regular interactive Liquid Glass for both the resting bar and the expanded overflow menu, keeping native edge
    /// refraction and frosted translucency over underlying content (including other glass controls) without a nested
    /// blur overlay or material swap.
    private let bar = UprightGlass(effect: GlassTabBar.glass(.regular))

    private static func glass(_ style: UIGlassEffect.Style) -> UIGlassEffect {
        let glass = UIGlassEffect(style: style)
        glass.isInteractive = true
        return glass
    }
    private let accessory = UprightGlass(effect: {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        return glass
    }())
    private let accessoryIcon = UIImageView()
    /// The tab row, kept on the bar's bottom edge while the bar grows into the menu.
    private let tabContent = UIView()
    /// VoiceOver's rows; the rows people see are drawn in SwiftUI (`menuRowsView`).
    private let menuRows = UIView()
    private var rowViews: [MenuRow] = []
    /// Inside the glass and clipped to it, so what it holds takes the pressed glass's growth: the rows on the top
    /// edge, and the tab row's picture on the bottom edge while it blurs away. The lens is not in it: lifted, it hangs
    /// past the glass.
    private let menuClip = UIView()
    /// The menu's selection: the row the finger is on, or else the page shown. It grows out of the lens or the bar's
    /// selection as the menu opens, and fades, or folds back into the bar's selection, as it closes.
    private let menuIndicator = UIView()
    private let indicatorFill = UIView()
    private let indicatorFrost = GlassTabBar.makeSelectionFrost()
    private let menu = MenuModel()
    private lazy var menuRowsView: UIView = Self.host(MenuRowsLayer(model: menu))
    private lazy var tabSnapshotView: UIView = Self.host(TabSnapshotLayer(model: menu))

    /// A SwiftUI layer that takes no safe area: the bar sits on the home indicator's inset, which would push what it
    /// draws up by half the overlap, so the picture would jump against the live glyphs it replaces.
    private static func host<Content: View>(_ content: Content) -> UIView {
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        return host.view
    }
    private let pill = UIView()
    private let pillFrost = GlassTabBar.makeSelectionFrost()
    /// Single continuous layer of glyphs below `segments`: `_UILiquidLensView` refracts them on the render server with
    /// zero per-frame mask lag, zero hard clip edge, and zero double-copy flicker when dragged slowly across icons.
    private let glyphs = UIView()
    private var lensReshaped = false
    private var slots: [SlotView] = []
    private var lastPillRect: CGRect = .null
    private var segments = GlassTabBar.makeSegments()
    /// Masks out the segmented control's smaller resting selection view once landed (`lift == 0`) while keeping the
    /// control itself visible and hit-testable, so `pill` draws the exact native slot-width resting capsule with zero
    /// concentric inner shadow or resting rim.
    private let segmentsRestingMask = CAShapeLayer()
    private var segmentScale: CGFloat = 1
    /// The control that was tracking when the menu opened. Its events are stale; a fresh control replaces it.
    private weak var staleSegments: UISegmentedControl?
    private weak var lens: UIView?
    private var link: CADisplayLink?
    /// 1 once the lens has landed, 0 while it is lifted.
    private var restBlend: CGFloat = 1
    private var stillFrames = 0
    private var lensMovedAt: CFTimeInterval = 0
    private var lastRawLens: CGRect?
    private var lastFollow: CFTimeInterval = 0
    private var lastLens: CGRect?
    private var trackUntil: CFTimeInterval = 0
    /// Critically-damped spring state for `pill`'s opacity (0.25 s fade-out on lift, 0.40 s fade-in on landing),
    /// plus previous presentation-layer sample for 1-frame velocity lookahead to eliminate Core Animation commit lag.
    private var pillAlpha: CGFloat = 1
    private var pillAlphaVel: CGFloat = 0
    private var pillLifting = false
    private var prevAlphaLift: CGFloat = 0
    private var prevAlphaTime: CFTimeInterval = 0
    private var prevLensLift: CGFloat = 0
    private var prevLensCenter: CGPoint?
    private var prevLensTime: CFTimeInterval = 0
    private var lastDisplayDt: CFTimeInterval = 1.0 / 60.0
    private let selection = UISelectionFeedbackGenerator()
    private let takeOver = TakeOverRecognizer()

    // MARK: State

    private var menuOpen = false
    /// The finger that opened the menu is still down and picks a row by where it is.
    private var menuTracking = false
    private var hoveredRow: Int?
    /// Where the finger was when the menu opened: rows answer only once it has moved off it.
    private var menuOpenPoint: CGPoint?
    private var pressSlot: Int?
    private let press = UILongPressGestureRecognizer()
    private var menuDwell: DispatchWorkItem?
    private var dwellPoint: CGPoint = .zero
    private var dwellAnchor: CGPoint = .zero
    private var pressStart: CGPoint = .zero
    private var pressBeganAt: CFTimeInterval = 0
    private var pressedAccessory = false
    private var moved = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // The canvas gives the layout its turned coordinates and holds nothing: the glass stands upright beside it.
        canvas.isUserInteractionEnabled = false
        addSubview(canvas)
        container.frame = bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(container)
        bar.canvas = canvas
        accessory.canvas = canvas

        // Explicit fixed corner radii so UIKit animates corner radius smoothly alongside bounds when the vertical side
        // bar widens (24pt <-> 30.8pt) instead of snapping `.capsule()` to the target bounds radius on frame 0.
        bar.cornerConfiguration = .uniformCorners(radius: .fixed(thickness / 2))
        bar.glass.accessibilityIdentifier = "glassTabBar.bar"
        accessory.cornerConfiguration = .capsule()
        container.contentView.addSubview(bar.glass)
        container.contentView.addSubview(accessory.glass)

        pill.accessibilityIdentifier = "glassTabBar.pill"
        pill.isUserInteractionEnabled = false
        pill.clipsToBounds = true
        pill.layer.cornerCurve = .continuous
        pillFrost.frame = pill.bounds
        pill.addSubview(pillFrost)
        glyphs.isUserInteractionEnabled = false
        segments.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
        for part in [pill, glyphs, segments] { tabContent.addSubview(part) }
        tabContent.autoresizingMask = [.flexibleTopMargin, .flexibleWidth]
        bar.contentView.addSubview(tabContent)

        accessoryIcon.tintColor = .label
        accessoryIcon.contentMode = .center
        accessoryIcon.isUserInteractionEnabled = false
        accessory.contentView.addSubview(accessoryIcon)
        accessory.glass.isAccessibilityElement = true
        accessory.glass.accessibilityTraits = .button

        // Always in the tree and drawn once ahead of time: at rest the rows are fully transparent and there is no
        // tab picture, so opening the menu starts no first render.
        menuClip.isUserInteractionEnabled = false
        menuClip.clipsToBounds = true
        menuClip.layer.cornerCurve = .continuous
        menuClip.layer.cornerRadius = Metrics.height / 2
        menuClip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        for layer in [menuRowsView, tabSnapshotView] {
            layer.backgroundColor = .clear
            layer.isUserInteractionEnabled = false
            menuClip.addSubview(layer)
        }
        menuRowsView.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        tabSnapshotView.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        bar.contentView.addSubview(menuClip)
        // Under the rows, and not clipped: the lifted lens it starts as hangs past the glass.
        menuIndicator.accessibilityIdentifier = "glassTabBar.menuIndicator"
        menuIndicator.isUserInteractionEnabled = false
        menuIndicator.alpha = 0
        menuIndicator.isHidden = true
        indicatorFill.clipsToBounds = true
        indicatorFill.layer.cornerCurve = .continuous
        indicatorFill.frame = menuIndicator.bounds
        indicatorFill.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        indicatorFrost.frame = indicatorFill.bounds
        indicatorFill.addSubview(indicatorFrost)
        menuIndicator.addSubview(indicatorFill)
        bar.contentView.insertSubview(menuIndicator, belowSubview: menuClip)
        menuRows.isHidden = true
        menuRows.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bar.contentView.addSubview(menuRows)

        press.addTarget(self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.cancelsTouchesInView = false
        press.delaysTouchesEnded = false
        press.delegate = self
        addGestureRecognizer(press)
        takeOver.delegate = self
        takeOver.onTouchDown = { [weak self] point in
            guard let self else { return }
            self.touchDown(at: self.canvasPoint(point))
        }
        addGestureRecognizer(takeOver)

        registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitLayoutDirection.self]) { (self: Self, _) in
            self.setNeedsLayout()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `id` as the selected page without telling the owner. An overflow page also becomes the last slot's.
    func select(_ id: String, animated: Bool) {
        selectedID = id
        if overflow.contains(where: { $0.id == id }) { overflowID = id }
        refreshSlots()
        let target = segmentIndex
        if segments.selectedSegmentIndex != target {
            if animated {
                pillLifting = true
                prevAlphaTime = CACurrentMediaTime()
                segments.selectedSegmentIndex = target
            } else {
                UIView.performWithoutAnimation { segments.selectedSegmentIndex = target }
                pillLifting = false
                pillAlpha = 1
                pillAlphaVel = 0
                prevLensCenter = nil
                setPillAlpha(1)
                if pressSlot == nil { setSegmentsLensVisible(false) }
            }
        }
        track(for: animated ? 0.9 : 0.15)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: Geometry

    private var slotCount: Int { items.count + (overflow.isEmpty ? 0 : 1) }
    private var overflowSlot: Int? { overflow.isEmpty ? nil : items.count }
    private var selectedSlot: Int {
        if let i = items.firstIndex(where: { $0.id == selectedID }) { return i }
        return overflowSlot ?? 0
    }

    /// The canvas's frame for one laid out from its leading end, mirrored when the canvas is.
    private func mirror(_ rect: CGRect, in width: CGFloat) -> CGRect {
        mirrored ? CGRect(x: width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect
    }

    private var barFrame: CGRect {
        let space = canvas.bounds
        let reserve = accessoryImage == nil ? 0 : thickness + accessoryGap
        if isCompact {
            let length = Metrics.inset * 2 + Metrics.compactStride * CGFloat(max(slotCount - 1, 0)) + Metrics.compactItem
            return CGRect(x: Metrics.compactSide, y: space.height - Metrics.compactBottom - thickness,
                          width: length, height: thickness)
        }
        let room = space.width - Metrics.margin * 2 - reserve
        let length = isVertical
            ? Metrics.sideItem + Metrics.sideStride * CGFloat(max(slotCount - 1, 0)) + Metrics.sideInsetAlong * 2
            : min(room, maxBarLength)
        // Vertical, the bar ends a gap short of the circle at the far end; horizontal, the bar and the circle stand
        // together in the middle of the room.
        let x = isVertical ? space.width - edgeMargin - reserve - length : Metrics.margin + (room - length) / 2
        let frame = CGRect(x: x, y: space.height - edgeMargin - thickness, width: max(0, length), height: thickness)
        return mirror(frame, in: space.width)
    }

    private var accessoryFrame: CGRect {
        let space = canvas.bounds
        if isCompact {
            return CGRect(x: space.width - Metrics.compactSide - thickness, y: barFrame.minY, width: thickness, height: thickness)
        }
        let unmirrored = mirror(barFrame, in: space.width)
        let frame = CGRect(x: unmirrored.maxX + accessoryGap, y: unmirrored.minY, width: thickness, height: thickness)
        return mirror(frame, in: space.width)
    }

    private var inner: CGRect {
        CGRect(origin: .zero, size: barFrame.size)
            .insetBy(dx: isVertical ? Metrics.sideInsetAlong : Metrics.inset,
                     dy: isVertical ? Metrics.sideInsetAcross : Metrics.inset)
    }

    /// The bottom bar at its largest: every slot at its widest and spacing.
    private var maxBarLength: CGFloat {
        Metrics.inset * 2 + Metrics.maxStride * CGFloat(max(slotCount - 1, 0)) + Metrics.maxItemWidth
    }

    /// Slots widen from the iPhone's 76pt to 94pt over the last 40pt before the bar reaches its largest.
    private var itemLength: CGFloat {
        guard !isVertical else { return Metrics.sideItem }
        if isCompact { return Metrics.compactItem }
        let t = min(max((barFrame.width - (maxBarLength - 40)) / 40, 0), 1)
        return Metrics.itemWidth + (Metrics.maxItemWidth - Metrics.itemWidth) * t
    }

    /// The spacing of slot centres. Slots overlap, as the system's do: 76pt slots 68.67pt apart in a 290pt bar.
    private var slotStride: CGFloat {
        let n = max(slotCount, 1)
        return n > 1 ? (inner.width - min(itemLength, inner.width)) / CGFloat(n - 1) : 0
    }

    /// A slot in the bar's own coordinates. Mirrored, the first slot is at the bar's far end.
    private func slotFrame(_ i: Int) -> CGRect {
        let width = min(itemLength, inner.width)
        let frame = CGRect(x: inner.minX + slotStride * CGFloat(i), y: inner.minY, width: width, height: inner.height)
        return mirror(frame, in: barFrame.width)
    }

    /// Whether a finger at `barX` is on the menu slot or past it, beyond the bar's end.
    private func isOnMenuSlot(barX: CGFloat) -> Bool {
        guard let menuSlot = overflowSlot else { return false }
        let mid = slotFrame(menuSlot).midX
        return mirrored ? barX <= mid + slotStride / 2 : barX >= mid - slotStride / 2
    }

    private func slot(atBarX x: CGFloat) -> Int {
        (0..<slotCount).min { abs(slotFrame($0).midX - x) < abs(slotFrame($1).midX - x) } ?? 0
    }

    /// The bar grown into the menu: as long as the bar, on the bar's bottom edge, a row per overflow page. Vertical,
    /// it grows across the screen towards the content and its rows run along the bar.
    private var menuFrame: CGRect {
        let bar = barFrame
        let height = isVertical ? Metrics.sideMenuWidth
            : max(bar.height, CGFloat(overflow.count) * Metrics.menuRow + Metrics.menuPadding * 2)
        return CGRect(x: bar.minX, y: bar.maxY - height, width: bar.width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyOrientation(resolveOrientation())
        if !morphing { glassHeight = menuOpen ? menuFrame.height : thickness; glassInset = 0 }
        bar.bounds = CGRect(x: 0, y: 0, width: barFrame.width - glassInset * 2 + widenLengthening,
                            height: glassHeight + widenExtra)
        bar.center = CGPoint(x: barFrame.midX, y: barFrame.maxY - glassHeight / 2)
        tabContent.frame = CGRect(x: -glassInset + widenLengthening / 2, y: glassHeight - thickness + widenExtra / 2,
                                  width: barFrame.width, height: thickness)
        accessory.isHidden = accessoryImage == nil
        onLayout?()
        // Its container covers only the circle, so it never takes a touch meant for the bar.
        accessory.frame = accessoryFrame
        accessoryIcon.frame = accessory.contentView.bounds
        let local = CGRect(origin: .zero, size: barFrame.size)
        if glyphs.frame != local {
            glyphs.frame = local
            lastPillRect = .null
        }
        // Sideways on an iPhone the system draws each glyph 3pt after its slot's middle, where it sits beside a title.
        let nudge: CGFloat = isCompact ? 3 : 0
        // Bounds and centre, not frame: slots scale about their centres while the lens passes over them.
        for i in 0..<slotCount {
            guard i < slots.count else { continue }
            slots[i].bounds = CGRect(origin: .zero, size: slotFrame(i).size)
            slots[i].center = CGPoint(x: slotFrame(i).midX + nudge, y: slotFrame(i).midY)
        }
        layoutSegments()
        layoutMenuRows()
        followLens()
        // A rotation animates the bar into place: follow it until it settles.
        track(for: 0.6)
    }

    /// Scales the segmented control statically so its lens lifts to the system's size and its segment centres sit on
    /// the slots without per-frame sublayer transforms.
    private func layoutSegments() {
        let n = slotCount
        guard n > 0, slotStride > 0 else { return }
        let scale = lensScale
        // In a passing layout the slots can be as far apart as the lens is long: no control size gives that lens.
        guard scale.isFinite, scale > 0.1 else { return }
        guard let geometry = lensGeometry() else { return }
        // Mirrored with the canvas, so its first segment is at the first slot; set on every control, as a fresh one
        // replaces it each time the menu closes.
        segments.semanticContentAttribute = mirrored ? .forceRightToLeft : .forceLeftToRight
        let bounds = CGRect(x: 0, y: 0, width: geometry.segment.width * CGFloat(n), height: geometry.segment.height)
        let center = CGPoint(x: (slotFrame(0).midX + slotFrame(n - 1).midX) / 2, y: tabContent.bounds.midY)
        // The lifted lens reaches past the control's ends at the first and last slots.
        if segments.clipsToBounds { segments.clipsToBounds = false }
        let moved = segments.bounds != bounds || segments.center != center || segmentScale != scale
        segmentScale = scale
        let preWidenRatio = Metrics.sidePreWidenAcross / max(Metrics.sideLiftedAcross, 1)
        let widenRatio: CGFloat = isVertical ? (preWidenRatio + (1 - preWidenRatio) * widenLaid) : 1
        let scaled = CGAffineTransform(scaleX: scale, y: scale * widenRatio)
        if segments.transform != scaled { segments.transform = scaled }
        if segments.bounds != bounds { segments.bounds = bounds }
        if segments.center != center { segments.center = center }
        if moved || pressSlot == nil { segments.layoutIfNeeded() }
        // The control places its lens when its selection changes, not when it is resized: after a rotation or a new
        // size it would stay where it was. Reselect at rest so it moves to the new place.
        if moved, pressSlot == nil, !menuOpen, widen == 0 {
            let index = segments.selectedSegmentIndex
            UIView.performWithoutAnimation {
                segments.selectedSegmentIndex = UISegmentedControl.noSegment
                segments.selectedSegmentIndex = index
                segments.layoutIfNeeded()
            }
            setSegmentsLensVisible(false)
            lens = nil
            lastLens = nil
            lastRawLens = nil
            lastPillRect = .null
        }
        hideSegmentTrack()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        setNeedsLayout()
        hideSegmentTrack()
        track(for: 0.25)
    }

    /// Hides `UISegmentedControl`'s own grey track `UIImageView`s (which UIKit can lazily create or unhide when the
    /// control first enters a window), leaving only its liquid lens active.
    private func hideSegmentTrack() {
        for view in segments.subviews where view is UIImageView && !view.isHidden {
            view.isHidden = true
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden else { return nil }
        if menuOpen { return self }
        let local = canvasPoint(point)
        if barFrame.contains(local) {
            // The menu slot is a button: the control never sees a touch that starts there, so it lifts no lens.
            if let menuSlot = overflowSlot, slot(atBarX: local.x - barFrame.minX) == menuSlot { return self }
            return super.hitTest(point, with: event) ?? self
        }
        if !accessory.isHidden && accessoryFrame.contains(local) { return super.hitTest(point, with: event) ?? self }
        return nil
    }

    // MARK: Building

    private func rebuildSlots() {
        slots.forEach { $0.removeFromSuperview() }
        slots = (0..<slotCount).map { i in
            let slot = SlotView(chevron: i == overflowSlot)
            slot.onActivate = { [weak self] in self?.activate(slot: i) }
            glyphs.addSubview(slot)
            return slot
        }
        lastPillRect = .null
        uprightGlyphs()
        if overflowID.isEmpty || !overflow.contains(where: { $0.id == overflowID }) { overflowID = overflow.first?.id ?? "" }
        if selectedID.isEmpty { selectedID = items.first?.id ?? "" }
        rebuildSegments()
        refreshSlots()
        setNeedsLayout()
    }

    /// One blank segment per slot, the menu slot's included and enabled: the control lends its lens, the bar draws
    /// the glyphs. A dragged lens reaches the menu slot and stays there past the bar's end; a disabled segment would
    /// make the control drop the finger. A touch that starts on the menu slot never reaches the control (`hitTest`).
    private func rebuildSegments() {
        segments.removeAllSegments()
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
            .withRenderingMode(.alwaysOriginal)
        for i in 0..<slotCount { segments.insertSegment(with: blank, at: i, animated: false) }
        segments.selectedSegmentIndex = segmentIndex
        lens = nil
    }

    /// The control's selection for the page shown: the menu slot while it is a menu page.
    private var segmentIndex: Int {
        selectedSlot < slotCount ? selectedSlot : UISegmentedControl.noSegment
    }

    private var overflowSelected: Bool { overflow.contains { $0.id == selectedID } }

    private func item(forSlot i: Int) -> Item? {
        if i < items.count { return items[i] }
        return overflow.first { $0.id == overflowID }
    }

    private func refreshSlots() {
        for i in 0..<slotCount {
            guard let item = item(forSlot: i), i < slots.count else { continue }
            let selected = i == selectedSlot
            // Match `UITab` / `_UITabBarItemPlatterView`: only the committed selected tab uses `selectedImage`,
            // drawn in one continuous unmasked layer beneath `_UILiquidLensView` so slow drags across icons never
            // split icons or flicker at the rim.
            let shownSource = selected ? (item.selectedImage ?? item.image) : item.image
            let glyph = shownSource?.renderingMode == .alwaysOriginal ? shownSource : shownSource?.withRenderingMode(.alwaysTemplate)

            let slot = slots[i]
            slot.icon.image = glyph
            slot.icon.tintColor = selected ? .label : Self.restingGlyph
            slot.chevron?.tintColor = selected ? .label : Self.restingGlyph
            slot.accessibilityIdentifier = i == overflowSlot ? "tab-more" : item.id
            slot.accessibilityLabel = i == overflowSlot ? String(localized: "More, \(item.title)") : item.title
            slot.accessibilityTraits = selected ? [.button, .selected] : .button
            slot.accessibilityValue = i == overflowSlot
                ? overflow.compactMap { itemValues[$0.id] }.first : itemValues[item.id]
        }
        rowViews.enumerated().forEach { index, row in
            row.accessibilityTraits = overflow[index].id == selectedID ? [.button, .selected] : .button
            row.accessibilityValue = itemValues[overflow[index].id]
        }
        let rows = overflow.map { item in
            MenuModel.Row(id: item.id, title: item.title,
                          icon: (item.id == selectedID ? item.selectedImage ?? item.image : item.image))
        }
        if menu.rows != rows { menu.rows = rows }
    }

    private func rebuildMenu() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = overflow.enumerated().map { index, item in
            let row = MenuRow(title: item.title)
            row.accessibilityIdentifier = item.id
            row.onActivate = { [weak self] in self?.pickRow(index) }
            menuRows.addSubview(row)
            return row
        }
        refreshSlots()
        setNeedsLayout()
    }

    private func layoutMenuRows() {
        let size = menuFrame.size
        let height = bar.bounds.height
        menuRows.frame = CGRect(x: -glassInset, y: height - size.height, width: size.width, height: size.height)
        for (i, row) in rowViews.enumerated() { row.frame = rowFrame(i) }
        menuClip.frame = bar.contentView.bounds
        // The rows stand upright on screen: vertical, their layer is turned back and its sides swapped.
        let rowsFrame = CGRect(x: -glassInset, y: 0, width: size.width, height: size.height)
        let upright = CGAffineTransform(rotationAngle: -canvasAngle)
        if menuRowsView.transform != upright { menuRowsView.transform = upright }
        menuRowsView.bounds = CGRect(origin: .zero, size: isVertical ? CGSize(width: size.height, height: size.width) : size)
        menuRowsView.center = CGPoint(x: rowsFrame.midX, y: rowsFrame.midY)
        tabSnapshotView.frame = CGRect(x: -glassInset, y: height - thickness, width: size.width, height: thickness)
    }

    /// Frosted selection capsule backing shared by both the resting tab pill and the open overflow menu indicator,
    /// matching `_UITabSelectionView`'s backdrop blur + colour matrix so underlying content is diffused instead of
    /// bleeding sharply through.
    private static func makeSelectionFrost() -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        view.isUserInteractionEnabled = false
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.contentView.backgroundColor = selectionFill
        return view
    }

    private func setPillAlpha(_ alpha: CGFloat) {
        let clamped = min(max(alpha, 0), 1)
        if abs(pill.alpha - clamped) > 0.001 { pill.alpha = clamped }
        let hidden = clamped <= 0.015
        if pill.isHidden != hidden { pill.isHidden = hidden }
    }

    private func setMenuIndicatorAlpha(_ alpha: CGFloat) {
        let clamped = min(max(alpha, 0), 1)
        if abs(menuIndicator.alpha - clamped) > 0.001 { menuIndicator.alpha = clamped }
        let hidden = clamped <= 0.001
        if menuIndicator.isHidden != hidden { menuIndicator.isHidden = hidden }
    }

    /// Unselected glyphs: 94 % in light, 99 % in dark, as the system bar draws them.
    private static let restingGlyph = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.99) : UIColor(white: 0, alpha: 0.94)
    }

    // MARK: Following the lens

    /// The system lens's view inside the segmented control. Only its position is read; if a later system draws the
    /// control differently, the pill and glyphs fall back to the selected slot.
    private func findLens() -> UIView? {
        if let lens, lens.isDescendant(of: segments) { return lens }
        let controlMajor = max(segments.bounds.width, segments.bounds.height)
        func search(_ view: UIView) -> UIView? {
            if view !== segments, !view.isHidden, view.alpha > 0.01, !view.subviews.isEmpty {
                let major = max(view.bounds.width, view.bounds.height)
                if major > 20, major < controlMajor - 10 { return view }
            }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        lens = search(segments)
        return lens
    }

    /// Follows the lens frame by frame while it may move.
    private func track(for seconds: CFTimeInterval) {
        trackUntil = max(trackUntil, CACurrentMediaTime() + seconds)
        guard link == nil else { return }
        let link = CADisplayLink(target: GlassTabBarLinkTarget(self), selector: #selector(GlassTabBarLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func tick(_ displayLink: CADisplayLink) {
        lastDisplayDt = min(max(displayLink.targetTimestamp - displayLink.timestamp, 1.0 / 120.0), 1.0 / 30.0)
        // A press whose touch went away unreported, as when the screen it was on is switched off by folding, would
        // keep the lens lifted and the side bar wide: end it.
        if pressSlot != nil, press.state != .began, press.state != .changed {
            if menuOpen && menuTracking { closeMenu() }
            endPress()
        }
        stepWiden()
        if morphing { stepMorph() }
        followLens()
        updateIndicator()
        let alphaSettled = !pillLifting && abs(pillAlpha - 1) < 0.008 && abs(pillAlphaVel) < 0.02
        if CACurrentMediaTime() > trackUntil, CACurrentMediaTime() - lensMovedAt > Metrics.lensSettle, pressSlot == nil,
           restBlend == 1, alphaSettled, !morphing, !menuOpen, widen == 0 {
            link?.invalidate()
            link = nil
            lastLens = nil
            lastRawLens = nil
            prevLensCenter = nil
            prevAlphaTime = 0
        }
    }

    /// The active selection/lens capsule in the tab row's coordinates, and how far the liquid lens has lifted (0..1).
    /// Matches native iOS 27 `UITabBar`'s unified capsule formula: base size lerps linearly from `restLensSize` to
    /// `systemLiftedLens` with `lift`, then scales by `_UILiquidLensView`'s elastic stretch/squish (`own.a`, `own.d`).
    /// When `lookahead > 0`, projects center and lift 1 frame forward to eliminate Core Animation's 1-frame commit lag.
    private func lensFrame(record: Bool = false, lookahead: CFTimeInterval = 0) -> (frame: CGRect, lift: CGFloat) {
        let size = restLensSize, slot = slotFrame(selectedSlot)
        let fallback = (CGRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2, width: size.width, height: size.height),
                        CGFloat(0))
        // With no segment selected (a menu page is shown) the control has no lens in play: the selection is the slot's.
        guard segments.selectedSegmentIndex != UISegmentedControl.noSegment || pressSlot != nil,
              let lens = findLens(), lensGeometry() != nil else { return fallback }
        let layer = lens.layer.presentation() ?? lens.layer
        let control = segments.layer.presentation() ?? segments.layer
        var raw = layer.bounds
        var node: CALayer = layer
        while node !== segments.layer, node.model() !== segments.layer {
            guard let parent = node.superlayer else { return fallback }
            let anchor = CGPoint(x: node.bounds.minX + node.bounds.width * node.anchorPoint.x,
                                 y: node.bounds.minY + node.bounds.height * node.anchorPoint.y)
            raw = raw.offsetBy(dx: -anchor.x, dy: -anchor.y).applying(node.affineTransform())
                .offsetBy(dx: node.position.x, dy: node.position.y)
            node = parent
        }
        guard raw.width > 1, raw.minX.isFinite, raw.minY.isFinite, raw.width.isFinite, raw.height.isFinite
        else { return fallback }
        let now = CACurrentMediaTime()
        if record {
            if let last = lastRawLens, abs(last.width - raw.width) + abs(last.height - raw.height)
                + abs(last.minX - raw.minX) + abs(last.minY - raw.minY) > 0.005 { lensMovedAt = now }
            lastRawLens = raw
        }
        let ctrlTransform = control.affineTransform()
        let scaleX = max(hypot(ctrlTransform.a, ctrlTransform.b), 0.1)
        let scaleY = max(hypot(ctrlTransform.c, ctrlTransform.d), 0.1)
        let actual = CGRect(
            x: control.position.x + (raw.minX - control.bounds.midX) * scaleX,
            y: control.position.y + (raw.minY - control.bounds.midY) * scaleY,
            width: raw.width * scaleX,
            height: raw.height * scaleY
        )
        let segRestH = control.bounds.height - Metrics.segmentInset.height
        let lift = min(max((layer.bounds.height - segRestH - 0.25) / max(Metrics.segmentLift.height - 0.25, 1), 0), 1)
        let own = layer.affineTransform()

        // Project 1 frame forward along presentation-layer velocity so `pill` (committed for the next vsync) stays
        // locked to `_UILiquidLensView` (evaluated on the render server) with zero trailing ghost at peak flight speed.
        var predX = actual.midX
        var predY = actual.midY
        var effLift = lift
        if record {
            let dtPrev = prevLensTime > 0 ? now - prevLensTime : 0
            if lookahead > 0, let prev = prevLensCenter, dtPrev >= 0.004, dtPrev <= 0.04 {
                let vx = (actual.midX - prev.x) / dtPrev
                let vy = (actual.midY - prev.y) / dtPrev
                let vlift = (lift - prevLensLift) / dtPrev
                if hypot(vx, vy) > 5 {
                    predX += vx * lookahead
                    predY += vy * lookahead
                }
                if abs(vlift) > 0.05 {
                    effLift = min(max(lift + vlift * lookahead, 0), 1)
                }
            }
            prevLensCenter = CGPoint(x: actual.midX, y: actual.midY)
            prevLensLift = lift
            prevLensTime = now
        }

        let targetIndex = segments.selectedSegmentIndex >= 0 ? min(segments.selectedSegmentIndex, max(slotCount - 1, 0)) : selectedSlot
        let targetSlot = slotFrame(targetIndex)
        let idealCenterX = targetSlot.midX + own.tx * scaleX
        let idealCenterY = targetSlot.midY + own.ty * scaleY
        let snapT = (pressSlot == nil && effLift < 0.08) ? (1 - smoothstep(1.5, 5.0, abs(predX - idealCenterX))) : 0
        let cx = predX + (idealCenterX - predX) * snapT
        let cy = predY + (idealCenterY - predY) * snapT

        var liftedSize = systemLiftedLens
        if isVertical {
            liftedSize.height = Metrics.sidePreWidenAcross + (Metrics.sideLiftedAcross - Metrics.sidePreWidenAcross) * widenLaid
        }
        let baseW = size.width + (liftedSize.width - size.width) * effLift
        let baseH = size.height + (liftedSize.height - size.height) * effLift
        let w = baseW * max(abs(own.a), 0.5)
        let h = baseH * max(abs(own.d), 0.5)
        return (CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), lift)
    }

    private func selectionFrame(lookahead: CFTimeInterval = 0) -> (frame: CGRect, lift: CGFloat) {
        let (lensRect, lift) = lensFrame(record: true, lookahead: lookahead)
        let drawn = lastLens ?? lensRect
        lastLens = lensRect
        lastFollow = CACurrentMediaTime()
        let still = pressSlot == nil && abs(drawn.width - lensRect.width) < 0.005
            && abs(drawn.height - lensRect.height) < 0.005 && abs(drawn.midX - lensRect.midX) < 0.005
        stillFrames = still ? stillFrames + 1 : 0
        restBlend = lift > 0 && stillFrames < 12 ? 0 : 1
        return (lensRect, lift)
    }

    private func setSegmentsLensVisible(_ visible: Bool) {
        if visible {
            if segments.layer.mask != nil { segments.layer.mask = nil }
        } else if segments.layer.mask !== segmentsRestingMask {
            segments.layer.mask = segmentsRestingMask
        }
    }

    private func followLens() {
        let (frame, lift) = selectionFrame(lookahead: link != nil ? lastDisplayDt : 0)
        if menuOpen, segments === staleSegments, lift < Metrics.lensDrop,
           segments.selectedSegmentIndex != UISegmentedControl.noSegment {
            segments.selectedSegmentIndex = UISegmentedControl.noSegment
        }
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return }
        if isVertical {
            if !lensReshaped, let lens = findLens() {
                // Keep `.capsule(maximumRadius:)` across both press and release: at rest the lens's half-height is
                // already below the cap so it settles as a true capsule with zero abrupt corner jump on release.
                let corners = UICornerConfiguration.capsule(maximumRadius: Double(Metrics.sideLensCorner / max(segmentScale, 0.1)))
                if lens.cornerConfiguration != corners { lens.cornerConfiguration = corners }
                lensReshaped = true
            }
        } else if lensReshaped, let lens = findLens() {
            lens.cornerConfiguration = .capsule()
            lensReshaped = false
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hideSegmentTrack()
        if !menuOpen, !morphing {
            let now = CACurrentMediaTime()
            let dt = prevAlphaTime > 0 ? min(max(now - prevAlphaTime, 0.001), 0.05) : 0
            prevAlphaTime = now
            let lensActive = segments.selectedSegmentIndex != UISegmentedControl.noSegment || pressSlot != nil
            if !lensActive {
                pillLifting = false
            } else if pressSlot != nil || lift > prevAlphaLift + 0.003 || lift > 0.94 {
                pillLifting = true
            } else if lift < prevAlphaLift - 0.003 || lift < 0.02 {
                pillLifting = false
            }
            prevAlphaLift = lift
            let target: CGFloat = pillLifting ? 0 : 1
            if dt > 0 {
                let response = pillLifting ? Metrics.pillFadeOut : Metrics.pillFadeIn
                let w = (2 * .pi) / response
                let e = exp(-w * dt)
                let x0 = pillAlpha - target
                let c2 = pillAlphaVel + w * x0
                pillAlpha = min(max(target + (x0 + c2 * dt) * e, 0), 1)
                pillAlphaVel = (pillAlphaVel - w * c2 * dt) * e
                if abs(pillAlpha - target) < 0.008 && abs(pillAlphaVel) < 0.02 {
                    pillAlpha = target
                    pillAlphaVel = 0
                }
            }
            setPillAlpha(pillAlpha)
            let showLens = lift >= Metrics.lensRevealLift
            setSegmentsLensVisible(showLens)
        } else {
            setSegmentsLensVisible(segments === staleSegments && lift >= Metrics.lensRevealLift)
        }
        // Keep `pill.bounds` constant at `restLensSize` and deform via `center` + `transform` (matching how native
        // `_UITabSelectionView` scales on the render server) so `pillFrost`'s `CABackdropLayer` never reallocates
        // surfaces per frame during 120 Hz tap flights.
        let restSize = restLensSize
        let restBounds = CGRect(origin: .zero, size: restSize)
        if pill.bounds != restBounds {
            pill.bounds = restBounds
            pill.layer.cornerRadius = min(restSize.width, restSize.height) / 2
            pillFrost.frame = restBounds
            lastPillRect = .null
        }
        let pillChanged = lastPillRect.isNull
            || abs(frame.minX - lastPillRect.minX) > 0.015
            || abs(frame.minY - lastPillRect.minY) > 0.015
            || abs(frame.width - lastPillRect.width) > 0.015
            || abs(frame.height - lastPillRect.height) > 0.015
        if pillChanged, restSize.width > 1, restSize.height > 1 {
            pill.center = CGPoint(x: frame.midX, y: frame.midY)
            let sx = frame.width / restSize.width
            let sy = frame.height / restSize.height
            let transform = (abs(sx - 1) < 0.0005 && abs(sy - 1) < 0.0005)
                ? CGAffineTransform.identity
                : CGAffineTransform(scaleX: sx, y: sy)
            if pill.transform != transform { pill.transform = transform }
            lastPillRect = frame
        }
        // One continuous copy of each glyph, below the lens: `_UILiquidLensView` bends it on the render server with
        // zero per-frame mask lag, while `lensZoom` scales each glyph smoothly in place around its own slot centre.
        for slot in slots {
            let zoom = lensZoom(at: slot.center, lens: frame, lift: lift)
            let transform = zoom == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: zoom, y: zoom)
            if slot.transform != transform { slot.transform = transform }
        }
        CATransaction.commit()
    }

    // MARK: Press

    @objc private func handlePress(_ press: UILongPressGestureRecognizer) {
        let point = press.location(in: canvas)
        let barX = point.x - barFrame.minX
        // Let go, the side bar narrows at once, and before the control lands its lens: it works out where the lens
        // lands from its size then, and does not place it again when it is resized.
        if press.state != .began, press.state != .changed { narrowSideBar() }
        switch press.state {
        case .began:
            pressStart = point
            pressBeganAt = CACurrentMediaTime()
            moved = false
            pressedAccessory = !accessory.isHidden && accessoryFrame.contains(point)
            if pressedAccessory { return }
            if menuOpen {
                menuTracking = true
                fingerInRows = false
                trackMenu(point)
                return
            }
            guard barFrame.contains(point) else { return }
            pressSlot = slot(atBarX: barX)
            selection.prepare()
            track(for: 1)
            // A press on the menu slot opens the menu at once, and the same finger can slide up to pick a row.
            if pressSlot == overflowSlot {
                openMenu(tracking: true, at: point)
                return
            }
            pillLifting = true
            if prevAlphaTime == 0 { prevAlphaTime = CACurrentMediaTime() }
        case .changed:
            if hypot(point.x - pressStart.x, point.y - pressStart.y) > 6 { moved = true }
            if pressedAccessory { return }
            if menuOpen { trackMenu(point); return }
            guard let start = pressSlot else { return }
            // Resting on the last slot a moment opens the menu, and the same finger goes on to pick a row. Until then
            // the lens can be dragged back. The lens fades with the tab row; the control is replaced once the menu
            // closes.
            // The lens stays on the menu slot however far past it the finger goes; so does the dwell.
            let onMenuSlot = overflowSlot.map { start != $0 && point.y > barFrame.minY - 20
                && isOnMenuSlot(barX: barX) } ?? false
            if onMenuSlot { armMenuDwell(at: point) } else { cancelMenuDwell() }
        case .ended:
            if pressedAccessory {
                if accessoryFrame.insetBy(dx: -8, dy: -8).contains(point) { onAccessory?() }
                return
            }
            if menuOpen && menuTracking { releaseMenu(at: point); endPress(); return }
            if menuOpen { releaseMenu(at: point); return }
            if let start = pressSlot, start == overflowSlot, slot(atBarX: barX) == start, barFrame.contains(point) {
                endPress()
                openMenu(tracking: false)
                return
            }
            // A lens let go on the menu slot opens the menu, as a tap there does.
            if let start = pressSlot, let menuSlot = overflowSlot, start != menuSlot, point.y > barFrame.minY - 20,
               isOnMenuSlot(barX: barX) {
                endPress()
                openMenu(tracking: false)
                return
            }
            if let start = pressSlot, !moved, start == selectedSlot, let item = item(forSlot: start) {
                // Native `UITabBar` pulses the grey selection capsule on a quick reselect tap without ballooning a
                // clear liquid lens after finger-up; longer holds (>= 0.18s) still lift and land the full lens.
                if CACurrentMediaTime() - pressBeganAt < 0.18 {
                    UIView.performWithoutAnimation {
                        segments.selectedSegmentIndex = UISegmentedControl.noSegment
                        segments.selectedSegmentIndex = start
                        segments.layoutIfNeeded()
                    }
                    pillLifting = false
                    setSegmentsLensVisible(false)
                }
                onReselect?(item.id)
            }
            endPress()
        default:
            if menuOpen && menuTracking { closeMenu() }
            endPress()
        }
    }

    /// The control lifts its lens only for a press on its selected segment; the system bar lifts it for a press on any
    /// tab and carries it under the finger. So the segment under a landing finger becomes the control's selection
    /// before the control sees the touch: it lifts there, from where it was. The bar's own selection follows only when
    /// the press ends (`settleSelection`).
    private func touchDown(at point: CGPoint) {
        guard !menuOpen, barFrame.contains(point), segments.superview != nil else { return }
        let under = slot(atBarX: point.x - barFrame.minX)
        guard under < segments.numberOfSegments, under != overflowSlot else { return }
        pillLifting = true
        prevAlphaTime = CACurrentMediaTime()
        track(for: 1)
        guard under != segments.selectedSegmentIndex else { return }
        segments.selectedSegmentIndex = under
    }

    private func commitSegmentSelection() {
        guard !menuOpen, segments !== staleSegments else { return }
        let index = segments.selectedSegmentIndex
        guard index >= 0, index != selectedSlot, index != overflowSlot || overflowSelected,
              let item = item(forSlot: index), item.id != selectedID else { return }
        selectedID = item.id
        refreshSlots()
        selection.selectionChanged()
        onSelect?(item.id)
    }

    /// Takes the control's selection as the bar's once the press is over: a press that landed off the selected tab
    /// changed the control without a value-changed event.
    private func settleSelection() {
        DispatchQueue.main.async { [self] in commitSegmentSelection() }
    }

    /// Opens the menu once the finger has held still on the last slot for `menuDwell`. Moving more than
    /// `dwellSlop` starts the wait again; leaving the slot cancels it.
    private func armMenuDwell(at point: CGPoint) {
        if menuDwell != nil, hypot(point.x - dwellAnchor.x, point.y - dwellAnchor.y) <= Metrics.dwellSlop {
            dwellPoint = point
            return
        }
        cancelMenuDwell()
        dwellAnchor = point
        dwellPoint = point
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pressSlot != nil, !self.menuOpen else { return }
            self.menuDwell = nil
            self.openMenu(tracking: true, at: self.dwellPoint)
        }
        menuDwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.menuDwell, execute: work)
    }

    private func cancelMenuDwell() {
        menuDwell?.cancel()
        menuDwell = nil
    }

    private func endPress() {
        cancelMenuDwell()
        pressSlot = nil
        commitSegmentSelection()
        settleSelection()
        track(for: 0.9)
    }

    /// Takes the finger from the control: UIKit cancels its touches, and it lands its lens with the system's motion.
    private func cancelSegmentTracking() {
        // The lens is drawn into the bar's glass, so hiding its view does not take it away. Let go, it lands on the
        // segment under it, shrinking in place as the menu's grey comes in inside it; `followLens` then clears it on
        // its way down so it fades. This control is replaced as the menu closes, so its selection is not the bar's.
        let (frame, _) = lensFrame()
        let here = min(slot(atBarX: frame.midX), max(segments.numberOfSegments - 1, 0))
        let control = segments
        takeOver.take()
        DispatchQueue.main.async {
            guard control.numberOfSegments > here else { return }
            control.selectedSegmentIndex = here
        }
        track(for: Metrics.morphDuration + 0.2)
    }

    /// A fresh control at rest on the selected slot: the one that was tracking when the menu opened may still hold
    /// its lens lifted.
    private func restoreSegments() {
        segments.removeFromSuperview()
        segments = Self.makeSegments()
        segments.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
        tabContent.insertSubview(segments, aboveSubview: glyphs)
        lensReshaped = false
        rebuildSegments()
        // Only the control: laying out the whole bar here would set the glass to its closed frame unanimated.
        layoutSegments()
        setSegmentsLensVisible(false)
        track(for: 0.3)
    }

    /// Tint applied over the frosted selection blur (`UIBlurEffect.systemUltraThinMaterial`), calibrated pixel-for-pixel
    /// against `_UITabSelectionView`'s backdrop blur + colour matrix in dark (`rgba(0,0,0,0.30)` -> RGB ~50 vs native
    /// 49.6) and light (`rgba(0,0,0,0.05)` -> RGB ~226 vs native 227).
    private static let selectionFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.30) : UIColor(white: 0, alpha: 0.05)
    }

    private static func makeSegments() -> UISegmentedControl {
        let control = UISegmentedControl()
        control.selectedSegmentTintColor = .clear
        control.clipsToBounds = false
        control.accessibilityElementsHidden = true
        return control
    }

    @objc private func segmentChanged(_ sender: UISegmentedControl) {
        guard sender === segments, sender !== staleSegments, !menuOpen else { return }
        if pressSlot != nil {
            // While dragging with the finger still down, emit haptic ticks on slot crossings without switching the
            // committed tab or underlying page until release (`endPress`), matching `UITabBar` and keeping dragged
            // dwell-to-overflow gestures on the starting page if cancelled.
            selection.selectionChanged()
            return
        }
        commitSegmentSelection()
    }

    // MARK: Menu

    /// The bar grows up into the menu, its glyphs blurring out as the rows blur in. One spring drives the glass's
    /// height frame by frame, and everything else is read off that height: what the glass shows always matches its
    /// size, and a close during the opening turns the same spring round from where it is, at the speed it has.
    private func openMenu(tracking: Bool, at point: CGPoint? = nil) {
        guard !menuOpen, overflowSlot != nil else { return }
        menuOpen = true
        menuTracking = tracking
        fingerInRows = false
        menuOpenPoint = tracking ? point : nil
        hoveredRow = nil
        bar.cornerConfiguration = .uniformCorners(radius: .fixed(thickness / 2))
        startIndicator(tracking: tracking)
        staleSegments = segments
        if !morphing {
            // The tab row as it is this frame, the lens's zoom included, stands in for the live glyphs.
            setMenuState { menu.tabs = tabRowImage() }
            glyphs.isHidden = true
        }
        selection.selectionChanged()
        // Glass does not draw under a fading parent, so the row is not faded. The control lets go of the finger and
        // its lens lands as the system's does; landed it is clear, and the row hides.
        cancelSegmentTracking()
        startMorph(to: menuFrame.height, response: Metrics.morphDuration, damping: 1 - Metrics.morphBounce)
        riseRows()
    }

    /// Drops every row a little and lets each spring back up in turn, from the row nearest the bar to the top.
    private func riseRows() {
        let count = menu.rows.count
        setMenuState {
            menu.closing = false
            menu.rise = Array(repeating: Metrics.rowRise, count: count)
            menu.shown = Array(repeating: 0, count: count)
        }
        for order in 0..<count {
            let index = count - 1 - order
            let delay = Metrics.rowDelay + Metrics.rowStagger * Double(order)
            withAnimation(Metrics.rowSpring.delay(delay)) { menu.rise[index] = 0 }
            withAnimation(Metrics.rowFade.delay(delay)) { menu.shown[index] = 1 }
        }
    }

    private func closeMenu() {
        guard menuOpen else { return }
        menuOpen = false
        menuTracking = false
        menuOpenPoint = nil
        menuRows.isHidden = true
        setMenuState { menu.closing = true }
        endIndicator()
        restoreSegments()
        if !morphing {
            setMenuState { menu.tabs = tabRowImage() }
        }
        tabContent.isHidden = false
        startMorph(to: thickness, response: Metrics.closeDuration, damping: 1)
    }

    private func setMenuState(_ change: () -> Void) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still, change)
    }

    // MARK: Morph spring

    /// The glass's height: the bar's 62 at rest, the menu's when open.
    private var glassHeight: CGFloat = Metrics.height
    private var glassVelocity: CGFloat = 0
    private var glassTarget: CGFloat = Metrics.height
    private var springStiffness: CGFloat = 0
    private var springDamping: CGFloat = 0
    private var lastMorphStep: CFTimeInterval = 0
    private var morphing = false

    private func startMorph(to height: CGFloat, response: TimeInterval, damping ratio: CGFloat) {
        glassTarget = height
        springStiffness = pow(2 * .pi / CGFloat(response), 2)
        springDamping = 2 * ratio * sqrt(springStiffness)
        if !morphing { lastMorphStep = CACurrentMediaTime() }
        morphing = true
        track(for: 0.1)
    }

    /// Steps the spring to now and lays the glass and what it shows out at the new height.
    private func stepMorph() {
        let now = CACurrentMediaTime()
        var remaining = min(max(now - lastMorphStep, 0), 0.05)
        lastMorphStep = now
        let step = 1.0 / 480
        while remaining > 0 {
            let dt = CGFloat(min(step, remaining))
            let force = -springStiffness * (glassHeight - glassTarget) - springDamping * glassVelocity
            glassVelocity += force * dt
            glassHeight += glassVelocity * dt
            remaining -= Double(dt)
        }
        let settled = abs(glassHeight - glassTarget) < 0.2 && abs(glassVelocity) < 2
        if settled {
            glassHeight = glassTarget
            glassVelocity = 0
        }
        applyGlassHeight()
        if settled { finishMorph() }
    }

    /// How much narrower than the bar the glass is on each side, while it draws in.
    private var glassInset: CGFloat = 0

    /// What the glass holds keeps the bar's full width, centred, so the glass narrows round it rather than pushing it.
    private func layoutGlassContent() {
        let width = barFrame.width, extra = widenExtra
        let height = bar.bounds.height - extra
        tabContent.frame = CGRect(x: -glassInset + widenLengthening / 2, y: height - thickness + extra / 2,
                                  width: width, height: thickness)
        layoutMenuRows()
    }

    /// How far the glass has grown from the bar to the menu, 0 to 1.
    private var morphProgress: CGFloat {
        let span = menuFrame.height - thickness
        return span > 0 ? min(max((glassHeight - thickness) / span, 0), 1) : 0
    }

    /// The vertical bar widens once a press starts dragging or holds past `sideWidenDelay`, about its middle, and
    /// narrows as it lets go, matching the iOS 27 Duo system spring curves.
    private func stepWiden() {
        let pressing = isVertical && pressSlot != nil && pressSlot != overflowSlot && !menuOpen
        let now = CACurrentMediaTime()
        if pressing { if widenSince == nil { widenSince = now } } else { widenSince = nil }
        let target: CGFloat = pressing && (moved || now - (widenSince ?? now) >= Metrics.sideWidenDelay) ? 1 : 0
        let dt = min(max(now - lastFollow, 1.0 / 120), 0.05)
        let next = widen + (target - widen) * (1 - exp(-dt / 0.04))
        let value = abs(target - next) < 0.003 ? target : next
        if value != widen { widen = value }
        if morphing {
            // The morph lays the glass out on every frame as it is; the widening goes with it.
            widenLaid = widen
            layoutSegments()
            return
        }
        guard widenLaid != target else { return }
        widenLaid = target
        let duration = target > 0 ? Metrics.sideWidening : Metrics.sideNarrowing
        let bounce = target > 0 ? Metrics.sideWideningBounce : Metrics.sideNarrowingBounce
        track(for: duration + 0.15)
        UIView.animate(springDuration: duration, bounce: bounce, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.applyGlassHeight()
            self.layoutSegments()
        }
    }

    private func narrowSideBar() {
        widenSince = nil
        guard isVertical, widenLaid != 0, !morphing else { return }
        widenLaid = 0
        track(for: Metrics.sideNarrowing + 0.15)
        UIView.animate(springDuration: Metrics.sideNarrowing, bounce: Metrics.sideNarrowingBounce, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.applyGlassHeight()
            self.layoutSegments()
        }
    }

    /// How much longer than at rest the vertical bar is, half at each end.
    private var widenLengthening: CGFloat { isVertical ? Metrics.sidePressedLengthening * widenLaid : 0 }

    /// How much wider than at rest the vertical bar is.
    private var widenExtra: CGFloat { isVertical ? (Metrics.sidePressedThickness - Metrics.sideThickness) * widenLaid : 0 }

    private func applyGlassHeight() {
        let base = barFrame
        // Early in its growth the glass draws in a little, then stretches out to full width: read off the growth, so
        // a close during the opening runs the same shape back.
        let squeeze = Metrics.morphSqueeze * sin(.pi * min(max(morphProgress / 0.7, 0), 1))
        glassInset = base.width * squeeze / 2
        // Bounds and centre, not frame: the pressed glass carries a transform of its own.
        let extra = widenExtra
        bar.bounds = CGRect(x: 0, y: 0, width: base.width - glassInset * 2 + widenLengthening, height: glassHeight + extra)
        bar.center = CGPoint(x: base.midX, y: base.maxY - glassHeight / 2)
        let barCorner: CGFloat = isVertical && !menuOpen && !morphing
            ? thickness / 2 + (Metrics.sidePressedCornerRadius - thickness / 2) * widenLaid
            : thickness / 2
        let targetCorner = UICornerConfiguration.uniformCorners(radius: .fixed(barCorner))
        if bar.cornerConfiguration != targetCorner {
            bar.cornerConfiguration = targetCorner
            bar.glass.layoutIfNeeded()
        }
        bar.contentView.layoutIfNeeded()
        layoutGlassContent()
        let progress = Double(morphProgress)
        if menu.progress != progress { setMenuState { menu.progress = progress } }
        // The selection belongs to the tab row: it shows as the row does, and opening never brings it back.
        let rowShown = CGFloat(MenuMorph.tabsOpacity(progress))
        // Only while the glass turns into the menu or back: a pressed side bar widening also comes through here, and
        // must not bring the selection back under the lifted lens.
        tabsShown = rowShown
        onLayout?()
        guard morphing else { return }
        let target = menuOpen ? min(pill.alpha, rowShown) : rowShown
        pillAlpha = target
        pillAlphaVel = 0
        setPillAlpha(target)
    }

    private func finishMorph() {
        morphing = false
        if menuOpen {
            tabContent.isHidden = true
            menuRows.isHidden = false
        } else {
            bar.cornerConfiguration = .uniformCorners(radius: .fixed(thickness / 2))
            glyphs.isHidden = false
            pillLifting = false
            pillAlpha = 1
            pillAlphaVel = 0
            prevLensCenter = nil
            setPillAlpha(1)
            setMenuIndicatorAlpha(0)
            indicatorLeg = nil
            indicatorTarget = nil
            hoveredRow = nil
            openRow = nil
        }
        setMenuState { menu.tabs = nil }
    }

    // MARK: Menu indicator

    /// A rect in the glass's coordinates, kept either from its top edge, as the rows are, or from its bottom edge,
    /// which does not move on screen while the glass grows.
    private struct Anchored {
        var rect: CGRect
        var fromBottom: Bool

        static func top(_ rect: CGRect) -> Anchored { Anchored(rect: rect, fromBottom: false) }
        static func bottom(_ rect: CGRect, height: CGFloat) -> Anchored {
            Anchored(rect: CGRect(x: rect.minX, y: height - rect.minY, width: rect.width, height: rect.height), fromBottom: true)
        }

        func resolve(_ height: CGFloat) -> CGRect {
            fromBottom ? CGRect(x: rect.minX, y: height - rect.minY, width: rect.width, height: rect.height) : rect
        }
    }

    /// The indicator travels from `from` to `to` (the row it points at, when nil) as the glass's growth goes from
    /// `fromProgress` to `toProgress`: tied to the glass, it starts where it is and turns round with it.
    private struct IndicatorLeg {
        var from: Anchored
        var fromProgress: CGFloat
        var to: Anchored?
        var toProgress: CGFloat
        var startAlpha: CGFloat
        /// It began as the lens: clear glass turning grey.
        var fromGlass = false
        var closing = false
        /// Closing into the bar's selection, which fades in where it ends.
        var intoSelection = false
    }

    private var indicatorLeg: IndicatorLeg?
    /// The row the indicator points at, kept from the glass's bottom edge, eased toward a new row as the finger moves.
    private var indicatorTarget: CGRect?
    private var indicatorShown: CGFloat = 0
    private var lastIndicatorStep: CFTimeInterval = 0
    /// The row under a finger that opened the menu and has not moved into it yet.
    private var openRow: Int?

    /// The indicator in the bar's full width, which it is laid out in before the glass's inset is taken off.
    private var indicatorFrame: CGRect { menuIndicator.frame.offsetBy(dx: glassInset, dy: 0) }

    private var activeRow: Int? { overflow.firstIndex { $0.id == selectedID } }
    /// A finger has picked through the rows during this press: off the menu it points at nothing, so the indicator
    /// fades where it is rather than going back to the page shown, as letting go there picks nothing.
    private var fingerInRows = false
    private var indicatorRow: Int? {
        guard menuOpen else { return nil }
        if menuTracking, fingerInRows { return hoveredRow }
        return hoveredRow ?? openRow ?? activeRow
    }

    /// Where the indicator starts as the menu opens: the lifted lens, the bar's selection on the menu slot, or what
    /// it showed when a close is turned round.
    private func startIndicator(tracking: Bool) {
        let height = bar.bounds.height
        // In the bar's full width, as the indicator is laid out; the glass may be drawn in.
        let offset = CGPoint(x: 0, y: tabContent.frame.minY)
        let (lens, lift) = lensFrame()
        let progress = morphProgress
        // A finger that dragged the lens to the menu slot points at the row nearest it until it moves.
        openRow = tracking && lift > 0.05 ? activeRow ?? overflow.count - 1 : nil
        indicatorTarget = nil
        if menuIndicator.alpha > 0.01, indicatorLeg != nil {
            indicatorLeg = IndicatorLeg(from: .bottom(indicatorFrame, height: height), fromProgress: progress,
                                        to: nil, toProgress: 1, startAlpha: menuIndicator.alpha)
        } else if lift > 0.05 {
            // The lens lands where it is, as the system's does, and the grey comes in inside it on its way to the row.
            indicatorLeg = IndicatorLeg(from: .bottom(lens.offsetBy(dx: offset.x, dy: offset.y), height: height),
                                        fromProgress: progress, to: nil, toProgress: 1, startAlpha: 1, fromGlass: true)
        } else if selectedSlot == overflowSlot, overflowSelected, pill.alpha > 0.05 {
            indicatorLeg = IndicatorLeg(from: .bottom(pill.frame.offsetBy(dx: offset.x, dy: offset.y), height: height),
                                        fromProgress: progress, to: nil, toProgress: 1, startAlpha: 1)
            // The indicator is the bar's selection from here on: two frosted layers over each other would darken.
            pillAlpha = 0
            pillAlphaVel = 0
            setPillAlpha(0)
        } else {
            indicatorLeg = nil
        }
        indicatorShown = indicatorLeg == nil ? 0 : 1
        lastIndicatorStep = CACurrentMediaTime()
        updateIndicator()
    }

    /// As the menu closes the indicator stays on its row and fades with it, or folds back into the bar's selection
    /// when the page shown is in the menu.
    private func endIndicator() {
        let progress = morphProgress
        guard menuIndicator.alpha > 0.01, progress > 0.01 else {
            setMenuIndicatorAlpha(0)
            indicatorLeg = nil
            return
        }
        let current = Anchored.top(indicatorFrame)
        var leg = IndicatorLeg(from: current, fromProgress: progress, to: current, toProgress: 0,
                               startAlpha: menuIndicator.alpha, closing: true)
        if overflowSelected, let slot = overflowSlot {
            leg.from = .bottom(indicatorFrame, height: bar.bounds.height)
            let rest = slotFrame(slot).offsetBy(dx: 0, dy: bar.bounds.height - thickness)
            leg.to = .bottom(rest, height: bar.bounds.height)
            leg.intoSelection = true
        }
        indicatorLeg = leg
    }

    private func updateIndicator() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastIndicatorStep, 0), 0.05)
        lastIndicatorStep = now
        let height = bar.bounds.height
        let progress = morphProgress
        if let row = indicatorRow {
            // Where the row stands once the menu is open, kept from the bottom edge: while the glass grows the rows
            // ride its top edge from below the bar, and the indicator heads straight for their resting place.
            let want = Anchored.bottom(rowFrame(row), height: menuFrame.height).rect
            let ease = 1 - exp(-dt / Metrics.indicatorFollow)
            indicatorTarget = indicatorTarget.map { lerp($0, want, ease) } ?? want
        }
        let target = indicatorTarget.map { Anchored(rect: $0, fromBottom: true).resolve(height) }
        guard menuOpen || indicatorLeg?.closing == true else { return }

        var frame = indicatorFrame
        var alpha: CGFloat
        var grey: CGFloat = 1
        if let leg = indicatorLeg {
            let span = leg.toProgress - leg.fromProgress
            let t = span == 0 ? 1 : min(max((progress - leg.fromProgress) / span, 0), 1)
            let start = leg.from.resolve(height)
            let end = leg.to?.resolve(height) ?? target ?? start
            frame = lerp(start, end, t)
            if leg.closing {
                let selectionShown = CGFloat(MenuMorph.tabsOpacity(Double(progress)))
                let startShown = CGFloat(MenuMorph.tabsOpacity(Double(leg.fromProgress)))
                alpha = leg.intoSelection
                    ? leg.startAlpha * (1 - selectionShown) / max(1 - startShown, 0.01)
                    : leg.startAlpha * min(1, (1 - t) * 1.5)
            } else {
                indicatorShown += ((indicatorRow == nil ? 0 : 1) - indicatorShown) * (1 - exp(-dt / Metrics.indicatorFade))
                alpha = leg.startAlpha + (indicatorShown - leg.startAlpha) * t
                if leg.fromGlass { grey = smoothstep(0, Metrics.lensToGrey, t) }
            }
        } else {
            if let target { frame = target }
            indicatorShown += ((indicatorRow == nil ? 0 : 1) - indicatorShown) * (1 - exp(-dt / Metrics.indicatorFade))
            alpha = indicatorShown * CGFloat(MenuMorph.rowsOpacity(Double(progress)))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        menuIndicator.frame = frame.offsetBy(dx: -glassInset, dy: 0)
        indicatorFill.layer.cornerRadius = min(frame.width, frame.height) / 2
        indicatorFill.alpha = grey
        setMenuIndicatorAlpha(alpha)
        CATransaction.commit()
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    private func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// How the lens zooms a glyph centred at `point`: smoothly ramps in place from 1.0× to `lensZoom` as the lens
    /// passes over the slot, leaving rim refraction entirely to `_UILiquidLensView` with zero horizontal drift.
    private func lensZoom(at point: CGPoint, lens: CGRect, lift: CGFloat) -> CGFloat {
        let half = lens.width / 2, reach = abs(point.x - lens.midX)
        let under = 1 - smoothstep(half - Metrics.glyphHalf, half + Metrics.glyphHalf, reach)
        return 1 + (Metrics.lensZoom - 1) * lift * under
    }

    /// The tab row as it stands, drawn flat so it can blur.
    private func tabRowImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat(for: traitCollection)
        let (lensRect, lift) = lensFrame()
        return UIGraphicsImageRenderer(size: barFrame.size, format: format).image { _ in
            for (i, slot) in slots.enumerated() {
                let frame = slotFrame(i).offsetBy(dx: isCompact ? 3 : 0, dy: 0)
                slot.bounds = CGRect(origin: .zero, size: frame.size)
                slot.center = CGPoint(x: frame.midX, y: frame.midY)
                slot.layoutIfNeeded()
                let zoom = lensZoom(at: CGPoint(x: frame.midX, y: frame.midY), lens: lensRect, lift: lift)
                for view in [slot.icon, slot.chevron].compactMap({ $0 }) {
                    guard let image = view.image else { continue }
                    let color = (view.tintColor ?? .label).resolvedColor(with: traitCollection)
                    let rect = view.frame.offsetBy(dx: frame.minX, dy: frame.minY)
                    let centre = CGPoint(x: frame.midX, y: frame.midY)
                    let scaled = CGRect(x: centre.x + (rect.minX - centre.x) * zoom,
                                        y: centre.y + (rect.minY - centre.y) * zoom,
                                        width: rect.width * zoom, height: rect.height * zoom)
                    // Drawn as it shows: the glyph upright on screen, the chevron turned with the bar.
                    let turn = view === slot.icon ? -canvasAngle : 0
                    let context = UIGraphicsGetCurrentContext()
                    context?.saveGState()
                    context?.translateBy(x: scaled.midX, y: scaled.midY)
                    context?.rotate(by: turn)
                    (image.renderingMode == .alwaysOriginal ? image : image.withTintColor(color, renderingMode: .alwaysOriginal))
                        .draw(in: CGRect(x: -scaled.width / 2, y: -scaled.height / 2, width: scaled.width, height: scaled.height))
                    context?.restoreGState()
                }
            }
        }
    }

    /// A row in the menu's coordinates, from its top. Vertical, rows run along the bar from the end Home is at.
    private func rowFrame(_ i: Int) -> CGRect {
        let size = menuFrame.size, pad = Metrics.menuPadding, row = Metrics.menuRow
        guard isVertical else {
            return CGRect(x: pad, y: pad + CGFloat(i) * row, width: size.width - pad * 2, height: row)
        }
        let along = mirrored ? size.width - pad - row * CGFloat(i + 1) : pad + row * CGFloat(i)
        return CGRect(x: along, y: pad, width: row, height: size.height - pad * 2)
    }

    private func row(at point: CGPoint) -> Int? {
        let frame = menuFrame
        guard frame.insetBy(dx: isVertical ? 0 : -24, dy: isVertical ? -24 : 0).contains(point) else { return nil }
        let along: CGFloat
        if isVertical {
            let x = point.x - frame.minX
            along = mirrored ? frame.width - Metrics.menuPadding - x : x - Metrics.menuPadding
        } else {
            along = point.y - frame.minY - Metrics.menuPadding
        }
        return min(max(Int(floor(along / Metrics.menuRow)), 0), overflow.count - 1)
    }

    private func trackMenu(_ point: CGPoint) {
        // The finger that opened the menu is on the tab row, under the bottom row: it picks nothing until it moves
        // up into the menu. Sliding along the tab row is not a choice.
        if let start = menuOpenPoint {
            guard start.y - point.y > Metrics.menuReach / 2 else { return }
            menuOpenPoint = nil
            openRow = nil
        }
        let row = row(at: point)
        guard row != hoveredRow else { return }
        hoveredRow = row
        if row != nil { fingerInRows = true }
        if row != nil { selection.selectionChanged() }
    }

    private func releaseMenu(at point: CGPoint) {
        menuTracking = false
        // Lifted where it opened the menu: the menu stays open for a tap, its indicator on the page shown, if any.
        if menuOpenPoint != nil {
            menuOpenPoint = nil
            openRow = nil
            return
        }
        if let row = row(at: point) {
            pickRow(row)
            return
        }
        closeMenu()
    }

    private func pickRow(_ index: Int) {
        let item = overflow[index]
        let changed = item.id != selectedID
        selectedID = item.id
        overflowID = item.id
        refreshSlots()
        if let slot = overflowSlot { segments.selectedSegmentIndex = slot }
        closeMenu()
        track(for: 0.9)
        changed ? onSelect?(item.id) : onReselect?(item.id)
    }

    private func activate(slot i: Int) {
        if i == overflowSlot { menuOpen ? closeMenu() : openMenu(tracking: false); return }
        guard let item = item(forSlot: i) else { return }
        if item.id == selectedID { onReselect?(item.id); return }
        select(item.id, animated: true)
        onSelect?(item.id)
    }
}


/// How the two contents cross as the glass grows, by how far it has grown (0 the bar, 1 the menu). The tab row leaves
/// over the first 60 % and the rows arrive from 20 %, so the glass is never empty.
enum MenuMorph {
    static func tabsOpacity(_ p: Double) -> Double { 1 - smoothstep(0, 0.6, p) }
    static func rowsOpacity(_ p: Double) -> Double { smoothstep(0.2, 0.9, p) }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// What the menu draws: its rows, which one the finger is on, and how far the bar has turned into it (0 the tab
/// row, 1 the menu), with the tab row's picture while it blurs away.
@MainActor @Observable private final class MenuModel {
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let icon: UIImage?
    }

    var progress: Double = 0
    var rows: [Row] = []
    var rise: [CGFloat] = []
    var shown: [Double] = []
    var closing = true
    var tabs: UIImage?
}

@available(iOS 26.0, *)
private struct MenuRowsLayer: View {
    let model: MenuModel

    private func shown(_ index: Int) -> Double { index < model.shown.count ? model.shown[index] : 0 }

    var body: some View {
        let p = model.progress
        let row = TabOverflowMenuView.Metrics.menuRow
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 0) {
                        if let icon = item.icon {
                            Image(uiImage: icon).renderingMode(icon.renderingMode == .alwaysOriginal ? .original : .template)
                                .frame(width: 24, height: 24)
                                .padding(.leading, MenuRow.iconX)
                        }
                        Text(item.title)
                            .font(.body)
                            .padding(.leading, MenuRow.labelX - MenuRow.iconX - 24)
                        Spacer(minLength: 0)
                    }
                    .frame(height: row)
                    .blur(radius: TabOverflowMenuView.Metrics.morphBlur * (1 - shown(index)))
                    .opacity(shown(index))
                    .offset(y: index < model.rise.count ? model.rise[index] : 0)
                }
            }
        }
        .foregroundStyle(Color(uiColor: .label))
        .padding(TabOverflowMenuView.Metrics.menuPadding)
        .blur(radius: model.closing ? TabOverflowMenuView.Metrics.morphBlur * (1 - MenuMorph.rowsOpacity(p)) : 0)
        .opacity(model.closing ? MenuMorph.rowsOpacity(p) : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@available(iOS 26.0, *)
private struct TabSnapshotLayer: View {
    let model: MenuModel

    var body: some View {
        let shown = MenuMorph.tabsOpacity(model.progress)
        Group {
            if let tabs = model.tabs {
                Image(uiImage: tabs)
                    .blur(radius: TabOverflowMenuView.Metrics.morphBlur * (1 - shown))
                    .opacity(shown)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Waits without effect until the bar takes the finger, then recognizes so UIKit cancels touches in underlying views.
final class TakeOverRecognizer: UIGestureRecognizer {
    var onTouchDown: ((CGPoint) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let point = touches.first?.location(in: view) { onTouchDown?(point) }
    }

    func take() {
        if state == .possible { state = .began }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .began || state == .changed { state = .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
    }
}

/// Glass that stands upright on screen while what it holds turns with the canvas so rim lighting and drop shadows stay
/// upright on vertical side-bar menus.
@available(iOS 26.0, *)
@MainActor private final class UprightGlass {
    let glass: UIVisualEffectView
    let contentView = UIView()
    weak var canvas: UIView?
    var angle: CGFloat = 0 { didSet { place() } }
    var bounds: CGRect = .zero { didSet { place() } }
    var center: CGPoint = .zero { didSet { place() } }
    var frame: CGRect {
        get { CGRect(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2, width: bounds.width, height: bounds.height) }
        set {
            bounds = CGRect(origin: .zero, size: newValue.size)
            center = CGPoint(x: newValue.midX, y: newValue.midY)
        }
    }
    var isHidden: Bool {
        get { glass.isHidden }
        set { glass.isHidden = newValue }
    }
    var effect: UIVisualEffect? {
        get { glass.effect }
        set { glass.effect = newValue }
    }
    var cornerConfiguration: UICornerConfiguration {
        get { glass.cornerConfiguration }
        set { glass.cornerConfiguration = newValue }
    }

    init(effect: UIVisualEffect) {
        glass = UIVisualEffectView(effect: effect)
        glass.contentView.addSubview(contentView)
    }

    private func place() {
        guard let canvas, let host = glass.superview else { return }
        let turned = abs(sin(angle)) > 0.5
        glass.bounds = CGRect(origin: .zero, size: turned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        glass.center = canvas.convert(center, to: host)
        let turn = CGAffineTransform(rotationAngle: angle)
        if contentView.transform != turn { contentView.transform = turn }
        contentView.bounds = CGRect(origin: .zero, size: bounds.size)
        contentView.center = CGPoint(x: glass.bounds.midX, y: glass.bounds.midY)
    }
}

@available(iOS 26.0, *)
@MainActor private final class LinkTarget: NSObject {
    weak var menu: TabOverflowMenuView?
    init(_ menu: TabOverflowMenuView) { self.menu = menu }
    @objc func tick(_ link: CADisplayLink) { menu?.tick(link) }
}

private final class MenuRow: UIView {
    static let iconX: CGFloat = 14
    static let labelX: CGFloat = 50
    var onActivate: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func accessibilityActivate() -> Bool { onActivate?(); return true }
}


@available(iOS 26.0, *)
@MainActor private final class GlassTabBarLinkTarget: NSObject {
    weak var bar: GlassTabBar?
    init(_ bar: GlassTabBar) { self.bar = bar }
    @objc func tick(_ link: CADisplayLink) { bar?.tick(link) }
}

/// One tab's glyph, with the overflow slot's chevron. VoiceOver activates it as a button.
private final class SlotView: UIView {
    let icon = UIImageView()
    let chevron: UIImageView?
    var onActivate: (() -> Void)?
    /// The chevron before the glyph along the bar rather than after: on the iPhone Duo's trailing bar that puts it
    /// below the glyph on screen.
    var chevronFirst = false { didSet { if chevronFirst != oldValue { setNeedsLayout() } } }

    init(chevron: Bool) {
        self.chevron = chevron
            ? UIImageView(image: UIImage(systemName: "chevron.up",
                                         withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)))
            : nil
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        icon.contentMode = .center
        addSubview(icon)
        if let chevron = self.chevron { addSubview(chevron) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = 24
        if let chevron {
            chevron.sizeToFit()
            // The chevron's extent along the bar: it is turned with the bar, so its own height there.
            let along = chevron.transform.a == 0 ? chevron.bounds.height : chevron.bounds.width
            let total = side + 3 + along
            let start = bounds.midX - total / 2
            let iconX = chevronFirst ? start + along + 3 : start
            icon.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            icon.center = CGPoint(x: iconX + side / 2, y: bounds.midY)
            chevron.center = CGPoint(x: chevronFirst ? start + along / 2 : iconX + side + 3 + along / 2, y: bounds.midY)
        } else {
            icon.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            icon.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    override func accessibilityActivate() -> Bool { onActivate?(); return true }
}

