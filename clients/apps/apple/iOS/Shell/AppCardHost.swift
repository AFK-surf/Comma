import SwiftUI
import UIKit

/// The app as one card above the canvas. With a Task docked it ends above the Task bar with rounded
/// bottom corners. UIKit animates the rendered card after one target layout: animating SwiftUI padding
/// instead repeatedly resizes the transcript and makes its tail-following compete with the card's spring.
struct AppCardHost<Content: View>: UIViewControllerRepresentable {
    let bottomInset: CGFloat
    let rounded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: Content

    init(bottomInset: CGFloat, rounded: Bool, @ViewBuilder content: () -> Content) {
        self.bottomInset = bottomInset
        self.rounded = rounded
        self.content = content()
    }

    func makeUIViewController(context: Context) -> AppCardViewController<Content> {
        AppCardViewController(content: content, environment: context.environment, bottomInset: bottomInset, rounded: rounded)
    }

    func updateUIViewController(_ controller: AppCardViewController<Content>, context: Context) {
        controller.update(content: content, environment: context.environment, bottomInset: bottomInset, rounded: rounded,
                          animated: !reduceMotion, transaction: context.transaction)
    }
}

extension CommaTheme {
    /// The app card's rounded bottom corners above a docked Task; the router chat's zoom ends on it too.
    static let cardRadius: CGFloat = 32
}

/// SwiftUI content in a child hosting controller, with the environment values that do not cross into it.
struct HostedContent<Content: View>: View {
    let content: Content
    let environment: HostedEnvironment

    init(content: Content, environment: EnvironmentValues) {
        self.content = content
        self.environment = HostedEnvironment(environment)
    }

    var body: some View {
        content
            .environment(\.locale, environment.locale)
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.layoutDirection, environment.layoutDirection)
    }
}

/// The environment values `HostedContent` carries into its hosting controller; comparing them tells a host
/// whether its content needs them again.
struct HostedEnvironment: Equatable {
    let locale: Locale
    let colorScheme: ColorScheme
    let dynamicTypeSize: DynamicTypeSize
    let layoutDirection: LayoutDirection

    init(_ values: EnvironmentValues) {
        locale = values.locale
        colorScheme = values.colorScheme
        dynamicTypeSize = values.dynamicTypeSize
        layoutDirection = values.layoutDirection
    }
}

final class AppCardViewController<Content: View>: UIViewController {
    private let hosting: UIHostingController<HostedContent<Content>>
    private var bottomInset: CGFloat
    private var rounded: Bool
    private var animator: UIViewPropertyAnimator?
    private var laidOutSize: CGSize = .zero
    private var laidOutInsets: UIEdgeInsets = .zero

    init(content: Content, environment: EnvironmentValues, bottomInset: CGFloat, rounded: Bool) {
        hosting = UIHostingController(rootView: HostedContent(content: content, environment: environment))
        self.bottomInset = bottomInset
        self.rounded = rounded
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(hosting)
        hosting.view.backgroundColor = .clear
        hosting.view.layer.cornerCurve = .continuous
        hosting.view.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        hosting.view.clipsToBounds = true
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let insets = view.window?.safeAreaInsets ?? view.safeAreaInsets
        guard view.bounds.size != laidOutSize || insets != laidOutInsets else { return }
        laidOutSize = view.bounds.size
        laidOutInsets = insets
        settleCurrentAnimation()
        UIView.performWithoutAnimation { applyLayout() }
    }

    func update(content: Content, environment: EnvironmentValues, bottomInset nextInset: CGFloat,
                rounded nextRounded: Bool, animated: Bool, transaction: Transaction) {
        withTransaction(transaction) {
            hosting.rootView = HostedContent(content: content, environment: environment)
        }
        guard nextInset != bottomInset || nextRounded != rounded else { return }
        let changesDock = nextRounded != rounded
        bottomInset = nextInset
        rounded = nextRounded
        guard isViewLoaded, laidOutSize.width > 0 else { return }
        settleCurrentAnimation()
        // Only Task open/close changes the inset, on a spring; the keyboard never does (`AppShellView`).
        guard animated, changesDock else {
            applyLayout()
            return
        }
        let spring = UISpringTimingParameters(mass: 1, stiffness: 275, damping: 30, initialVelocity: .zero)
        let animation = UIViewPropertyAnimator(duration: 0, timingParameters: spring)
        animation.addAnimations { self.applyLayout(); self.hosting.view.layoutIfNeeded() }
        animation.addCompletion { [weak self] _ in self?.animator = nil }
        animator = animation
        animation.startAnimation()
    }

    private func settleCurrentAnimation() {
        guard let animator else { return }
        animator.stopAnimation(false)
        animator.finishAnimation(at: .current)
        self.animator = nil
    }

    private func applyLayout() {
        // With a dock, the card ends above both the bar and the Home indicator. Without it, the
        // hosting controller supplies the ordinary container/keyboard safe area to the content.
        let reserved = bottomInset > 0 ? bottomInset + laidOutInsets.bottom : 0
        hosting.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width,
                                    height: max(0, view.bounds.height - reserved))
        hosting.view.layer.cornerRadius = rounded ? CommaTheme.cardRadius : 0
    }
}
