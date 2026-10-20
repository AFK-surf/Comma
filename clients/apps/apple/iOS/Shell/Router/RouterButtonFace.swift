import UIKit

/// The router button's face, carried by the zoom the way an app's icon is when the app opens out of it and closes
/// back into it: a card in the button's fill around the Comma mark. The mark stays on the button's own mark the
/// whole time, and only the card moves, so closing reads as the chat collapsing into the button, and the face then
/// hands over to the button with its mark exactly in place. Opening from the button, the card is the button growing
/// and gives way to the chat. The fill is the colour the button's glass shows (`CommaTheme.glassOverPage`): in the
/// page's colour, the face read in dark mode as a black disc landing on the grey button.
final class RouterButtonFace: UIView {
    private let card = UIView()
    private let mark = UIImageView(image: UIImage(named: "CommaMark")?.withRenderingMode(.alwaysTemplate))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        accessibilityElementsHidden = true
        card.layer.cornerCurve = .continuous
        card.layer.masksToBounds = true
        card.backgroundColor = UIColor(CommaTheme.glassOverPage)
        mark.tintColor = UIColor(CommaTheme.textPrimary)
        mark.contentMode = .scaleAspectFit
        addSubview(card)
        addSubview(mark)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Zooms with the chat from `start` to `target`, the mark on `button`'s. Closing, the face comes up as the chat
    /// nears the button and goes into it as the button takes it in (`AppNavigation.routerLanding`). Opening, it
    /// shows only when the zoom starts at the button, fading as the chat appears.
    func zoom(from start: RouterZoomFrame, to target: RouterZoomFrame, button: CGRect, opening: Bool,
              fromButton: Bool, velocity: CGFloat, reduceMotion: Bool) {
        stop()
        guard !reduceMotion, !opening || fromButton else { return }
        isHidden = false
        let side = RouterCircleOverlay.markSide
        mark.frame = CGRect(x: button.midX - side / 2, y: button.midY - side / 2, width: side, height: side)
        target.animateShape(card.layer, from: start, velocity: velocity, reduceMotion: false)
        if opening {
            layer.opacity = 1
            RouterSpring.fade(layer, to: 0, over: (0.05, 0.35), velocity: velocity, reduceMotion: false)
        } else {
            layer.opacity = 0
            // The chat's closing fade ends by the third time (`RouterLayerController.fade`), so nothing of the
            // transcript shows through as the face hands over.
            let times = [0.45, 0.75, 0.9, 0.97].map { RouterSpring.time(toCover: $0, velocity: velocity) }
            guard let end = times.last, end > 0 else { return }
            let rise = CAKeyframeAnimation(keyPath: "opacity")
            rise.values = [0, 0, 1, 1, 0]
            rise.keyTimes = ([0] + times.map { $0 / end }).map { NSNumber(value: $0) }
            rise.duration = end
            layer.add(rise, forKey: "routerZoom.opacity")
        }
    }

    /// The chat arriving at the button (`AppNavigation.routerLanding`): the face gives with the button, as one.
    func takeIn(_ landing: RouterLanding) {
        for layer in [card.layer, mark.layer] {
            let intake = landing.intake
            intake.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + landing.delay
            layer.add(intake, forKey: "routerIntake")
        }
    }

    /// Puts the face away: the zoom arrived, having taken the face into the button or past it to the chat, or a
    /// finger took hold of the chat, which the face is no part of.
    func stop() {
        for layer in [layer, card.layer, mark.layer] { layer.removeAllAnimations() }
        isHidden = true
    }
}
