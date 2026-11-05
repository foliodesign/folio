import UIKit

/// Figma-style hover and press fill for tappable rows.
class DeveloperToolsPressable: UIControl {
  private var hovering = false
  var restingColor: UIColor { .clear }

  override init(frame: CGRect) {
    super.init(frame: frame)
    addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
    updateFill()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isHighlighted: Bool { didSet { updateFill() } }
  @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
    hovering = recognizer.state == .began || recognizer.state == .changed
    updateFill()
  }
  func updateFill() {
    backgroundColor =
      hovering || isHighlighted ? DeveloperToolsController.Palette.hover : restingColor
  }
}

/// Sidebar item: fixed 16 pt icon frame at a fixed inset, so every title starts at the same x.
final class DeveloperToolsSidebarRow: DeveloperToolsPressable {
  static let inset: CGFloat = 8
  static let icon: CGFloat = 16
  static let textInset: CGFloat = inset + icon + 8
  private let iconView = UIImageView()
  private let titleLabel = UILabel()

  var isCurrent = false {
    didSet {
      accessibilityTraits = isCurrent ? [.button, .selected] : .button
      iconView.tintColor =
        isCurrent
        ? DeveloperToolsController.Palette.text
        : DeveloperToolsController.Palette.secondary
      updateFill()
    }
  }
  override var restingColor: UIColor {
    isCurrent ? DeveloperToolsController.Palette.selected : .clear
  }

  init(title: String, symbol: String?) {
    super.init(frame: .zero)
    layer.cornerRadius = 5
    iconView.image = symbol.flatMap {
      UIImage(
        systemName: $0,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: Self.icon, weight: .regular))
    }
    iconView.contentMode = .scaleAspectFit
    iconView.tintColor = DeveloperToolsController.Palette.secondary
    titleLabel.text = title
    titleLabel.font = DeveloperToolsController.font(12, .medium)
    titleLabel.textColor = DeveloperToolsController.Palette.text
    for view in [iconView, titleLabel] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 32),
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
      iconView.widthAnchor.constraint(equalToConstant: Self.icon),
      iconView.heightAnchor.constraint(equalToConstant: Self.icon),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    isAccessibilityElement = true
    accessibilityLabel = title
    accessibilityTraits = .button
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Shared Figma-style buttons, also used by the Download Center.
extension DeveloperToolsController {
  /// Blue primary, or grey secondary with a 1 pt border. Hover and press lighten the fill.
  static func smallButton(_ title: String, primary: Bool = false, action: @escaping () -> Void)
    -> UIButton
  {
    var config = UIButton.Configuration.filled()
    config.title = title
    config.titleTextAttributesTransformer = titleFont(11, .medium)
    config.background.strokeWidth = primary ? 0 : 1
    config.background.cornerRadius = 5
    config.cornerStyle = .fixed
    config.contentInsets = .init(top: 5, leading: 10, bottom: 5, trailing: 10)
    let button = UIButton(configuration: config)
    button.configurationUpdateHandler = { button in
      guard var config = button.configuration else { return }
      let lit = button.isHovered || button.isHighlighted
      config.baseBackgroundColor =
        primary
        ? (button.isEnabled ? (lit ? Palette.accentHover : Palette.accent) : Palette.raised)
        : (lit ? Palette.hover : Palette.panel)
      config.baseForegroundColor = button.isEnabled ? Palette.text : Palette.tertiary
      config.background.strokeColor = primary ? .clear : Palette.border
      button.configuration = config
    }
    button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }

  /// 28 pt square icon button with a 12 pt symbol; hover and press show a grey fill.
  static func iconButton(_ symbol: String, label: String, action: @escaping () -> Void)
    -> UIButton
  {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: symbol,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .regular))
    config.background.cornerRadius = 5
    config.contentInsets = .zero
    let button = UIButton(configuration: config)
    button.configurationUpdateHandler = { button in
      guard var config = button.configuration else { return }
      let lit = button.isHovered || button.isHighlighted
      config.background.backgroundColor = lit ? Palette.border : .clear
      config.baseForegroundColor =
        button.isEnabled ? (lit ? Palette.text : Palette.secondary) : Palette.border
      button.configuration = config
    }
    button.accessibilityLabel = label
    button.toolTip = label
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 28),
      button.heightAnchor.constraint(equalToConstant: 28),
    ])
    return button
  }
}
