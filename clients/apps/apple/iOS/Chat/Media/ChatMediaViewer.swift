import SwiftUI
import UIKit
import AVKit

/// A UIKit presentation anchor keeps the viewer above the composer, Task dock and Router chrome.
struct ChatMediaPresentation: UIViewControllerRepresentable {
    let gallery: ChatMediaGallery
    let store: CommaStore

    func makeUIViewController(context: Context) -> ChatMediaPresenter { ChatMediaPresenter(gallery: gallery, store: store) }
    func updateUIViewController(_ controller: ChatMediaPresenter, context: Context) {}
    static func dismantleUIViewController(_ controller: ChatMediaPresenter, coordinator: Void) { controller.close() }
}

final class ChatMediaPresenter: UIViewController {
    let gallery: ChatMediaGallery
    let store: CommaStore
    private let boundary: Int
    private weak var viewer: ChatMediaViewer?

    init(gallery: ChatMediaGallery, store: CommaStore) {
        self.gallery = gallery; self.store = store; boundary = store.boundaryToken
        super.init(nibName: nil, bundle: nil)
        gallery.open = { [weak self] item, image in self?.open(item, image: image) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
    }

    private func open(_ item: ChatMediaItem, image: UIImage?) {
        guard view.window != nil, viewer?.navigationController?.presentingViewController == nil, store.isCurrent(boundary),
              let index = gallery.items.firstIndex(where: { $0.id == item.id }) else { return }
        let viewer = ChatMediaViewer(items: gallery.items, index: index, initialImage: image, gallery: gallery, store: store)
        self.viewer = viewer
        // A page change back to an earlier session's last message must still reveal its tile.
        gallery.returnMessageID = item.messageID
        let navigation = UINavigationController(rootViewController: viewer)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigation.navigationBar.standardAppearance = appearance
        navigation.navigationBar.scrollEdgeAppearance = appearance
        navigation.navigationBar.compactAppearance = appearance
        navigation.navigationBar.tintColor = UIColor(CommaTheme.imageViewerForeground)
        navigation.overrideUserInterfaceStyle = .dark
        navigation.view.accessibilityViewIsModal = true
        // Keep the transcript mounted so a page change can reveal the current image's return tile.
        navigation.modalPresentationStyle = .overFullScreen
        if UIAccessibility.isReduceMotionEnabled {
            navigation.modalTransitionStyle = .crossDissolve
        } else {
            let options = UIViewController.Transition.ZoomOptions()
            options.alignmentRectProvider = { [weak viewer, weak navigation] _ in
                guard let viewer, let navigation else { return .null }
                return navigation.view.convert(viewer.imageFrame, from: viewer.view)
            }
            options.interactiveDismissShouldBegin = { [weak viewer] interaction in
                guard let viewer, viewer.currentPage?.scroll.zoomScale == 1, !viewer.paging else { return false }
                // Leave horizontal motion to the pager and zoomed-in motion to the image's scroll view.
                return interaction.velocity.dy > abs(interaction.velocity.dx)
            }
            navigation.preferredTransition = .zoom(options: options) { [weak viewer, weak gallery] _ in
                guard let viewer else { return nil }
                return gallery?.source(for: viewer.currentItem.id)
            }
        }
        present(navigation, animated: true)
    }

    func close() {
        gallery.open = nil
        if let viewer {
            viewer.cancelLoads()
            (viewer.navigationController ?? viewer).dismiss(animated: false)
        }
    }
}

/// The system zoom transition owns the interruptible, finger-tracked shrink and its velocity-aware finish/cancel.
/// UIPageViewController creates only the current page and its neighbours.
final class ChatMediaViewer: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    let items: [ChatMediaItem]
    private(set) var index: Int
    let gallery: ChatMediaGallery
    let store: CommaStore
    private let initialImage: UIImage?
    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private let count = UILabel()
    private let footerCount = UILabel()
    private(set) var paging = false
    private var backgroundObserver: NSObjectProtocol?

    var currentItem: ChatMediaItem { items[index] }
    var currentPage: ChatMediaPage? { pager.viewControllers?.first as? ChatMediaPage }
    var imageFrame: CGRect {
        guard let image = currentPage?.imageView else { return .null }
        return image.convert(image.bounds, to: view)
    }

