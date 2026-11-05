import UIKit

// Tier 1. Only our hover recognizer has a Folio delegate.
@MainActor
final class PencilInput: NSObject, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
  var onAction: ((Bool) -> Void)?
  var onLog: ((String) -> Void)?
  private weak var host: UIView?
  private var interaction: UIPencilInteraction?
  private var hover: UIHoverGestureRecognizer?
  func attach(to view: UIView) {
    detach()
    host = view
    let interaction = UIPencilInteraction()
    interaction.delegate = self
    view.addInteraction(interaction)
    self.interaction = interaction
    let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
    hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    hover.cancelsTouchesInView = false
    hover.delaysTouchesBegan = false
    hover.delaysTouchesEnded = false
    hover.delegate = self
    view.addGestureRecognizer(hover)
    self.hover = hover
  }
  func detach() {
    if let interaction { host?.removeInteraction(interaction) }
    if let hover { host?.removeGestureRecognizer(hover) }
    interaction = nil
    hover = nil
  }
  func pencilInteraction(
    _ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap
  ) {
    onAction?(false)
  }
  func pencilInteraction(
    _ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
  ) {
    onLog?("Pencil squeeze phase=\(squeeze.phase.rawValue) [Tier 1]")
    if squeeze.phase == .ended { onAction?(true) }
  }
  @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
    let point = recognizer.location(in: host)
    onLog?("Pencil hover phase=\(recognizer.state.rawValue) xy=\(point.x),\(point.y) [Tier 1]")
  }
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool { true }
}
