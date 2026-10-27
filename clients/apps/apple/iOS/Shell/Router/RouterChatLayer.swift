import SwiftUI
import UIKit

/// The router chat as a layer over the tabs and their chrome, under the Task dock. It zooms out of the
/// router button and back into it. A finger can pick it up and close it (`RouterLayerController+Drag`); so do
/// the close button and the VoiceOver escape gesture.
struct RouterChatLayer: UIViewControllerRepresentable {
    let store: CommaStore
    let open: Bool
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIViewController(context: Context) -> RouterLayerController {
        RouterLayerController(content: content(context))
    }

    func updateUIViewController(_ controller: RouterLayerController, context: Context) {
        controller.update(content: content(context), open: open, reduceMotion: reduceMotion)
    }

    /// The layer's SwiftUI side, built here where the navigation is in the environment; the controller takes it
    /// whole and finds the navigation on it.
    private func content(_ context: Context) -> HostedContent<RouterLayerContent> {
        HostedContent(content: RouterLayerContent(store: store, navigation: navigation), environment: context.environment)
    }
}

/// UIKit owns the layer and Core Animation zooms the chat's rendered layers (`RouterZoomFrame`): the transcript
/// lays out once at full size, and the zoom keeps its pace while the main thread is busy. Closed, every touch
/// passes through to the tabs.
final class RouterLayerController: UIViewController {
    let hosting: UIHostingController<HostedContent<RouterLayerContent>>
    /// Holds the lens; the zoom masks it to the zoom's rect.
    private let stage = UIView()
    /// Holds the chat at the layer's full size; the zoom scales and moves it with its own transform. On screen, an
    /// animated `sublayerTransform` on the stage did not keep pace with the mask and the button's face, so the chat
    /// spilled past its card and the face swelled back out after the chat had reached the button.
    private let lens = UIView()
    /// Masks the chat to the zoom's rect and corners while it is not settled open.
    private let mask = CALayer()
    /// The button's face, which the chat turns into as it closes and grows out of as it opens.
    private let face = RouterButtonFace()
    /// Darkens the page behind the chat as the chat grows over it, so the chat reads as a card lifted off the page
    /// while it zooms; clear with the chat at the button, darkest at full size, where the chat covers it.
    private let shade = CALayer()
    var navigation: AppNavigation { hosting.rootView.content.navigation }
    /// Where the layer is going; the zoom may still be on its way there.
    private(set) var open = false
    private var wantsOpen = false
    private(set) var reduceMotion = false
    private var laidOut = false
    /// Advances whenever a zoom starts or stops, so a stopped zoom's completion knows it is stale.
    private var zoomGeneration = 0
    /// Closed and still. The chat is then masked away, opaque and at full size, rather than hidden or
    /// transparent: SwiftUI counts a hidden or transparent transcript's rows as out of view and does not look
    /// again when the chat opens, so a chat mounted ahead of its first opening would never count a reply as seen.
    private var closedAtRest = true
    /// The finger holding the chat, while one does.
    var hold: RouterHold?

    init(content: HostedContent<RouterLayerContent>) {
        hosting = RouterContentHostingController(rootView: content)
        // The chat page inside the navigation stack avoids the keyboard itself.
        hosting.safeAreaRegions = .container
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = RouterContainerView()
        container.controller = self
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        stage.accessibilityElementsHidden = true
        mask.backgroundColor = UIColor.black.cgColor
        mask.cornerCurve = .continuous
        shade.backgroundColor = UIColor.black.cgColor
        shade.opacity = 0
        view.layer.addSublayer(shade)
        view.addSubview(stage)
        stage.addSubview(lens)
        addChild(hosting)
        hosting.view.backgroundColor = .clear
        lens.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        view.addSubview(face)
        installDrag()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, stage.frame != view.bounds else { return }
        // A new layer size lands the zoom where it was going, before the new frames: UIKit works out the chat's safe
        // area through the lens when they change, and a lens still scaled toward the button (to nothing while the
        // chat rests closed) left the chat no top inset, so its navigation bar sat under the status bar.
        stopZoom()
        hold = nil
        land()
        stage.frame = view.bounds
        face.frame = view.bounds
        shade.frame = view.bounds
        lens.frame = stage.bounds
        hosting.view.frame = lens.bounds
        guard !laidOut else { return }
        laidOut = true
        if wantsOpen { appear() }
    }

    /// Open from the start, as the app opens on the chat: it is simply there, with no zoom out of its button.
    private func appear() {
        open = true
        view.accessibilityViewIsModal = true
        closedAtRest = false
        land()
        navigation.routerSettled()
    }

    func update(content: HostedContent<RouterLayerContent>, open next: Bool, reduceMotion: Bool) {
        hosting.rootView = content
        self.reduceMotion = reduceMotion
        wantsOpen = next
        if laidOut, next != open { move(open: next, velocity: 0) }
    }

    func close() { navigation.closeRouter() }

    /// The router button the chat closes into, in the layer.
    var closedFrame: RouterZoomFrame {
        let button = view.convert(navigation.routerButtonFrame, from: nil)
        guard button.isEmpty else { return .closed(into: button) }
        // Before the button reports its frame, the bottom trailing corner.
        return .closed(into: CGRect(x: view.bounds.maxX - 72, y: view.bounds.maxY - 90, width: 56, height: 56))
    }

    /// Where the chat is on screen now.
    var shownFrame: RouterZoomFrame {
        stage.layer.mask == nil ? .open(in: view.bounds) : RouterZoomFrame(shownBy: mask)
    }

