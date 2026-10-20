import SwiftUI
import UniformTypeIdentifiers

/// What the composer's + button has open.
enum AttachmentSurface: Equatable {
    case menu, camera, photos
}

/// An image ready to attach. Camera captures and library photos both arrive as encoded data.
struct AttachmentImage: Sendable {
    let data: Data
    let type: UTType
}

/// Where each attachment path ends, in the composer that owns the upload.
struct AttachmentActions {
    let openFiles: () -> Void
    let openAllPhotos: () -> Void
    let attach: ([AttachmentImage]) async -> Void
}

/// The + menu and the camera and photo windows, as one card. The card opens on the + button as the menu;
/// choosing Camera or Photos grows it into a window in the keyboard's place at the bottom of the screen,
/// and Back shrinks it into the menu again. As in a native iOS 26 menu, the card starts as the + button's
/// own glass: it appears solid on the button, the + fading under it, and grows out over rows already resting
/// where they land. Closing, the rows leave first and the card shrinks back onto the button, dissolving into it as it lands.
/// The menu sits where ChatGPT's does: centred on the composer's bottom edge, clear of the screen's bottom
/// corners. With the keyboard up it can't reach over the keys as ChatGPT's system menu does (iOS draws the
/// keyboard above everything an app draws), so it rests on the keyboard, covering the +. A touch outside
/// closes it as the touch lands. Everything works in global coordinates.
struct AttachmentOverlay: View {
    /// The + button: what it has open, and its frame in global coordinates.
    let button: AttachmentModel
    let actions: AttachmentActions
    /// The menu's laid-out height: three 60pt rows and 8pt padding at the default text size.
    @State private var menuHeight: CGFloat = 196
    /// What the card shows. It outlives `surface` while the card folds back into the button, then returns
    /// to the menu, ready for the next touch.
    @State private var shown = AttachmentSurface.menu
    /// The card is out at its frame (true) or folded onto the button (false).
    @State private var open = false
    /// The card is drawn. It appears in place on the button, as the button's own glass, and hides once it
    /// has folded back, so the glass stays solid all the way instead of fading in see-through.
    @State private var materialized = false
    @State private var contentVisible = false
    /// The card is growing out of the button or folding back onto it. Meanwhile a touch on the + reverses it.
    @State private var moving: Movement?
    /// Tells a movement's completion from a later one's, so a reversed movement never finishes the next.
    @State private var movement = 0
    /// A touch is down on the + while the card moves. Gesture state, so it also resets when the system cancels
    /// the touch, which never reports an end: a flag left set kept this area over the + and the + dead.
    @GestureState private var reversing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let menuWidth: CGFloat = 260
    /// The composer's distance from the keyboard, or from the bottom safe area, below the + button.
    private static let composerInset: CGFloat = 8
    /// The menu's lowest distance from the screen's bottom edge, clear of the display's corners.
    private static let bottomClearance: CGFloat = 32
    /// The window's distance from the screen's sides and bottom, so its corners follow the display's.
    private static let windowInset: CGFloat = 12

