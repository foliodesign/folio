import UIKit

/// iPhone: a floating row of the characters iOS's decimal keypad lacks, shown above the keyboard
/// while a numeric field in the panel sheet has focus (phone-layout.ts). Figma's fields accept
/// signs, units and expressions; each key is typed into the focused field by the page through
/// the standard insertText command. Buttons never take first responder, so the keyboard stays.
@MainActor
final class PhoneKeyRow: UIView {
  static let height: CGFloat = 44

  /// Fixed key ids understood by phone-layout.ts.
  var onKey: ((String) -> Void)?

  private static let keys: [(id: String, title: String, label: String)] = [
    ("sign", "±", "Change sign"),
    ("minus", "−", "Minus"),
    ("plus", "+", "Plus"),
    ("times", "×", "Times"),
    ("divide", "÷", "Divide"),
    ("percent", "%", "Percent"),
    ("point", ".", "Decimal point"),
  ]

  private let haptics = UIImpactFeedbackGenerator(style: .light)
  private(set) var shown = false

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    accessibilityIdentifier = "phone-key-row"
    backgroundColor = ChromePalette.bar
    layer.cornerRadius = 12
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOffset = CGSize(width: 0, height: 2)
    layer.shadowRadius = 8
    layer.shadowOpacity = 0.25
    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.distribution = .fillEqually
    stack.spacing = 4
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      heightAnchor.constraint(equalToConstant: Self.height),
    ])
    for key in Self.keys {
      var config = UIButton.Configuration.plain()
      config.baseForegroundColor = ChromePalette.primaryText
      config.background.cornerRadius = 8
      config.attributedTitle = AttributedString(
        key.title,
        attributes: AttributeContainer([
          .font: UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .regular)
        ]))
      let button = UIButton(configuration: config)
      button.configurationUpdateHandler = { button in
        button.configuration?.background.backgroundColor =
          button.isHighlighted ? ChromePalette.hover : ChromePalette.segmentTrack
      }
      button.accessibilityLabel = key.label
      button.addAction(
        UIAction { [weak self] _ in
          self?.haptics.impactOccurred()
          self?.onKey?(key.id)
        }, for: .touchUpInside)
      stack.addArrangedSubview(button)
    }
    isHidden = true
    alpha = 0
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
      self.updateEdge()
    }
    updateEdge()
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic key row") }

  private func updateEdge() {
    layer.borderColor = ChromePalette.floatingEdge.resolvedColor(with: traitCollection).cgColor
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
  }

  /// Shown or hidden at once, with the keyboard; it rides on the keyboard layout guide.
  func setShown(_ visible: Bool) {
    guard visible != shown else { return }
    shown = visible
    UIView.performWithoutAnimation {
      alpha = visible ? 1 : 0
      isHidden = !visible
    }
  }
}
