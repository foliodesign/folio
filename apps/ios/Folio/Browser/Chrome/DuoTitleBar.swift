import UIKit

/// iPhone Duo top bar for the column layouts (maintainer, 2026-11-11, after Reddit's Duo app):
/// a short opaque bar whose window controls are Liquid Glass shapes in one row: Home, the tab
/// title with its chevron (opens the tab list), then the open-file count and ⋯ in one capsule.
/// Edit commands live in the side column (`SideRailView`). Height and the row's centre follow
/// Freeform's title bar on the Duo: about 72 pt from the window's top, controls centred 46 pt down.
@MainActor
final class DuoTitleBar: UIView {
  static let height: CGFloat = 72
  static let rowCentre: CGFloat = 46
  static let control: CGFloat = 44
  private static let gap: CGFloat = 8

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
  private let homeGlass = SideRailView.glass()
  private let titleGlass = SideRailView.glass()
  private let tabsGlass = SideRailView.glass()
  private let home = SideRailView.button("house", label: "Home")
  private let title = UIControl()
  private let titleLabel = UILabel()
  private let chevron = UIImageView(
    image: UIImage(
      systemName: "chevron.down",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let count = SideRailCountButton()
  private let more = SideRailView.button("ellipsis", label: "More")

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = ChromePalette.bar
    accessibilityIdentifier = "duo-title-bar"
    hairline.backgroundColor = ChromePalette.divider
    addSubview(hairline)
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
    homeGlass.contentView.addSubview(home)
    titleGlass.contentView.addSubview(title)
    tabsGlass.contentView.addSubview(count)
    tabsGlass.contentView.addSubview(more)
    for glass in [homeGlass, titleGlass, tabsGlass] { addSubview(glass) }
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
    homeGlass.frame = CGRect(x: insets.left, y: y, width: size, height: size)
    home.frame = homeGlass.bounds
    let tabsWidth = size * 2
    tabsGlass.frame = CGRect(
      x: bounds.width - insets.right - tabsWidth, y: y, width: tabsWidth, height: size)
    count.frame = CGRect(x: 0, y: 0, width: size, height: size)
    more.frame = CGRect(x: size, y: 0, width: size, height: size)
    // The title capsule hugs its text, up to the room between Home and the count.
    let left = homeGlass.frame.maxX + Self.gap
    let room = max(size, tabsGlass.frame.minX - Self.gap - left)
    let spin: CGFloat = spinner.isAnimating ? 22 : 0
    let text = titleLabel.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: size)).width
    let chrome: CGFloat = 16 + spin + 6 + 22 + 10
    let width = min(room, ceil(text) + chrome)
    titleGlass.frame = CGRect(x: left, y: y, width: width, height: size)
    title.frame = titleGlass.bounds
    var x: CGFloat = 16
    spinner.frame = CGRect(x: x - 4, y: 0, width: 22, height: size)
    x += spin
    let labelWidth = max(0, width - x - 6 - 22 - 10)
    titleLabel.frame = CGRect(x: x, y: 0, width: labelWidth, height: size)
    chevron.frame = CGRect(x: x + labelWidth + 6, y: (size - 22) / 2, width: 22, height: 22)
  }
}
