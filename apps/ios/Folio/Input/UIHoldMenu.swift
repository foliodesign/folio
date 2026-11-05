import UIKit

/// Tier 1. A native long press (0.5 s, 12 pt) for finger/Pencil in Figma UI, like a native long
/// press: the menu opens while the contact is still down; moving past 12 pt afterwards closes it so
/// the drag proceeds. Installed outside the WKWebView (like MultiFingerTap) so WebKit's touch
/// deferral and long-press drag lift cannot fail or cancel it. Never blocks or delays touches.
@MainActor
final class UIHoldMenu: NSObject, UIGestureRecognizerDelegate {
  enum Phase: String { case began, moved, ended }

  private(set) weak var host: UIView?
  private var recognizer: UILongPressGestureRecognizer?
  private var start: CGPoint = .zero
  private var moved = false
  var eligible: (() -> Bool)?
  /// Point in host coordinates (the down point for every phase).
  var onPhase: ((Phase, CGPoint) -> Void)?
  var log: ((String) -> Void)?

  func attach(to host: UIView) {
    guard self.host !== host else { return }
    detach()
    self.host = host
    let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
    press.minimumPressDuration = 0.5
    press.allowableMovement = 12
    press.allowedTouchTypes = [
      NSNumber(value: UITouch.TouchType.direct.rawValue),
      NSNumber(value: UITouch.TouchType.pencil.rawValue),
    ]
    press.cancelsTouchesInView = false
    press.delaysTouchesBegan = false
    press.delaysTouchesEnded = false
    press.delegate = self
    host.addGestureRecognizer(press)
    recognizer = press
  }

  func detach() {
    if let recognizer { host?.removeGestureRecognizer(recognizer) }
    recognizer = nil
    host = nil
  }

  @objc private func pressed(_ press: UILongPressGestureRecognizer) {
    guard let view = press.view else { return }
    switch press.state {
    case .began:
      start = press.location(in: view)
      moved = false
      guard eligible?() == true else {
        log?("attempt rejected reason=native-ineligible")
        return
      }
      onPhase?(.began, start)
    case .changed:
      let p = press.location(in: view)
      guard !moved, hypot(p.x - start.x, p.y - start.y) > 12 else { return }
      moved = true
      onPhase?(.moved, start)
    case .ended, .cancelled:
      onPhase?(.ended, start)
    default: return
    }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  { eligible?() == true }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool { true }
}
