import SwiftUI
import UIKit

/// Direction is checked before claiming the gesture. No second native pager competes with this pan.
struct HorizontalPanCapture: UIGestureRecognizerRepresentable {
    var onPan: (CGFloat, CGFloat, Bool) -> Void
    var excludesHorizontalScrollViews = true

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = context.coordinator
        context.coordinator.excludesHorizontalScrollViews = excludesHorizontalScrollViews
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.excludesHorizontalScrollViews = excludesHorizontalScrollViews
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // Window coordinates stay stable while the page or panel moves under the finger.
        let translation = recognizer.translation(in: recognizer.view?.window).x
        let velocity = recognizer.velocity(in: recognizer.view?.window).x
        switch recognizer.state {
        case .began, .changed: onPan(translation, velocity, false)
        case .ended: onPan(translation, velocity, true)
        case .cancelled, .failed: onPan(0, 0, true)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var excludesHorizontalScrollViews = true
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view?.window)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view, current !== gesture.view {
                if excludesHorizontalScrollViews, let scroll = current as? UIScrollView,
                   scroll.contentSize.width > scroll.bounds.width + 2 { return false }
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Once horizontal paging starts, vertical scrolling must not move the old page.
            false
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}
