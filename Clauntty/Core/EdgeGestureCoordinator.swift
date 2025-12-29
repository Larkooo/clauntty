import UIKit
import Combine

/// Coordinates edge swipe gestures with terminal gestures.
/// Holds references to window-level edge gesture recognizers so terminal views
/// can establish proper gesture dependencies (require-to-fail relationships).
@MainActor
class EdgeGestureCoordinator: ObservableObject {
    /// Left edge pan gesture (swipe right to go back)
    @Published private(set) var leftEdgeGesture: UIScreenEdgePanGestureRecognizer?

    /// Right edge pan gesture (swipe left for next tab)
    @Published private(set) var rightEdgeGesture: UIScreenEdgePanGestureRecognizer?

    /// Register edge gestures (called by EdgeSwipeUIView after moving to window)
    func registerEdgeGestures(left: UIScreenEdgePanGestureRecognizer, right: UIScreenEdgePanGestureRecognizer) {
        leftEdgeGesture = left
        rightEdgeGesture = right
    }

    /// Unregister edge gestures (called when EdgeSwipeUIView is removed)
    func unregisterEdgeGestures() {
        leftEdgeGesture = nil
        rightEdgeGesture = nil
    }
}
