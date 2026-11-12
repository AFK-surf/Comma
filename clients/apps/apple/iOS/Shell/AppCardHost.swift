import SwiftUI
import UIKit

/// The app card reserves a Task bar below it, or a Task rail to its left, with rounded adjoining corners.
/// UIKit animates the rendered card after one target layout. Animated SwiftUI padding
/// instead repeatedly resizes the transcript and makes its tail-following compete with the card's spring.
struct AppCardHost<Content: View>: UIViewControllerRepresentable {
    let bottomInset: CGFloat
    let leadingInset: CGFloat
    let rounded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: Content

    init(bottomInset: CGFloat, leadingInset: CGFloat = 0, rounded: Bool, @ViewBuilder content: () -> Content) {
        self.bottomInset = bottomInset
        self.leadingInset = leadingInset
        self.rounded = rounded
        self.content = content()
    }

    func makeUIViewController(context: Context) -> AppCardViewController<Content> {
        AppCardViewController(content: content, environment: context.environment, bottomInset: bottomInset, leadingInset: leadingInset, rounded: rounded)
    }

    func updateUIViewController(_ controller: AppCardViewController<Content>, context: Context) {
        controller.update(content: content, environment: context.environment, bottomInset: bottomInset, leadingInset: leadingInset, rounded: rounded,
                          animated: !reduceMotion, transaction: context.transaction)
    }
}

extension CommaTheme {
    /// Maximum radius beside a docked Task; smaller display corners cap each corner independently.
    /// The router chat's zoom uses this radius too.
    static let cardRadius: CGFloat = 32
}

/// The full-size host resolves the display's corners before its child surfaces reserve room for the dock.
/// Keep each corner independent: Duo's outer display has small corners along one edge.
struct DisplayCornerRadii: Equatable {
    var topLeft: CGFloat = .greatestFiniteMagnitude
    var topRight: CGFloat = .greatestFiniteMagnitude
    var bottomLeft: CGFloat = .greatestFiniteMagnitude
    var bottomRight: CGFloat = .greatestFiniteMagnitude

    init() {}

    @MainActor init(in view: UIView) {
        if #available(iOS 26.0, *) {
            topLeft = view.effectiveRadius(corner: .topLeft)
            topRight = view.effectiveRadius(corner: .topRight)
            bottomLeft = view.effectiveRadius(corner: .bottomLeft)
            bottomRight = view.effectiveRadius(corner: .bottomRight)
        }
    }
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
            .environment(\.homeTaskColumn, environment.homeTaskColumn)
            .environment(\.settingsColumnsFolded, environment.settingsColumnsFolded)
    }
}

/// The environment values `HostedContent` carries into its hosting controller; comparing them tells a host
/// whether its content needs them again.
struct HostedEnvironment: Equatable {
    let locale: Locale
    let colorScheme: ColorScheme
    let dynamicTypeSize: DynamicTypeSize
    let layoutDirection: LayoutDirection
    let homeTaskColumn: Bool
    let settingsColumnsFolded: Bool?

    init(_ values: EnvironmentValues) {
        locale = values.locale
        colorScheme = values.colorScheme
        dynamicTypeSize = values.dynamicTypeSize
        layoutDirection = values.layoutDirection
        homeTaskColumn = values.homeTaskColumn
        settingsColumnsFolded = values.settingsColumnsFolded
    }
}

final class AppCardViewController<Content: View>: UIViewController {
    private let hosting: UIHostingController<HostedContent<Content>>
    private var bottomInset: CGFloat
    private var leadingInset: CGFloat
    private var rounded: Bool
    private var animator: UIViewPropertyAnimator?
    private var laidOutSize: CGSize = .zero
    private var laidOutInsets: UIEdgeInsets = .zero
    private var displayCorners = DisplayCornerRadii()

    init(content: Content, environment: EnvironmentValues, bottomInset: CGFloat, leadingInset: CGFloat = 0, rounded: Bool) {
        hosting = UIHostingController(rootView: HostedContent(content: content, environment: environment))
        self.bottomInset = bottomInset
        self.leadingInset = leadingInset
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
        if #available(iOS 26.0, *) {
            view.cornerConfiguration = .corners(radius: .containerConcentric())
        } else {
            hosting.view.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        hosting.view.clipsToBounds = true
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let insets = view.window?.safeAreaInsets ?? view.safeAreaInsets
        let corners = DisplayCornerRadii(in: view)
        guard view.bounds.size != laidOutSize || insets != laidOutInsets || corners != displayCorners else { return }
        laidOutSize = view.bounds.size
        laidOutInsets = insets
        displayCorners = corners
        settleCurrentAnimation()
        UIView.performWithoutAnimation { applyLayout() }
    }

    func update(content: Content, environment: EnvironmentValues, bottomInset nextInset: CGFloat,
                leadingInset nextLeadingInset: CGFloat = 0, rounded nextRounded: Bool, animated: Bool, transaction: Transaction) {
        withTransaction(transaction) {
            hosting.rootView = HostedContent(content: content, environment: environment)
        }
        guard nextInset != bottomInset || nextLeadingInset != leadingInset || nextRounded != rounded else { return }
        let changesDock = nextRounded != rounded || (nextLeadingInset > 0) != (leadingInset > 0)
        bottomInset = nextInset
        leadingInset = nextLeadingInset
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
        // Reserve the Task's bar and system inset along the active docking edge.
        let reserved = bottomInset > 0 ? bottomInset + laidOutInsets.bottom : 0
        let reservedLeading = leadingInset > 0 ? leadingInset + laidOutInsets.left : 0
        hosting.view.frame = CGRect(x: reservedLeading, y: 0, width: max(0, view.bounds.width - reservedLeading),
                                    height: max(0, view.bounds.height - reserved))
        if #available(iOS 26.0, *) {
            hosting.view.cornerConfiguration = .corners(
                topLeftRadius: .fixed(rounded && leadingInset > 0 ? min(CommaTheme.cardRadius, displayCorners.topLeft) : 0),
                topRightRadius: 0,
                bottomLeftRadius: .fixed(rounded ? min(CommaTheme.cardRadius, displayCorners.bottomLeft) : 0),
                bottomRightRadius: .fixed(rounded && leadingInset == 0 ? min(CommaTheme.cardRadius, displayCorners.bottomRight) : 0))
        } else {
            hosting.view.layer.maskedCorners = leadingInset > 0
                ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            hosting.view.layer.cornerRadius = rounded ? CommaTheme.cardRadius : 0
        }
    }
}
