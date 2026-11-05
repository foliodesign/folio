import UIKit

// Observes public UITouch metadata without recognizing, cancelling or delaying browser gestures.
@MainActor
final class InputObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
  private var activeTouches: Set<UITouch> = []
  var onTouch: ((UITouch, UIView) -> Void)?

  init(onTouch: @escaping (UITouch, UIView) -> Void) {
    self.onTouch = onTouch
    super.init(target: nil, action: nil)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
    delegate = self
    allowedTouchTypes = [
      UITouch.TouchType.direct.rawValue, UITouch.TouchType.pencil.rawValue,
      UITouch.TouchType.indirectPointer.rawValue,
    ].map { NSNumber(value: $0) }
  }
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    activeTouches.formUnion(touches)
    record(touches)
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { record(touches) }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    record(touches)
    activeTouches.subtract(touches)
    if activeTouches.isEmpty {
      state = .failed
    }
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    record(touches)
    activeTouches.subtract(touches)
    if activeTouches.isEmpty { state = .failed }
  }
  override func reset() {
    activeTouches.removeAll()
    super.reset()
  }
  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
    false
  }
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool { true }
  private func record(_ touches: Set<UITouch>) {
    guard let view else { return }
    for touch in touches { onTouch?(touch, view) }
  }
}
