import UIKit

/// iPhone: native grab bar on top of the sidebar sheet. Folio places Figma's panel below it
/// (phone-layout.ts) and drags change the sheet height as a fraction of the browser height.
@MainActor
final class PhoneSheetHandle: UIView {
  static let height: CGFloat = 20
  static let range: ClosedRange<Double> = 0.25...0.85

  enum DragPhase: String { case begin, move, end }

  /// Explicit boundaries let the page commit layout only when dragging ends.
  var onFraction: ((Double, DragPhase) -> Void)?

  private let grabber = UIView()
  private let drag = UIPanGestureRecognizer()
  private var startFraction = 0.5
  var fraction = 0.5
  /// Browser height the fraction refers to, set by the owner on layout.
  var referenceHeight: CGFloat = 0

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = ChromePalette.bar
    layer.cornerRadius = 10
    layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    layer.borderWidth = 1
    grabber.backgroundColor = ChromePalette.icon.withAlphaComponent(0.6)
    grabber.layer.cornerRadius = 2.5
    grabber.translatesAutoresizingMaskIntoConstraints = false
    addSubview(grabber)
    NSLayoutConstraint.activate([
      grabber.centerXAnchor.constraint(equalTo: centerXAnchor),
      grabber.centerYAnchor.constraint(equalTo: centerYAnchor),
      grabber.widthAnchor.constraint(equalToConstant: 36),
      grabber.heightAnchor.constraint(equalToConstant: 5),
    ])
    isAccessibilityElement = true
    accessibilityLabel = "Panel height"
    accessibilityTraits = .adjustable
    drag.addTarget(self, action: #selector(pan(_:)))
    addGestureRecognizer(drag)
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
      self.layer.borderColor =
        ChromePalette.divider.resolvedColor(with: self.traitCollection)
        .cgColor
    }
    layer.borderColor = ChromePalette.divider.resolvedColor(with: traitCollection).cgColor
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic sheet handle") }

  /// Fades the bar out and disables dragging while a Figma popover is open over the sheet.
  func setCovered(_ covered: Bool, animated: Bool) {
    drag.isEnabled = !covered
    isUserInteractionEnabled = !covered
    accessibilityElementsHidden = covered
    let alpha: CGFloat = covered ? 0 : 1
    guard animated, !UIAccessibility.isReduceMotionEnabled else {
      self.alpha = alpha
      return
    }
    UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) {
      self.alpha = alpha
    }
  }

  /// 44 pt tall touch target around the 20 pt bar.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: 0, dy: -12).contains(point)
  }

  @objc private func pan(_ gesture: UIPanGestureRecognizer) {
    guard let container = superview, referenceHeight > 0 else { return }
    if gesture.state == .began { startFraction = fraction }
    let delta = Double(gesture.translation(in: container).y / referenceHeight)
    let phase: DragPhase
    switch gesture.state {
    case .began: phase = .begin
    case .changed: phase = .move
    case .ended, .cancelled, .failed: phase = .end
    default: return
    }
    set(startFraction - delta, phase: phase)
  }

  override func accessibilityIncrement() { set(fraction + 0.1) }
  override func accessibilityDecrement() { set(fraction - 0.1) }

  private func set(_ value: Double, phase: DragPhase = .end) {
    let clamped = min(Self.range.upperBound, max(Self.range.lowerBound, value))
    guard clamped != fraction || phase != .move else { return }
    fraction = clamped
    accessibilityValue = "\(Int((clamped * 100).rounded())) percent"
    onFraction?(clamped, phase)
  }
}