    private var surface: AttachmentSurface? {
        get { button.surface }
        nonmutating set { button.surface = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let origin = geometry.frame(in: .global).origin
            let plus = button.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
            let window = windowFrame(in: geometry.size)
            ZStack(alignment: .topLeading) {
                // Always in place, catching touches only while the card is out. Inserted and removed instead, its
                // removal joins the fold's animation, and a view on its way out still takes touches: for as long as
                // the spring took to settle, the whole screen ignored every tap and scroll.
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in close() })
                    .allowsHitTesting(surface != nil)
                    .accessibilityHidden(true)
                // The card always waits on the button, folded and invisible, so a tap grows it out at once.
                let target = shown == .menu ? menuFrame(on: plus, in: geometry.size) : window
                // Reduced motion keeps the card in place and only fades it.
                let rect = open || reduceMotion ? target : plus
                // Folded, the content still sits where it rests, so the glass grows over it rather than carrying it.
                let rest = CGSize(width: target.midX - plus.midX, height: target.midY - plus.midY)
                card(shown, window: window.size, offset: open || reduceMotion ? .zero : rest)
                    .modifier(CardEdges(.vertical, rect.minY, rect.maxY))
                    .modifier(CardEdges(.horizontal, rect.minX, rect.maxX))
                    // Resting, the card is all but transparent rather than gone, so its glass and rows are already drawn
                    // when it grows out: a card drawn for the first time mid-animation drops frames.
                    .opacity(materialized ? 1 : 0.001)
                    .allowsHitTesting(surface != nil)
                    .accessibilityHidden(surface == nil)
                // While the card moves, the + answers the touch here, above the card and the button, and the card
                // turns back from wherever it is (`reverse`). Always in place too, for the same reason as the catcher.
                Color.clear.contentShape(Rectangle())
                    .frame(width: plus.width, height: plus.height)
                    .offset(x: plus.minX, y: plus.minY)
                    .gesture(DragGesture(minimumDistance: 0).updating($reversing) { _, down, _ in down = true })
                    .allowsHitTesting(moving != nil || reversing)
                    .accessibilityHidden(true)
            }
        }
        // The screen's edges, but for the menu not the keyboard's: with the keyboard up the overlay ends on it, so
        // the menu rests there instead of sliding under the keys, where iOS draws over it. A window takes the
        // keyboard's place, so it measures the whole screen: it grows straight to where it rests instead of chasing
        // the keyboard down, and its frame does not change on every frame of the keyboard's descent.
        .ignoresSafeArea(shown == .menu ? .container : .all)
        .onChange(of: surface) { _, next in present(next) }
        .onChange(of: reversing) { _, down in if down { reverse() } }
        .accessibilityAction(.escape, close)
    }

    /// Each surface's content keeps its own size, so the card can clip it at any size on the way.
    private func card(_ surface: AttachmentSurface, window: CGSize, offset: CGSize) -> some View {
        let arriving = AnyTransition.asymmetric(insertion: .opacity.animation(AttachmentMotion.arrive),
                                                removal: .opacity.animation(AttachmentMotion.leave))
        return AttachmentCard(surface: surface, raised: open) {
            ZStack {
                AttachmentMenu(choose: choose)
                    .frame(width: Self.menuWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuHeight = $0 }
                    .opacity(surface == .menu ? 1 : 0)
                    .animation(surface == .menu ? AttachmentMotion.arrive : AttachmentMotion.leave,
                               value: surface == .menu)
                    .allowsHitTesting(surface == .menu)
                if surface == .camera {
                    CameraPanel(back: showMenu, attach: attach)
                        .frame(width: window.width, height: window.height)
                        .transition(arriving)
                }
                if surface == .photos {
                    PhotoGridPanel(back: showMenu, openAllPhotos: { close(); actions.openAllPhotos() }, attach: attach)
                        .frame(width: window.width, height: window.height)
                        .transition(arriving)
                }
            }
            // Opacity only: a blur here would be drawn off screen on every frame of the move, over the live camera too.
            .opacity(contentVisible ? 1 : 0)
            .offset(offset)
        }
    }

    /// Lined up with the + button's leading edge and centred on the composer's bottom edge. It goes no lower
    /// than the screen's corners allow, or, over the keyboard (where this overlay ends), than the + itself.
    private func menuFrame(on plus: CGRect, in size: CGSize) -> CGRect {
        let centre = plus.maxY + Self.composerInset
        let bottom = min(centre + menuHeight / 2, max(plus.maxY, size.height - Self.bottomClearance))
        return CGRect(x: plus.minX, y: bottom - menuHeight, width: Self.menuWidth, height: menuHeight)
    }

    private func windowFrame(in size: CGSize) -> CGRect {
        let inset = Self.windowInset
        let height = min(500, size.height * 0.6)
        return CGRect(x: inset, y: size.height - inset - height, width: size.width - inset * 2, height: height)
    }

    private func choose(_ choice: AttachmentMenu.Choice) {
        switch choice {
        case .camera: surface = .camera
        case .photos: surface = .photos
        case .files: close(); actions.openFiles()
        }
    }

    private func showMenu() { surface = .menu }
    private func close() { if surface != nil { surface = nil } }

    /// Every card movement starts here. One spring moves the card both ways and picks up from wherever the
    /// card is, at its speed, so a reopen mid-fold grows straight back out.
    private func present(_ next: AttachmentSurface?) {
        guard let next else { return fold() }
        if open {
            // Menu to window and back: one card changing frame, corners and fill.
            withAnimation(motion(AttachmentMotion.resize)) { shown = next }
            return
        }
        // The folded card already waits on the button, so it grows out in the tap's own frame. Reduced
        // motion keeps it in place and fades it in.
        if reduceMotion {
            withAnimation(AttachmentMotion.reduced) { materialized = true }
        } else {
            materialized = true
        }
        let id = begin(.opening)
        withAnimation(motion(AttachmentMotion.morph), completionCriteria: .logicallyComplete) {
            shown = next
            open = true
        } completion: {
            if movement == id { moving = nil }
        }
        withAnimation(motion(AttachmentMotion.contentIn)) { contentVisible = true }
    }

    private func fold() {
        let id = begin(.folding)
        withAnimation(motion(AttachmentMotion.contentOut)) { contentVisible = false }
        // As it lands the card dissolves into the + fading in under it, so the two glasses cross-fade instead of the
        // card's glass covering the + until the card hides.
        if !reduceMotion { withAnimation(AttachmentMotion.dissolve) { materialized = false } }
        // Logically complete: the card is back on the button about when the + is, so it hides then. Waiting for the
        // spring's tail to be removed left the card's glass over the + for a moment, a pale disc before the + returned.
        withAnimation(motion(AttachmentMotion.morph), completionCriteria: .logicallyComplete) {
            open = false
            if reduceMotion { materialized = false }
        } completion: {
            // Back on the button, whose glass it matches: the card hides, a window's panel leaves, and the card
            // waits as the menu for the next touch.
            guard movement == id else { return }
            moving = nil
            materialized = false
            shown = .menu
        }
    }

    private enum Movement { case opening, folding }

    private func begin(_ next: Movement) -> Int {
        movement += 1
        moving = next
        return movement
    }

    /// A touch on the + while the card moves: a card folding back grows out again, and a card growing out folds
    /// back, each from where it is. The gesture can report the touch only as it lifts, after the movement has
    /// ended, so the touch follows where the card is headed rather than whether it still moves.
    private func reverse() {
        if surface != nil { close() } else if button.canAttach { surface = .menu }
    }

    private func motion(_ animation: Animation) -> Animation {
        reduceMotion ? AttachmentMotion.reduced : animation
    }

    private func attach(_ images: [AttachmentImage]) {
        close()
        Task { await actions.attach(images) }
    }
}
