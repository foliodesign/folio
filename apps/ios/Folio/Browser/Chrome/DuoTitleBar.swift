import UIKit

/// iPhone Duo top bar for the column layouts: Home, the tab title with its chevron (opens the tab
/// list), then the open-file count and ⋯. Edit commands live in the side column (`SideRailView`).
///
/// Plain, like the iPhone's compact top bar (maintainer, 2026-11-11: no Liquid Glass here): flat
/// icons on the opaque bar, a hover fill only while pressed. Sizes follow Freeform's title bar on
/// the Duo: about 72 pt from the window's top, 44 pt controls centred 46 pt down.
@MainActor
final class DuoTitleBar: UIView {
  static let height: CGFloat = 72
  static let rowCentre: CGFloat = 46
  static let control: CGFloat = 44
  private static let gap: CGFloat = 8
  /// Corner of the pressed fill behind a control.
  static let pressedRadius: CGFloat = 10

  var onHome: (() -> Void)?
  var onTabs: (() -> Void)?
  /// The ⋯ menu, opened below the given button.
  var onMore: ((UIView) -> Void)?

  /// Distance of the row from each window edge: clear of the display's corner, and of the
  /// system column when it shares this edge.
  var insets: (left: CGFloat, right: CGFloat) = (18, 18) {
    didSet { if insets != oldValue { setNeedsLayout() } }
  }

  private let hairline = UIView()
  private let home = DuoTitleBar.button("house", label: "Home")
  private let title = DuoTitleControl()
  private let titleLabel = UILabel()
  private let chevron = UIImageView(
    image: UIImage(
      systemName: "chevron.down",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let count = SideRailCountButton()
  private let more = DuoTitleBar.button("ellipsis", label: "More")

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = ChromePalette.bar
    accessibilityIdentifier = "duo-title-bar"
    hairline.backgroundColor = ChromePalette.divider
    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel.textColor = ChromePalette.primaryText
    titleLabel.lineBreakMode = .byTruncatingTail
    chevron.tintColor = ChromePalette.icon
    chevron.contentMode = .center
    spinner.hidesWhenStopped = true
    spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
    for view in [spinner, titleLabel, chevron] as [UIView] {
      view.isUserInteractionEnabled = false
      title.addSubview(view)
    }
    title.accessibilityTraits = .button
    title.accessibilityHint = "Shows open tabs"
    title.isAccessibilityElement = true
    for view in [hairline, home, title, count, more] as [UIView] { addSubview(view) }
    home.addAction(UIAction { [weak self] _ in self?.onHome?() }, for: .touchUpInside)
    title.addAction(UIAction { [weak self] _ in self?.onTabs?() }, for: .touchUpInside)
    count.addAction(UIAction { [weak self] _ in self?.onTabs?() }, for: .touchUpInside)
    more.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.onMore?(self.more)
      }, for: .touchUpInside)
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic title bar") }

  func update(title text: String, homeSelected: Bool, documentCount: Int, loading: Bool) {
    titleLabel.text = text
    title.accessibilityLabel = text
    home.configuration?.image = SideRailView.image(homeSelected ? "house.fill" : "house")
    home.isSelected = homeSelected
    home.accessibilityTraits = homeSelected ? [.button, .selected] : .button
    count.update(count: documentCount, loading: false)
    if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let scale = max(1, traitCollection.displayScale)
    hairline.frame = CGRect(
      x: 0, y: bounds.maxY - 1 / scale, width: bounds.width, height: 1 / scale)
    let size = Self.control
    let y = Self.rowCentre - size / 2
    home.frame = CGRect(x: insets.left, y: y, width: size, height: size)
    more.frame = CGRect(x: bounds.width - insets.right - size, y: y, width: size, height: size)
    count.frame = more.frame.offsetBy(dx: -size, dy: 0)
    // The title hugs its text, up to the room between Home and the count.
    let left = home.frame.maxX + Self.gap
    let room = max(size, count.frame.minX - Self.gap - left)
    let spin: CGFloat = spinner.isAnimating ? 22 : 0
    let text = titleLabel.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: size)).width
    let chrome: CGFloat = 10 + spin + 4 + 22 + 6
    let width = min(room, ceil(text) + chrome)
    title.frame = CGRect(x: left, y: y, width: width, height: size)
    var x: CGFloat = 10
    spinner.frame = CGRect(x: x - 4, y: 0, width: 22, height: size)
    x += spin
    let labelWidth = max(0, width - x - 4 - 22 - 6)
    titleLabel.frame = CGRect(x: x, y: 0, width: labelWidth, height: size)
    chevron.frame = CGRect(x: x + labelWidth + 4, y: (size - 22) / 2, width: 22, height: 22)
  }

  /// A flat icon button: the chrome's icon colour, white (black in light mode) when pressed or
  /// selected, on a rounded hover fill while pressed. Glyphs come from the column's icon system,
  /// so they match the side column in size.
  private static func button(_ symbol: String, label: String) -> UIButton {
    var configuration = UIButton.Configuration.plain()
    configuration.image = SideRailView.image(symbol)
    configuration.contentInsets = .zero
    configuration.background.cornerRadius = pressedRadius
    let button = UIButton(configuration: configuration)
    button.configurationUpdateHandler = { button in
      var configuration = button.configuration
      configuration?.background.backgroundColor =
        button.isHighlighted ? ChromePalette.hover : .clear
      configuration?.baseForegroundColor =
        button.isHighlighted || button.isSelected ? ChromePalette.primaryText : ChromePalette.icon
      button.configuration = configuration
    }
    button.accessibilityLabel = label
    return button
  }
}

/// The title's tap area, with the same pressed fill as the buttons.
@MainActor
private final class DuoTitleControl: UIControl {
  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = DuoTitleBar.pressedRadius
    layer.cornerCurve = .continuous
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic title control") }

  override var isHighlighted: Bool {
    didSet { backgroundColor = isHighlighted ? ChromePalette.hover : .clear }
  }
}
