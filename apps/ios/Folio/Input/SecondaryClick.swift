import UIKit

/// Tier 1. WKWebView on iPadOS does not deliver trackpad/mouse secondary clicks to the page as a
/// right button, so Figma never opens its context menu. A secondary-button tap recognizer outside
/// the web view (it would otherwise be deferred and failed by WebKit) reports the click point.
/// Indirect pointer only; never cancels or delays touches. Control-click is left to the page.
@MainActor
final class SecondaryClick: NSObject, UIGestureRecognizerDelegate {
  private(set) weak var host: UIView?
  private var recognizer: UITapGestureRecognizer?
  var eligible: (() -> Bool)?
  var onClick: ((CGPoint) -> Void)?
  var log: ((String) -> Void)?

  func attach(to host: UIView) {
    guard self.host !== host else { return }
    detach()
    self.host = host
    let tap = UITapGestureRecognizer(target: self, action: #selector(clicked(_:)))
    tap.buttonMaskRequired = .secondary
    tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
    tap.cancelsTouchesInView = false
    tap.delaysTouchesBegan = false
    tap.delaysTouchesEnded = false
    tap.delegate = self
    host.addGestureRecognizer(tap)
    recognizer = tap
  }

  func detach() {
    if let recognizer { host?.removeGestureRecognizer(recognizer) }
    recognizer = nil
    host = nil
  }

  @objc private func clicked(_ tap: UITapGestureRecognizer) {
    guard tap.state == .ended, let view = tap.view else { return }
    guard eligible?() == true else {
      log?("attempt rejected reason=native-ineligible")
      return
    }
    // Figma decides what Control-click means (its own preference); do not turn it into a right click.
    if tap.modifierFlags.contains(.control) {
      log?("attempt rejected reason=control-click")
      return
    }
    onClick?(tap.location(in: view))
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool { true }
}
