import SwiftUI
import UIKit

/// The left-edge swipe that goes back (design §8.9), on a pushed screen that draws its own pixel header and hides the
/// navigation bar: with the bar hidden, the navigation controller's own delegate refuses its interactive pop. Put it
/// behind such a screen (`.background(EdgeSwipeBack())`).
///
/// While the screen is on top, the pop gesture is on and its delegate is this helper: the swipe may begin whenever
/// there is a screen to go back to, and scroll views' pans wait for it (it fails at once unless the touch starts at
/// the left edge, so a horizontal scroll row still scrolls, and the Critter stages are touched as before). When the
/// screen goes away (popped, or covered) the gesture gets its own delegate back, so the root screen never swipes and
/// nothing outlives the screen; when it comes back, this takes over again. At most one is ever installed.
struct EdgeSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        /// The pop gesture this stands in for while its screen is on top.
        private weak var gesture: UIGestureRecognizer?
        /// That gesture's own delegate, given back on the way out (UIKit keeps it alive).
        private weak var original: (any UIGestureRecognizerDelegate)?

        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            uninstall()
        }

        private func install() {
            guard gesture == nil, let pop = navigationController?.interactivePopGestureRecognizer,
                  pop.delegate !== self
            else { return }
            #if DEBUG
            let wasEnabled = pop.isEnabled
            let refused = pop.delegate?.gestureRecognizerShouldBegin?(pop) == false
            #endif
            original = pop.delegate
            gesture = pop
            pop.delegate = self
            pop.isEnabled = true
            #if DEBUG
            let screens = navigationController?.viewControllers.count ?? 0
            let verdict = gestureRecognizerShouldBegin(pop) ? "allows" : "refuses"
            TraceLog.nav(
                "edge swipe installed: \(screens) screens; before: enabled \(wasEnabled), UIKit's delegate would "
                    + "\(refused ? "refuse" : "allow") the swipe; now: enabled \(pop.isEnabled), this one \(verdict) it"
            )
            // The push may still be finishing as the screen appears; a swipe comes later.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.gesture === pop else { return }
                let verdict = self.gestureRecognizerShouldBegin(pop) ? "allows" : "refuses"
                TraceLog.nav("0.5 s later: this one \(verdict) the swipe")
            }
            #endif
        }

        private func uninstall() {
            guard let pop = gesture else { return }
            if pop.delegate === self { pop.delegate = original }
            gesture = nil
            original = nil
            #if DEBUG
            let owner = pop.delegate.map { "\(type(of: $0))" } ?? "none"
            TraceLog.nav("edge swipe given back: the gesture's delegate is UIKit's again (\(owner))")
            #endif
        }

        // MARK: UIGestureRecognizerDelegate

        /// There is a screen to go back to, and no push or pop is under way (one begun mid-transition corrupts the
        /// stack).
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigation = navigationController, navigation.transitionCoordinator == nil else { return false }
            return navigation.viewControllers.count > 1
        }

        /// A scroll view's pan starts only once the edge swipe has failed (at once, for a touch away from the edge).
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other.view is UIScrollView
        }
    }
}