    init(items: [ChatMediaItem], index: Int, initialImage: UIImage?, gallery: ChatMediaGallery, store: CommaStore) {
        self.items = items; self.index = index; self.initialImage = initialImage; self.gallery = gallery; self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(CommaTheme.imageViewerBackground)
        view.accessibilityIdentifier = "chatImageViewer"
        pager.dataSource = self; pager.delegate = self
        addChild(pager)
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.setViewControllers([page(at: index, initial: initialImage)], direction: .forward, animated: false)
        // A native image item keeps the system's Glass background and can move into Duo's vertical bar.
        let closeButton = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.closeViewer() })
        closeButton.accessibilityLabel = String(localized: "Close")
        closeButton.accessibilityIdentifier = "closeChatImageViewer"
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) { closeButton.axisBehavior = .verticalPreferred }
        #endif
        navigationItem.leftBarButtonItem = closeButton
        if #available(iOS 27.0, *) { navigationItem.navigationBarMinimization.minimizationBehavior = .never }
        for label in [count, footerCount] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = UIColor(CommaTheme.imageViewerForeground)
            label.textAlignment = .center
            label.accessibilityIdentifier = "chatImagePosition"
        }
        footerCount.isHidden = true
        view.addSubview(footerCount)
        navigationItem.titleView = count
        pager.view.translatesAutoresizingMaskIntoConstraints = false
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            pager.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            pager.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            pager.view.topAnchor.constraint(equalTo: view.topAnchor),
            pager.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updatePosition()
        // Reduce Motion uses a crossfade for presentation. Keep the same explicit downward close gesture.
        if UIAccessibility.isReduceMotionEnabled {
            let down = UISwipeGestureRecognizer(target: self, action: #selector(reducedMotionSwipe))
            down.direction = .down
            down.delegate = self
            view.addGestureRecognizer(down)
        }
    }

    override func accessibilityPerformEscape() -> Bool { closeViewer(); return true }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if backgroundObserver == nil {
            backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.currentPage?.pauseVideo() }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *), traitCollection.verticalBarEdge != .unspecified {
            // A title would retain an empty horizontal header above Duo's image content.
            if navigationItem.titleView != nil { navigationItem.titleView = nil }
            footerCount.isHidden = items.count == 1
            let size = footerCount.intrinsicContentSize
            let room = view.safeAreaLayoutGuide.layoutFrame
            footerCount.frame = CGRect(x: room.midX - size.width / 2, y: room.maxY - CommaTheme.imageViewerControl,
                                 width: size.width, height: CommaTheme.imageViewerControl)
            return
        }
        #endif
        footerCount.isHidden = true
        if navigationItem.titleView !== count { navigationItem.titleView = count }
    }

    @objc private func closeViewer() { (navigationController ?? self).dismiss(animated: true) }

    @objc private func reducedMotionSwipe() {
        if currentPage?.scroll.zoomScale == 1, !paging { closeViewer() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The page's scroll recognizer must not consume the reduced-motion downward swipe.
        gestureRecognizer is UISwipeGestureRecognizer
    }

    func cancelLoads() { pager.children.compactMap { $0 as? ChatMediaPage }.forEach { $0.cancelLoad() } }

    private func page(at index: Int, initial: UIImage? = nil) -> ChatMediaPage {
        ChatMediaPage(item: items[index], index: index, initial: initial, gallery: gallery, store: store)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore controller: UIViewController) -> UIViewController? {
        guard let page = controller as? ChatMediaPage, page.index > 0 else { return nil }
        return self.page(at: page.index - 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter controller: UIViewController) -> UIViewController? {
        guard let page = controller as? ChatMediaPage, page.index + 1 < items.count else { return nil }
        return self.page(at: page.index + 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        paging = true
    }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        paging = false
        guard completed, let page = currentPage else { return }
        index = page.index
        updatePosition()
        gallery.returnMessageID = currentItem.messageID
    }

    private func updatePosition() {
        for label in [count, footerCount] {
            label.text = "\(index + 1) / \(items.count)"
            label.accessibilityLabel = label.text
        }
        count.isHidden = items.count == 1
    }
}

final class ChatMediaPage: UIViewController, UIScrollViewDelegate, @preconcurrency AVPlayerViewControllerDelegate {
    let item: ChatMediaItem
    let index: Int
    let scroll = UIScrollView()
    let imageView = UIImageView()
    private let gallery: ChatMediaGallery
    private let store: CommaStore
    private var load: Task<Void, Never>?
    private let retry = UIButton(type: .system)
    private let progress = UIActivityIndicatorView(style: .medium)
    private var laidOutSize = CGSize.zero
    private var loadID = UUID()
    private var video: ChatVideoAsset?
    private var videoController: AVPlayerViewController?
    private var readyObservation: NSKeyValueObservation?
    private var failureObservation: NSKeyValueObservation?
    private var shouldResumePlayback = true
    private var systemFullscreen = false

    init(item: ChatMediaItem, index: Int, initial: UIImage?, gallery: ChatMediaGallery, store: CommaStore) {
        self.item = item; self.index = index; self.gallery = gallery; self.store = store
        super.init(nibName: nil, bundle: nil)
        imageView.image = initial ?? gallery.cached(item, full: true) ?? gallery.cached(item, full: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        scroll.delegate = self
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = item.isVideo ? 1 : 4
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = item.attachment.name
        imageView.accessibilityIdentifier = "chatPreviewImage-" + item.id
        view.addSubview(scroll); scroll.addSubview(imageView)
        retry.setTitle(String(localized: "Retry"), for: .normal)
        retry.tintColor = UIColor(CommaTheme.imageViewerForeground)
        retry.addTarget(self, action: #selector(retryContent), for: .touchUpInside)
        retry.isHidden = true
        view.addSubview(retry); view.addSubview(progress)
        progress.color = UIColor(CommaTheme.imageViewerForeground)
        if !item.isVideo {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
            doubleTap.numberOfTapsRequired = 2
            scroll.addGestureRecognizer(doubleTap)
        }
        readImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if laidOutSize != view.bounds.size {
            laidOutSize = view.bounds.size
            scroll.zoomScale = 1
            scroll.frame = view.bounds
            layoutImage()
        }
        retry.sizeToFit()
        retry.frame = CGRect(x: 0, y: view.bounds.height - view.safeAreaInsets.bottom - CommaTheme.imageViewerControl,
                             width: view.bounds.width, height: CommaTheme.imageViewerControl)
        progress.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if !systemFullscreen { videoController?.view.frame = view.bounds }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if !systemFullscreen { pauseVideo() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !systemFullscreen { cancelLoad() }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if item.isVideo {
            startVideo()
            if shouldResumePlayback { videoController?.player?.play() }
        }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if load == nil, gallery.cached(item, full: !item.isVideo) == nil { readImage() }
    }

    @objc private func retryContent() {
        readImage()
        if item.isVideo { stopVideo(); shouldResumePlayback = true; startVideo() }
    }

    @objc private func readImage() {
        guard load == nil else { return }
        retry.isHidden = true
        if imageView.image == nil { progress.startAnimating() }
        let id = UUID()
        loadID = id
        load = Task { [weak self, gallery, store, item] in
            do {
                let image = try await gallery.image(item, full: !item.isVideo, store: store)
                guard !Task.isCancelled, let self else { return }
                // Keep the exact thumbnail through the opening transition, then replace its pixels in place.
                if let transition = self.transitionCoordinator, transition.isAnimated {
                    await withCheckedContinuation { continuation in
                        transition.animate(alongsideTransition: nil) { _ in continuation.resume() }
                    }
                }
                guard !Task.isCancelled else { return }
                self.imageView.image = image
                self.layoutImage()
            } catch {
                // A playing video keeps its controls clear when only its cover failed.
                if !Task.isCancelled, self?.videoController?.isReadyForDisplay != true { self?.retry.isHidden = false }
            }
            if self?.loadID == id {
                self?.progress.stopAnimating()
                self?.load = nil
            }
        }
    }

    func cancelLoad() { load?.cancel(); load = nil; stopVideo() }

    func pauseVideo() {
        guard let player = videoController?.player else { return }
        shouldResumePlayback = player.timeControlStatus != .paused
        player.pause()
    }

    private func startVideo() {
        guard videoController == nil else { return }
        do {
            let resource = try gallery.video(item, store: store)
            video = resource
            let playerItem = AVPlayerItem(asset: resource.asset)
            playerItem.preferredForwardBufferDuration = 5
            let player = AVPlayer(playerItem: playerItem)
            player.audiovisualBackgroundPlaybackPolicy = .pauses
            let controller = AVPlayerViewController()
            controller.player = player
            controller.delegate = self
            controller.allowsPictureInPicturePlayback = false
            controller.updatesNowPlayingInfoCenter = false
            controller.view.accessibilityIdentifier = "chatVideoPlayer"
            controller.view.alpha = 0
            controller.view.frame = view.bounds
            videoController = controller
            addChild(controller)
            view.insertSubview(controller.view, belowSubview: retry)
            controller.didMove(toParent: self)
            readyObservation = controller.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self, weak resource] _, _ in
                Task { @MainActor in
                    guard let self, let resource, self.video === resource, self.videoController?.isReadyForDisplay == true else { return }
                    self.videoController?.view.alpha = 1
                    self.retry.isHidden = true
                    self.progress.stopAnimating()
                }
            }
            failureObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self, weak resource] observed, _ in
                let failed = observed.status == .failed
                Task { @MainActor in
                    guard let self, let resource, self.video === resource, failed else { return }
                    self.retry.isHidden = false
                    self.progress.stopAnimating()
                }
            }
            if shouldResumePlayback { player.play() }
        } catch { retry.isHidden = false }
    }

    private func stopVideo() {
        readyObservation = nil; failureObservation = nil
        videoController?.player?.pause()
        videoController?.player?.replaceCurrentItem(with: nil)
        videoController?.willMove(toParent: nil)
        videoController?.view.removeFromSuperview()
        videoController?.removeFromParent()
        videoController = nil
        video?.close(); video = nil
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willBeginFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator) {
        systemFullscreen = true
    }
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator) {
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.systemFullscreen = false }
    }

    private func layoutImage() {
        guard scroll.zoomScale == 1 else { return }
        let size = imageView.image?.size ?? (item.isVideo ? scroll.bounds.size : CGSize(width: 1, height: 1))
        let ratio = min(scroll.bounds.width / max(size.width, 1), scroll.bounds.height / max(size.height, 1))
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: size.width * ratio, height: size.height * ratio))
        scroll.contentSize = imageView.bounds.size
        centerImage()
    }
    private func centerImage() {
        imageView.center = CGPoint(x: max(scroll.contentSize.width, scroll.bounds.width) / 2,
                                   y: max(scroll.contentSize.height, scroll.bounds.height) / 2)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled) }
        else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scroll.bounds.width / 2, height: scroll.bounds.height / 2)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                  width: size.width, height: size.height), animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}
