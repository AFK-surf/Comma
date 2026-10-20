import SwiftUI
import UIKit

/// The app's toast (`ToastCenter`), drawn in a window of its own so it shows over sheets as well as the tabs, the
/// router chat and the Task dock. It sits under the status bar, where nothing on any page waits for a thumb and
/// neither the keyboard, the tab bar nor a composer can cover it, as the system places its own short notices.
///
/// A glass capsule hugging its text: the status glyph carries the colour, the words stay in the text colour, as on
/// the desktop. It drops in from the top edge and leaves the way it came, by itself after a while or swiped up; a
/// finger on it holds it. VoiceOver reads each new toast out without moving its focus.
struct ToastStage: View {
    let center: ToastCenter
    /// Where the capsule is, in the window, so the window takes only touches on it.
    let area: ToastArea
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if let toast = center.current {
                ToastCard(toast: toast, center: center, area: area)
                    // A new toast replaces the old one's card; the same one updates in place.
                    .id(toast.id)
                    .transition(reduceMotion ? .opacity
                        : .offset(y: -ToastCard.travel).combined(with: .scale(scale: 0.92, anchor: .top))
                            .combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
        .animation(CommaMotion.settle(reduced: reduceMotion), value: center.current?.id)
        .onChange(of: center.current == nil) { _, gone in if gone { area.frame = .zero } }
        // Each new toast, and each change to one in place, is read out; focus stays where it was. Initially too, for a
        // toast already showing as the window opens.
        .onChange(of: center.revision, initial: true) { _, _ in
            guard let toast = center.current else { return }
            AccessibilityNotification.Announcement(toast.spoken).post()
        }
        .sensoryFeedback(trigger: center.revision) { _, _ in
            guard let toast = center.current, toast.answersMember else { return nil }
            return toast.intent == .error ? .error : toast.intent == .warning ? .warning : nil
        }
    }
}

private extension HorizontalAlignment {
    /// The message's leading edge, which a stacked action's words line up with.
    private enum Message: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.leading] }
    }
    static let message = HorizontalAlignment(Message.self)
}

/// Where the toast is on screen; an empty rect while none shows.
@MainActor final class ToastArea {
    var frame: CGRect = .zero
}

/// One toast, with its own time on screen and its own drag, so a card leaving keeps where the finger left it.
private struct ToastCard: View {
    let toast: Toast
    let center: ToastCenter
    let area: ToastArea
    @State private var drag: CGFloat = 0
    /// A finger is on the card. It lets go by itself when the system takes the touch away, which ends the drag
    /// without `onEnded` (`released`).
    @GestureState private var held = false
    /// The drag that just let go ended through `onEnded`, which has put the card where it goes.
    @State private var released = false
    /// Its time ran out under the finger; it leaves when the finger does, unless shown again meanwhile.
    @State private var expired = false
    @State private var height: CGFloat = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Half the message's cap height, which puts the glyph's centre on the middle of its first line.
    @ScaledMetric(relativeTo: .subheadline) private var halfCapHeight: CGFloat = 5.3

    /// How far above its place a card starts and ends.
    static let travel: CGFloat = 24
    private static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    /// The action's own inset, which a stacked action hangs outside the message's edge so its words line up.
    private static let actionInset: CGFloat = 12

    var body: some View {
        // At the accessibility text sizes the message takes the full width and the action goes under it.
        let stacked = typeSize.isAccessibilitySize && toast.action != nil
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .message, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 4))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CentralIcon(toast.intent.glyph, size: 20, relativeTo: .subheadline)
                    .foregroundStyle(toast.intent.tint)
                    // The words grow without bound; the glyph stops at the largest standard size.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + halfCapHeight }
                    .accessibilityHidden(true)
                Text(toast.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CommaTheme.textPrimary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize)
                    .alignmentGuide(.message) { $0[.leading] }
                    .padding(.top, 12).padding(.bottom, stacked ? 0 : 12)
            }
            .frame(maxWidth: stacked ? .infinity : nil, alignment: .leading)
            if let action = toast.action {
                Button { center.perform() } label: {
                    Text(action.title).font(.subheadline.weight(.semibold)).padding(.horizontal, Self.actionInset)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(TactileButtonStyle(scale: 0.92))
                .foregroundStyle(CommaTheme.brandSolid)
                // The action never breaks; the message gives way instead.
                .fixedSize()
                .alignmentGuide(.message) { $0[.leading] + Self.actionInset }
                .accessibilityIdentifier("toastAction")
            }
        }
        .frame(minHeight: 44)
        .padding(.leading, 14).padding(.trailing, toast.action == nil || stacked ? 18 : 4)
        .padding(.bottom, stacked ? 4 : 0)
        // One line is a capsule; more grow into the same corners.
        .commaGlass(in: Self.shape)
        .modifier(MaterializingGlass())
        .contentShape(Self.shape)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            height = frame.height
            // A card on its way out no longer takes touches.
            if center.current?.id == toast.id { area.frame = frame }
        }
        .accessibilityElement(children: toast.action == nil ? .combine : .contain)
        .accessibilityLabel(Text(toast.spoken))
        .accessibilityIdentifier("toast")
        .accessibilityAction(.escape) { center.dismiss(toast.id) }
        .offset(y: drag)
        .gesture(swipe)
        .onChange(of: held) { _, held in
            guard !held else { return }
            guard !released else { released = false; return }
            // Taken away: the card goes back, or leaves if its time ran out meanwhile.
            if expired { center.dismiss(toast.id) } else { withAnimation(CommaMotion.settle) { drag = 0 } }
        }
        // At most 420pt wide and 16pt in from the screen's sides; the capsule keeps its own width inside.
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .task(id: center.revision) { await timeOut() }
    }

    /// Up follows the finger; down gives a little and holds. Let go past a short pull, or flung, it leaves upward;
    /// otherwise it springs back at the finger's speed.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($held) { _, held, _ in held = true }
            .onChanged { value in
                let pull = value.translation.height
                drag = pull < 0 ? pull : Self.rubberBand(pull)
            }
            .onEnded { value in
                released = true
                let projected = value.predictedEndTranslation.height
                if value.translation.height < -10 && projected < -height / 2 || projected < -height {
                    center.dismiss(toast.id)
                } else if expired {
                    center.dismiss(toast.id)
                } else {
                    // The finger's speed as a share of the way back per second. Pulled down, the card moved less than
                    // the finger, so it springs back from rest instead.
                    let velocity = drag < -0.5 ? value.velocity.height / -drag : 0
                    withAnimation(CommaMotion.settle(velocity: velocity)) { drag = 0 }
                }
            }
    }

    /// Past the toast's resting place it moves less the further it is pulled, as the system's sheets do.
    private static func rubberBand(_ pull: CGFloat) -> CGFloat {
        let dimension: CGFloat = 44, constant: CGFloat = 0.55
        return pull * dimension * constant / (dimension + constant * pull)
    }

    private func timeOut() async {
        expired = false
        try? await Task.sleep(for: toast.lifetime(voiceOver: voiceOver))
        guard !Task.isCancelled, center.current?.id == toast.id else { return }
        if held { expired = true } else { center.dismiss(toast.id) }
    }
}

