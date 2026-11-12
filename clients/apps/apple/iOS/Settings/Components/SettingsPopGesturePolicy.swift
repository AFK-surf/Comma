import SwiftUI
import UIKit

/// The outer Settings pop moves three columns. UIKit's interactive pop controls only the detail column,
/// so this boundary uses the Back button until the columns share an interactive transition owner.
struct SettingsPopGesturePolicy: UIViewControllerRepresentable {
    let blocked: Bool

    func makeUIViewController(context: Context) -> Controller { Controller(blocked: blocked) }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.blocked = blocked
        controller.apply()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.restore() }

    final class Controller: UIViewController {
        var blocked: Bool
        private var visible = false
        private var waitingForTransition = false
        private var saved: [(gesture: UIGestureRecognizer, enabled: Bool)] = []

        init(blocked: Bool) {
            self.blocked = blocked
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            visible = true
            // UIKit also updates these recognizers as its navigation transition finishes.
            // Reapply once after that update; never replace the navigation or gesture delegates.
            Task { @MainActor [weak self] in self?.apply() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            visible = false
            restore()
            super.viewWillDisappear(animated)
        }

        func apply() {
            guard visible else { return }
            guard blocked, let navigationController, navigationController.viewControllers.count == 2 else {
                restore()
                return
            }
            // Do not cancel an active gesture or save UIKit's temporary disabled state during a push.
            if let transition = navigationController.transitionCoordinator {
                guard !transition.isInteractive, !waitingForTransition else { return }
                waitingForTransition = true
                transition.animate(alongsideTransition: nil) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.waitingForTransition = false
                        self?.apply()
                    }
                }
                return
            }
            var gestures = [navigationController.interactivePopGestureRecognizer].compactMap { $0 }
            if #available(iOS 26.0, *), let content = navigationController.interactiveContentPopGestureRecognizer {
                gestures.append(content)
            }
            for gesture in gestures {
                if !saved.contains(where: { $0.gesture === gesture }) { saved.append((gesture, gesture.isEnabled)) }
                gesture.isEnabled = false
            }
        }

        func restore() {
            for entry in saved { entry.gesture.isEnabled = entry.enabled }
            saved = []
        }
    }
}