    /// Zooms toward open or closed. `velocity` is the finger's speed toward that end, as a fraction of the
    /// remaining distance per second, so the zoom carries on at the finger's pace.
    func move(open next: Bool, velocity: CGFloat) {
        open = next
        wantsOpen = next
        view.accessibilityViewIsModal = next
        // The keyboard goes down before the closing zoom starts.
        if !next { view.endEditing(true) }
        let fromButton = closedAtRest
        if closedAtRest {
            stage.layer.opacity = 0
            place(reduceMotion ? .open(in: view.bounds) : closedFrame)
            closedAtRest = false
        }
        // VoiceOver, and anything else reading the screen, finds the chat once it has arrived.
        stage.accessibilityElementsHidden = true
        let from = stopZoom()
        // With Reduce Motion the chat fades where it is instead of zooming.
        let target: RouterZoomFrame = switch (next, reduceMotion) {
        case (true, false): .opening(in: view.bounds)
        case (true, true): .open(in: view.bounds)
        case (false, false): closedFrame
        case (false, true): from
        }
        let generation = zoomGeneration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.zoomGeneration == generation else { return }
            self.land()
            if next { self.navigation.routerSettled() }
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
        stage.layer.mask = mask
        target.animate(layer: lens.layer, mask: mask, from: from, velocity: velocity, reduceMotion: reduceMotion)
        fade(to: next ? 1 : 0, velocity: velocity)
        let darkness = RouterSpring.animation("opacity", velocity: velocity, reduceMotion: reduceMotion)
        darkness.fromValue = shading(at: from)
        shade.opacity = shading(at: target)
        darkness.toValue = shade.opacity
        shade.add(darkness, forKey: "routerZoom.opacity")
        face.zoom(from: from, to: target, button: closedFrame.rect, opening: next, fromButton: fromButton,
                  velocity: velocity, reduceMotion: reduceMotion)
        if !next, !reduceMotion {
            let landing = RouterSpring.landing(velocity: velocity, distance: from.rect.width - closedFrame.rect.width)
            face.takeIn(landing)
            navigation.routerLanding?(landing)
        }
        CATransaction.commit()
    }

    /// Stops the zoom where it is on screen and returns that frame.
    @discardableResult func stopZoom() -> RouterZoomFrame {
        zoomGeneration += 1
        let frame = shownFrame
        let opacity = stage.layer.shown.opacity
        stage.layer.removeAnimation(forKey: "routerZoom.opacity")
        lens.layer.removeAnimation(forKey: "routerZoom.transform")
        mask.removeAllAnimations()
        shade.removeAllAnimations()
        face.stop()
        navigation.routerLanding?(nil)
        stage.layer.opacity = opacity
        if stage.layer.mask != nil { place(frame) }
        return frame
    }

    func place(_ frame: RouterZoomFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.layer.mask = mask
        frame.apply(to: lens.layer, mask: mask)
        shade.opacity = shading(at: frame)
        CATransaction.commit()
    }

    /// The shade with the chat at `frame`: none with it at the button's size, deepest at the screen's.
    private func shading(at frame: RouterZoomFrame) -> Float {
        let button = closedFrame.rect.width, full = view.bounds.width
        guard !reduceMotion, full > button else { return 0 }
        let grown = Float(min(1, max(0, (frame.rect.width - button) / (full - button))))
        return grown * (traitCollection.userInterfaceStyle == .dark ? 0.45 : 0.2)
    }

    /// Puts the chat where it is going, at once. Settled open it drops its mask, which would cost an offscreen
    /// pass on every frame it scrolls.
    private func land() {
        if open {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stage.layer.mask = nil
            lens.layer.transform = CATransform3DIdentity
            stage.layer.opacity = 1
            // Under the chat, the shade would only cost a pass on every frame.
            shade.opacity = 0
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stage.layer.mask = mask
            lens.layer.transform = CATransform3DIdentity
            mask.bounds = .zero
            stage.layer.opacity = 1
            CATransaction.commit()
            closedAtRest = true
        }
        face.stop()
        stage.accessibilityElementsHidden = !open
    }

    /// Opening, the chat fades in over the zoom's first third. Closing, it fades under the button's face as it
    /// arrives at the button, and is gone by the time the face starts handing over to the button
    /// (`RouterButtonFace.zoom`); still there then, the transcript showed through the button.
    private func fade(to opacity: Float, velocity: CGFloat) {
        let span: (CGFloat, CGFloat) = opacity > stage.layer.opacity ? (0, 1 / 3) : (0.7, 0.9)
        RouterSpring.fade(stage.layer, to: opacity, over: span, velocity: velocity, reduceMotion: reduceMotion)
    }
}

/// The chat stays at its container's full size while its rendered layers zoom. UIKit can retain a zero top inset
/// on the hosting view after a reply/keyboard transition, although every ancestor still has the screen's inset.
/// Keep that container-owned space on this host; the navigation stack adds its own bar below it.
private final class RouterContentHostingController: UIHostingController<HostedContent<RouterLayerContent>> {
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        reconcileContainerTopInset()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        reconcileContainerTopInset()
    }

    private func reconcileContainerTopInset() {
        guard let container = parent?.viewIfLoaded, let hosted = viewIfLoaded else { return }
        var additional = additionalSafeAreaInsets
        let inherited = hosted.safeAreaInsets.top - additional.top
        let missing = max(0, container.safeAreaInsets.top - inherited)
        guard additional.top != missing else { return }
        additional.top = missing
        additionalSafeAreaInsets = additional
    }
}
