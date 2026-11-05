import UIKit

/// A single tab: a flat full-height segment with a trailing zoom-scaled 1 pt divider, file icon,
/// middle-truncated title, and a close × on hover/selected.
@MainActor
final class ChromeTabView: UIControl {
  var tabID: UUID?
  var onClose: (() -> Void)?
  var menuProvider: (() -> UIMenu?)?
  private(set) var isPinned = false
  var isCurrent = false {
    didSet { if oldValue != isCurrent { refresh() } }
  }
  var interfaceScale: CGFloat = 1 {
    didSet { if oldValue != interfaceScale { refresh() } }
  }
  private let iconOnly: Bool
  private let fill = UIView()
  private var fillBottom: NSLayoutConstraint!
  private let divider = UIView()
  private var dividerWidth: NSLayoutConstraint!
  private let icon = UIImageView()
  private var iconWidth: NSLayoutConstraint!
  private var iconHeight: NSLayoutConstraint!
  private var iconLeading: NSLayoutConstraint?
  private var iconCenter: NSLayoutConstraint?
  private var titleConstraints: [NSLayoutConstraint] = []
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let label = UILabel()
  private let close = ChromeHitButton(type: .custom)
  private var title = ""
  private var symbol = ""
  private var hovering = false {
    didSet { if oldValue != hovering { refresh() } }
  }