/// On iOS 26 the capsule's glass materializes in and out rather than fading, which glass does not do.
private struct MaterializingGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { content.glassEffectTransition(.materialize) }
        } else {
            content
        }
    }
}

private extension Toast.Intent {
    /// The desktop's filled status glyphs.
    var glyph: String {
        switch self {
        case .info: "central-circle-info-fill"
        case .success: "central-circle-check-fill"
        case .warning: "central-exclamation-circle-fill"
        case .error: "central-circle-x-fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: CommaTheme.textTertiary
        case .success: CommaTheme.successPrimary
        case .warning: CommaTheme.attention
        case .error: CommaTheme.errorPrimary
        }
    }

    var spokenPrefix: String? {
        switch self {
        case .info, .success: nil
        case .warning: String(localized: "Warning")
        case .error: String(localized: "Error")
        }
    }
}

private extension Toast {
    /// What VoiceOver reads: the kind of trouble first, as the glyph shows it, then the message.
    var spoken: String { intent.spokenPrefix.map { "\($0), \(message)" } ?? message }

    /// Long enough to read, longer with something to do, and longer still while VoiceOver reads the screen.
    func lifetime(voiceOver: Bool) -> Duration {
        let seconds: Double = action != nil ? 8 : intent == .error || intent == .warning ? 5 : 4
        return .seconds(voiceOver ? seconds * 2.5 : seconds)
    }
}

// MARK: - Window

/// Puts the toast window in the app's scene and takes it away with the app.
struct ToastWindowHost: UIViewRepresentable {
    let center: ToastCenter

    func makeUIView(context: Context) -> ToastWindowAnchor { ToastWindowAnchor(center: center) }
    func updateUIView(_ view: ToastWindowAnchor, context: Context) {}
    static func dismantleUIView(_ view: ToastWindowAnchor, coordinator: ()) { view.removeToastWindow() }
}

/// The window shows only while a toast does, and a little after, for its exit: an idle window over the app would
/// still decide the status bar's look, over a page that hides it as much as any other.
final class ToastWindowAnchor: UIView {
    private let toasts: ToastCenter
    private var toastWindow: ToastWindow?
    private var hide: DispatchWorkItem?
    /// Longer than the card's exit (`CommaMotion.settle`).
    private static let exit: TimeInterval = 0.5

    init(center: ToastCenter) {
        toasts = center
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let scene = window?.windowScene else { return removeToastWindow() }
        guard toastWindow == nil else { return }
        let overlay = ToastWindow(windowScene: scene)
        // Over the app's sheets, under the call, which keeps the top of the stack.
        overlay.windowLevel = .normal + 1
        overlay.backgroundColor = .clear
        let hosting = UIHostingController(rootView: ToastStage(center: toasts, area: overlay.area))
        hosting.view.backgroundColor = .clear
        overlay.rootViewController = hosting
        // Shown for the stage's first, empty draw, then hidden while idle: a stage first drawn with its toast already
        // in it would take it as its starting state, with no entry, announcement or haptic.
        overlay.isHidden = false
        toastWindow = overlay
        if toasts.current == nil { showWindow(false) }
        follow()
    }

    func removeToastWindow() {
        hide?.cancel(); hide = nil
        toastWindow?.isHidden = true
        toastWindow?.rootViewController = nil
        toastWindow = nil
    }

    /// Shows the window as a toast arrives and hides it once the last has left, for as long as the window lasts.
    private func follow() {
        withObservationTracking { _ = toasts.current == nil } onChange: { [weak self] in
            // Told as the toast is about to change, on the main actor that owns it, so the window is up before the
            // card draws its entry.
            MainActor.assumeIsolated { self?.showWindow(true) }
            Task { @MainActor in
                guard let self, self.toastWindow != nil else { return }
                if self.toasts.current == nil { self.showWindow(false) }
                self.follow()
            }
        }
    }

    private func showWindow(_ showing: Bool) {
        hide?.cancel(); hide = nil
        guard !showing else { toastWindow?.isHidden = false; return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.toasts.current == nil else { return }
            self.toastWindow?.isHidden = true
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exit, execute: work)
    }
}

/// Takes only the touches on the toast and never the keyboard's focus, so the app beneath keeps working.
private final class ToastWindow: UIWindow {
    let area = ToastArea()

    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard area.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