  init(iconOnly: Bool) {
    self.iconOnly = iconOnly
    super.init(frame: .zero)
    for view in [fill, divider] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.isUserInteractionEnabled = false
      addSubview(view)
    }
    divider.backgroundColor = ChromePalette.divider

    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.contentMode = iconOnly ? .center : .scaleAspectFit
    icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: iconOnly ? 16 : 13, weight: .light)
    icon.setContentHuggingPriority(.required, for: .horizontal)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    spinner.transform = CGAffineTransform(scaleX: 0.65, y: 0.65)
    addSubview(icon)
    addSubview(spinner)

    iconWidth = icon.widthAnchor.constraint(equalToConstant: 16)
    iconHeight = icon.heightAnchor.constraint(equalToConstant: 16)
    dividerWidth = divider.widthAnchor.constraint(equalToConstant: 1)
    fillBottom = fill.bottomAnchor.constraint(equalTo: bottomAnchor)
    var constraints = [
      fill.leadingAnchor.constraint(equalTo: leadingAnchor),
      fill.trailingAnchor.constraint(equalTo: trailingAnchor),
      fill.topAnchor.constraint(equalTo: topAnchor),
      fillBottom!,
      divider.trailingAnchor.constraint(equalTo: trailingAnchor),
      divider.topAnchor.constraint(equalTo: topAnchor),
      divider.bottomAnchor.constraint(equalTo: bottomAnchor),
      dividerWidth!,
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconWidth!,
      iconHeight!,
      spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
    ]
    if iconOnly {
      constraints.append(icon.centerXAnchor.constraint(equalTo: centerXAnchor))
    } else {
      label.translatesAutoresizingMaskIntoConstraints = false
      label.lineBreakMode = .byTruncatingMiddle
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      close.translatesAutoresizingMaskIntoConstraints = false
      var configuration = UIButton.Configuration.plain()
      configuration.image = UIImage(systemName: "xmark")
      configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
        pointSize: 11, weight: .light)
      configuration.contentInsets = .zero
      close.configuration = configuration
      // Full-height hit area around the close glyph.
      close.configurationUpdateHandler = { button in
        var configuration = button.configuration
        let active = button.isHovered || button.isHighlighted
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = active ? ChromePalette.closeFill : .clear
        background.cornerRadius = 4
        background.backgroundInsets = NSDirectionalEdgeInsets(
          top: 12, leading: 4, bottom: 12, trailing: 4)
        configuration?.background = background
        configuration?.baseForegroundColor =
          active ? ChromePalette.primaryText : ChromePalette.secondaryText
        button.configuration = configuration
      }
      close.accessibilityLabel = "Close tab"
      close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
      addSubview(label)
      addSubview(close)
      iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
      iconCenter = icon.centerXAnchor.constraint(equalTo: centerXAnchor)
      titleConstraints = [
        label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
        label.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -2),
      ]
      constraints +=
        titleConstraints + [
          iconLeading!,
          label.centerYAnchor.constraint(equalTo: centerYAnchor),
          close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
          close.topAnchor.constraint(equalTo: topAnchor),
          close.bottomAnchor.constraint(equalTo: bottomAnchor),
          close.widthAnchor.constraint(equalToConstant: 28),
        ]
      accessibilityCustomActions = [
        UIAccessibilityCustomAction(name: "Close tab") { [weak self] _ in
          self?.onClose?()
          return true
        }
      ]
    }
    NSLayoutConstraint.activate(constraints)

    isAccessibilityElement = true
    isContextMenuInteractionEnabled = true
    let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
    addGestureRecognizer(hover)
    registerForTraitChanges([
      UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self,
      UITraitDisplayScale.self,
    ]) { (view: ChromeTabView, _) in
      view.refresh()
    }
    refresh()
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic tab") }

  /// A flat, full-height icon segment (e.g. '+' or ⋯) with a hover fill.
  static func segmentButton(_ symbol: String, label: String) -> UIButton {
    var configuration = UIButton.Configuration.plain()
    configuration.image = UIImage(systemName: symbol)
    configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 15, weight: .light)
    configuration.contentInsets = .zero
    let button = ChromeHitButton(configuration: configuration)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.configurationUpdateHandler = { button in
      var configuration = button.configuration
      let active = button.isHovered || button.isHighlighted
      var background = UIBackgroundConfiguration.clear()
      background.backgroundColor = active ? ChromePalette.hover : .clear
      configuration?.background = background
      configuration?.baseForegroundColor = active ? ChromePalette.primaryText : ChromePalette.icon
      button.configuration = configuration
    }
    button.accessibilityLabel = label
    return button
  }

  func configure(title: String, symbol: String, pinned: Bool, loading: Bool) {
    if self.title != title {
      self.title = title
      label.text = title
    }
    if self.symbol != symbol {
      self.symbol = symbol
      icon.image = ChromeFileIcon.image(symbol)
      refresh()
    }
    if isPinned != pinned {
      isPinned = pinned
      if !iconOnly {
        iconLeading?.isActive = !pinned
        iconCenter?.isActive = pinned
        if pinned {
          NSLayoutConstraint.deactivate(titleConstraints)
        } else {
          NSLayoutConstraint.activate(titleConstraints)
        }
        label.isHidden = pinned
        accessibilityCustomActions =
          pinned
          ? []
          : [
            UIAccessibilityCustomAction(name: "Close tab") { [weak self] _ in
              self?.onClose?()
              return true
            }
          ]
      }
      refresh()
    }
    if loading != spinner.isAnimating {
      if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
      icon.alpha = loading ? 0 : 1
    }
    accessibilityLabel = iconOnly ? "Home" : title
    accessibilityValue = pinned ? "Pinned" : nil
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    var target = bounds.insetBy(dx: 0, dy: -max(0, (44 - bounds.height) / 2))
    if iconOnly || isPinned { target.size.width = max(44, target.width) }
    return target.contains(point)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled,
      self.point(inside: point, with: event)
    else { return nil }
    if close.isUserInteractionEnabled, close.alpha > 0.01,
      close.point(inside: convert(point, to: close), with: event)
    {
      return close
    }
    return super.hitTest(point, with: event) ?? self
  }

  override var isHighlighted: Bool {
    didSet { if oldValue != isHighlighted { refresh() } }
  }

  @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
    switch recognizer.state {
    case .began, .changed: hovering = true
    default: hovering = false
    }
  }

  private func updateSizing() {
    guard !iconOnly else { return }
    let size = 16 * interfaceScale
    iconWidth.constant = size
    iconHeight.constant = size
    icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 13 * interfaceScale, weight: .light)
    let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
      for: .systemFont(
        ofSize: max(13, 15 * interfaceScale), weight: isCurrent ? .medium : .regular),
      maximumPointSize: max(13, 18 * interfaceScale), compatibleWith: traitCollection)
    label.font = font.withSize(max(13, font.pointSize))
  }

  private func refresh() {
    updateSizing()
    // Only the selected tab covers the bar's bottom border.
    let pixels = max(1, traitCollection.displayScale)
    let thickness = max(1, (interfaceScale * pixels).rounded()) / pixels
    dividerWidth.constant = thickness
    fillBottom.constant = isCurrent ? 0 : -thickness
    fill.backgroundColor =
      isCurrent
      ? ChromePalette.selectedTab
      : hovering || isHighlighted ? ChromePalette.hover : ChromePalette.inactiveTab
    let tint = isCurrent || hovering ? ChromePalette.primaryText : ChromePalette.secondaryText
    // The selected file's icon is blue (green in Dev Mode); Home and inactive icons stay grey
    // (white when current).
    let active = symbol == ChromeFileIcon.dev ? ChromePalette.devGreen : ChromePalette.activeIcon
    icon.tintColor =
      isCurrent
      ? (iconOnly ? ChromePalette.primaryText : active)
      : hovering ? ChromePalette.primaryText : ChromePalette.icon
    label.textColor = tint
    spinner.color = tint
    let showClose = !iconOnly && !isPinned && (isCurrent || hovering)
    close.alpha = showClose ? 1 : 0
    close.isUserInteractionEnabled = showClose
    accessibilityTraits = isCurrent ? [.button, .selected] : .button
  }

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let menu = menuProvider?() else { return nil }
    return UIContextMenuConfiguration(actionProvider: { _ in menu })
  }
}

/// Invisible touch padding around compact bar controls.
@MainActor
private final class ChromeHitButton: UIButton {
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(
      dx: -max(0, (44 - bounds.width) / 2),
      dy: -max(0, (44 - bounds.height) / 2)
    ).contains(point)
  }
}
