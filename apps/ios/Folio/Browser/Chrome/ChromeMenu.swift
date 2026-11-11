import UIKit

/// One row of the chrome's ⋯ menu. Data only; `ChromeMenuPresenter` draws it.
/// Add features by appending items to `BrowserChromeView.menuItems`.
struct ChromeMenuItem {
  var title = ""
  /// Muted, right-aligned hint, e.g. a shortcut ("⌃⌘N") or the current value ("100%").
  var hint: String?
  var checked = false
  var enabled = true
  /// Keep the menu open after the action and refresh it (e.g. zoom steps).
  var keepsOpen = false
  var children: [ChromeMenuItem]?
  var action: (() -> Void)?
  private(set) var isSeparator = false

  init(
    title: String, hint: String? = nil, checked: Bool = false, enabled: Bool = true,
    keepsOpen: Bool = false, children: [ChromeMenuItem]? = nil, action: (() -> Void)? = nil
  ) {
    self.title = title
    self.hint = hint
    self.checked = checked
    self.enabled = enabled
    self.keepsOpen = keepsOpen
    self.children = children
    self.action = action
  }

  static var separator: ChromeMenuItem {
    var item = ChromeMenuItem(title: "")
    item.isSeparator = true
    return item
  }

  var isSelectable: Bool { !isSeparator && enabled }
}

extension ChromePalette {
  /// Figma's interface blue (#0D99FF): accents, selection, highlights and switches.
  static let figmaBlue = hex(0x0D99FF)
}

/// Dark, compact popover menu with nested submenus, hover/press highlight and keyboard
/// navigation. Hosted in a full-window overlay that dismisses on outside taps.
/// iPhone (compact): one panel at a time with 44 pt rows; a submenu replaces its parent and
/// starts with a Back row, shortcut hints are left out, and a window resize dismisses the menu.
@MainActor
final class ChromeMenuPresenter: UIView {
  /// Context-menu palette sampled from docs/delivery/reference/figma-context-menu.png;
  /// highlight uses Figma's UI blue.
  static let accent = ChromePalette.figmaBlue
  static let separator = ChromePalette.hex(0x383838)
  static let hint = ChromePalette.hex(0xBBBBBB)

  private let provider: () -> [ChromeMenuItem]
  private var panels: [ChromeMenuPanel] = []
  /// Index of the opened submenu row in each panel, root first.
  private var path: [Int] = []
  private weak var previousResponder: UIView?
  private var dismissing = false
  private let anchor: CGRect
  private let compact: Bool
  /// Opens to the trailing side of the anchor, top-aligned (side rail), instead of below it.
  private let beside: Bool
  private var shownSize: CGSize?

  /// Shows the menu below `anchor` (in `window` coordinates), trailing-aligned.
  @discardableResult
  static func present(
    in window: UIWindow, below anchor: CGRect, compact: Bool = false, beside: Bool = false,
    items: @escaping () -> [ChromeMenuItem]
  ) -> ChromeMenuPresenter {
    let presenter = ChromeMenuPresenter(
      window: window, anchor: anchor, compact: compact, beside: beside, items: items)
    presenter.show()
    return presenter
  }

  private init(
    window: UIWindow, anchor: CGRect, compact: Bool, beside: Bool,
    items: @escaping () -> [ChromeMenuItem]
  ) {
    provider = items
    self.anchor = anchor
    self.compact = compact
    self.beside = beside
    super.init(frame: window.bounds)
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
    previousResponder = BrowserResponderFocus.first(in: window)
    window.addSubview(self)
    let dismissTap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
    dismissTap.cancelsTouchesInView = false
    addGestureRecognizer(dismissTap)
    accessibilityViewIsModal = true
  }

  required init?(coder: NSCoder) { fatalError("Use present(in:below:items:)") }

  /// Room below the anchor, above the home indicator on phones. Beside a rail the menu may
  /// use the window's full safe height: it slides up from the anchor as far as it needs.
  private var availableHeight: CGFloat {
    beside
      ? bounds.height - safeAreaInsets.top - safeAreaInsets.bottom - 16
      : bounds.height - anchor.maxY - 16 - (compact ? safeAreaInsets.bottom : 0)
  }

  private func show() {
    let panel = makePanel(items: provider())
    var size = panel.preferredSize(maxHeight: availableHeight)
    if compact { size.width = min(bounds.width - 16, max(size.width, 260)) }
    if beside {
      // Opens towards the page: right of a leading rail, left of a trailing one.
      let x =
        anchor.midX > bounds.midX
        ? max(8, anchor.minX - 8 - size.width)
        : min(anchor.maxX + 8, bounds.width - size.width - 8)
      // Level with the anchor when it fits, otherwise raised until its bottom clears the edge.
      let lowest = bounds.height - safeAreaInsets.bottom - 8 - size.height
      let y = max(safeAreaInsets.top + 8, min(anchor.minY, lowest))
      panel.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    } else {
      let x = min(max(8, anchor.maxX - size.width), bounds.width - size.width - 8)
      panel.frame = CGRect(x: x, y: anchor.maxY + 4, width: size.width, height: size.height)
    }
    shownSize = bounds.size
    panels = [panel]
    path = []
    panel.alpha = 0
    UIView.animate(withDuration: 0.12) { panel.alpha = 1 }
    becomeFirstResponder()
    // Same Esc behaviour when the menu lost the first responder: submenu first, then the menu.
    FolioEscape.register(self) { [weak self] in
      guard let self else { return }
      if self.panels.count > 1 {
        self.closePanels(above: self.panels.count - 2)
      } else {
        self.dismiss()
      }
    }
    UIAccessibility.post(notification: .screenChanged, argument: panel)
  }

  func dismiss() {
    guard !dismissing else { return }
    dismissing = true
    FolioEscape.unregister(self)
    let ownedFocus = isFirstResponder
    resignFirstResponder()
    accessibilityViewIsModal = false
    isUserInteractionEnabled = false
    // Return the borrowed responder before activate() runs the action. The action may
    // switch/close a tab or present a sheet that captures this responder for dismissal.
    // The fade completion must never overwrite that action's new focus owner.
    if ownedFocus, let window, BrowserResponderFocus.first(in: window) == nil {
      focusReturnResponder?.becomeFirstResponder()
    }
    UIView.animate(
      withDuration: 0.1, animations: { self.alpha = 0 },
      completion: { _ in
        self.removeFromSuperview()
      })
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Phones: rotation, folding or a keyboard change would leave the panel misplaced.
    if compact, let shownSize, shownSize != bounds.size {
      self.shownSize = nil
      dismiss()
    }
  }

  override func accessibilityPerformEscape() -> Bool {
    dismiss()
    return true
  }

  @objc private func backgroundTapped(_ recognizer: UITapGestureRecognizer) {
    let point = recognizer.location(in: self)
    if !panels.contains(where: { $0.frame.contains(point) }) { dismiss() }
  }

  private func makePanel(items: [ChromeMenuItem], back: String? = nil) -> ChromeMenuPanel {
    let panel = ChromeMenuPanel(items: items, compact: compact, back: back)
    panel.onBack = { [weak self, weak panel] in
      guard let self, let panel else { return }
      self.closePanels(above: self.level(of: panel) - 1)
    }
    panel.onHighlight = { [weak self, weak panel] index in
      guard let self, let panel else { return }
      self.highlight(index, in: panel, openSubmenu: true)
    }
    panel.onActivate = { [weak self, weak panel] index in
      guard let self, let panel else { return }
      self.activate(index, in: panel)
    }
    addSubview(panel)
    return panel
  }

  private func level(of panel: ChromeMenuPanel) -> Int { panels.firstIndex(of: panel) ?? 0 }

  private func closePanels(above level: Int) {
    while panels.count > level + 1 { panels.removeLast().removeFromSuperview() }
    if path.count > level { path.removeSubrange(level...) }
    panels.last?.isHidden = false
  }

  private func highlight(_ index: Int?, in panel: ChromeMenuPanel, openSubmenu: Bool) {
    let level = level(of: panel)
    panel.highlighted = index
    if let index, path.count > level, path[level] == index { return }
    closePanels(above: level)
    if openSubmenu, let index, panel.items[index].isSelectable,
      let children = panel.items[index].children
    {
      openChild(children, from: panel, row: index)
    }
  }

  private func openChild(_ items: [ChromeMenuItem], from parent: ChromeMenuPanel, row: Int) {
    if compact {
      // One panel at a time: the submenu takes the parent's place and width.
      let child = makePanel(items: items, back: parent.items[row].title)
      let height = child.preferredSize(
        maxHeight: bounds.height - parent.frame.minY - 16 - safeAreaInsets.bottom
      ).height
      child.frame = CGRect(
        x: parent.frame.minX, y: parent.frame.minY, width: parent.frame.width, height: height)
      parent.isHidden = true
      path.append(row)
      panels.append(child)
      UIAccessibility.post(notification: .screenChanged, argument: child)
      return
    }
    let child = makePanel(items: items)
    let rowFrame = convert(parent.rowFrame(row), from: parent)
    let size = child.preferredSize(maxHeight: bounds.height - 16)
    // Prefer the left side: the menu opens at the trailing end of the bar.
    var x = parent.frame.minX - size.width + 4
    if x < 8 { x = min(parent.frame.maxX - 4, bounds.width - size.width - 8) }
    let y = min(max(8, rowFrame.minY - ChromeMenuPanel.inset), bounds.height - size.height - 8)
    child.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    path.append(row)
    panels.append(child)
  }

  private func activate(_ index: Int, in panel: ChromeMenuPanel) {
    let item = panel.items[index]
    guard item.isSelectable else { return }
    if let children = item.children {
      let level = level(of: panel)
      if path.count <= level || path[level] != index {
        closePanels(above: level)
        panel.highlighted = index
        openChild(children, from: panel, row: index)
      }
      panels.last?.highlighted = panels.last?.firstSelectable()
      return
    }
    if item.keepsOpen {
      item.action?()
      reload()
    } else {
      dismiss()
      item.action?()
    }
  }

  /// Rebuilds every open panel from fresh data, keeping highlights and open submenus.
  private func reload() {
    var items = provider()
    for (level, panel) in panels.enumerated() {
      let highlighted = panel.highlighted
      panel.setItems(items)
      panel.highlighted = highlighted
      guard level < path.count, let children = items[safe: path[level]]?.children else { break }
      items = children
    }
  }

  // MARK: Keyboard

  override var canBecomeFirstResponder: Bool { true }

  private var focusReturnResponder: UIView? {
    guard let window, let previousResponder, previousResponder.window === window else { return nil }
    var ancestor: UIView? = previousResponder
    while let view = ancestor {
      if view.isHidden || view.alpha < 0.01 { return nil }
      ancestor = view.superview
    }
    return previousResponder
  }

  /// The menu is a window subview, so its own responder chain skips the browser controller.
  /// Never route through a hidden/detached tab or a menu that is already closing.
  override var next: UIResponder? {
    (dismissing ? nil : focusReturnResponder) ?? window?.rootViewController ?? super.next
  }

  /// Closes any open Folio menu in `window`, e.g. before a keyboard shortcut acts.
  static func dismissOpen(in window: UIWindow?) {
    for case let menu as ChromeMenuPresenter in window?.subviews ?? [] { menu.dismiss() }
  }

  override var keyCommands: [UIKeyCommand]? {
    [
      UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow,
      UIKeyCommand.inputRightArrow, UIKeyCommand.inputEscape, "\r", " ",
    ].map { input in
      let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(key(_:)))
      command.wantsPriorityOverSystemBehavior = true
      return command
    }
  }

  @objc private func key(_ command: UIKeyCommand) {
    guard let panel = panels.last else { return }
    switch command.input ?? "" {
    case UIKeyCommand.inputDownArrow:
      panel.highlighted = panel.nextSelectable(after: panel.highlighted, step: 1)
    case UIKeyCommand.inputUpArrow:
      panel.highlighted = panel.nextSelectable(after: panel.highlighted, step: -1)
    case UIKeyCommand.inputRightArrow:
      if let index = panel.highlighted, panel.items[index].children != nil {
        activate(index, in: panel)
      }
    case UIKeyCommand.inputLeftArrow:
      if panels.count > 1 { closePanels(above: panels.count - 2) }
    case UIKeyCommand.inputEscape:
      if panels.count > 1 { closePanels(above: panels.count - 2) } else { dismiss() }
    default:
      if let index = panel.highlighted { activate(index, in: panel) }
    }
  }
}

/// One rounded dark panel of rows.
@MainActor
final class ChromeMenuPanel: UIView {
  static let inset: CGFloat = 6
  static let rowHeight: CGFloat = 34
  /// iPhone rows keep 44 pt touch targets.
  static let compactRowHeight: CGFloat = 44
  static let separatorHeight: CGFloat = 13

  private(set) var items: [ChromeMenuItem]
  var onHighlight: ((Int?) -> Void)?
  var onActivate: ((Int) -> Void)?
  var onBack: (() -> Void)?
  private let compact: Bool
  /// Compact submenus: the parent row's title, shown in a leading Back row.
  private let back: String?
  private var rowHeight: CGFloat { compact ? Self.compactRowHeight : Self.rowHeight }
  var highlighted: Int? {
    didSet { for (index, row) in rows.enumerated() { row?.isLit = index == highlighted } }
  }
  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private var rows: [ChromeMenuRow?] = []

  init(items: [ChromeMenuItem], compact: Bool = false, back: String? = nil) {
    self.items = items
    self.compact = compact
    self.back = back
    super.init(frame: .zero)
    backgroundColor = ChromeMenuPanel.background
    layer.cornerRadius = 12
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.borderColor = ChromeMenuPresenter.separator.cgColor
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.4
    layer.shadowRadius = 16
    layer.shadowOffset = CGSize(width: 0, height: 6)
    overrideUserInterfaceStyle = .dark
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.layer.cornerRadius = 12
    scroll.layer.cornerCurve = .continuous
    scroll.showsVerticalScrollIndicator = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    addSubview(scroll)
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: topAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(
        equalTo: scroll.contentLayoutGuide.topAnchor, constant: Self.inset),
      stack.bottomAnchor.constraint(
        equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Self.inset),
      stack.leadingAnchor.constraint(
        equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Self.inset),
      stack.trailingAnchor.constraint(
        equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Self.inset),
    ])
    setItems(items)
  }

  required init?(coder: NSCoder) { fatalError("Use init(items:)") }

  static let background = ChromePalette.hex(0x1E1E1E)

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 12).cgPath
  }

  func setItems(_ items: [ChromeMenuItem]) {
    self.items = items
    for view in stack.arrangedSubviews { view.removeFromSuperview() }
    if let back {
      let row = ChromeMenuBackRow(title: back, height: rowHeight)
      row.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
      stack.addArrangedSubview(row)
      stack.addArrangedSubview(Self.separatorView())
    }
    let gutter = items.contains { $0.checked }
    rows = items.enumerated().map { index, item in
      if item.isSeparator {
        stack.addArrangedSubview(Self.separatorView())
        return nil
      }
      let row = ChromeMenuRow(item: item, gutter: gutter, compact: compact)
      row.addAction(UIAction { [weak self] _ in self?.onActivate?(index) }, for: .touchUpInside)
      row.onHover = { [weak self] inside in
        guard let self else { return }
        if inside {
          self.onHighlight?(item.isSelectable ? index : nil)
        } else if self.highlighted == index, item.children == nil {
          self.highlighted = nil
        }
      }
      row.onPress = { [weak self] in self?.highlighted = index }
      stack.addArrangedSubview(row)
      return row
    }
  }

  private static func separatorView() -> UIView {
    let separator = UIView()
    let line = UIView()
    line.translatesAutoresizingMaskIntoConstraints = false
    line.backgroundColor = ChromeMenuPresenter.separator
    separator.addSubview(line)
    NSLayoutConstraint.activate([
      separator.heightAnchor.constraint(equalToConstant: Self.separatorHeight),
      line.heightAnchor.constraint(equalToConstant: 1),
      line.centerYAnchor.constraint(equalTo: separator.centerYAnchor),
      line.leadingAnchor.constraint(equalTo: separator.leadingAnchor, constant: 6),
      line.trailingAnchor.constraint(equalTo: separator.trailingAnchor, constant: -6),
    ])
    separator.isAccessibilityElement = false
    return separator
  }

  func preferredSize(maxHeight: CGFloat) -> CGSize {
    let width = rows.compactMap { $0?.preferredWidth }.max() ?? 160
    let header = back == nil ? 0 : rowHeight + Self.separatorHeight
    let height =
      items.reduce(Self.inset * 2 + header) {
        $0 + ($1.isSeparator ? Self.separatorHeight : rowHeight)
      }
    return CGSize(
      width: min(max(width + Self.inset * 2, 200), 320), height: min(height, max(120, maxHeight)))
  }

  func rowFrame(_ index: Int) -> CGRect {
    layoutIfNeeded()
    guard let row = rows[safe: index] ?? nil else { return .zero }
    return convert(row.bounds, from: row)
  }

  func firstSelectable() -> Int? { nextSelectable(after: nil, step: 1) }

  func nextSelectable(after index: Int?, step: Int) -> Int? {
    guard !items.isEmpty else { return nil }
    var current = index ?? (step > 0 ? -1 : items.count)
    for _ in items.indices {
      current = (current + step + items.count) % items.count
      if items[current].isSelectable { return current }
    }
    return index
  }
}

/// A menu row: optional check gutter, title, muted hint or submenu chevron.
@MainActor
final class ChromeMenuRow: UIControl {
  var onHover: ((Bool) -> Void)?
  var onPress: (() -> Void)?
  var isLit = false {
    didSet { if oldValue != isLit { refresh() } }
  }
  private let item: ChromeMenuItem
  private let fill = UIView()
  private let check = UIImageView(image: UIImage(systemName: "checkmark"))
  private let title = UILabel()
  private let hint = UILabel()
  private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
  private(set) var preferredWidth: CGFloat = 0

  init(item: ChromeMenuItem, gutter: Bool, compact: Bool = false) {
    var item = item
    // Phones rarely have a keyboard: keep value hints ("75%"), drop shortcut hints.
    if compact, let hint = item.hint, hint.contains(where: { "⌘⌃⌥⇧".contains($0) }) {
      item.hint = nil
    }
    self.item = item
    super.init(frame: .zero)
    fill.translatesAutoresizingMaskIntoConstraints = false
    fill.isUserInteractionEnabled = false
    fill.layer.cornerRadius = 6
    fill.layer.cornerCurve = .continuous
    addSubview(fill)

    let font = UIFont.systemFont(ofSize: compact ? 15 : 13, weight: .regular)
    title.text = item.title
    title.font = font
    hint.text = item.hint
    hint.font = font
    hint.textAlignment = .right
    for image in [check, chevron] {
      image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: 11, weight: .semibold)
      image.contentMode = .center
      image.isHidden = true
    }
    check.isHidden = !item.checked
    chevron.isHidden = item.children == nil
    hint.isHidden = item.hint == nil

    let row = UIStackView(arrangedSubviews: [title, UIView(), hint, chevron])
    row.translatesAutoresizingMaskIntoConstraints = false
    row.isUserInteractionEnabled = false
    row.spacing = 16
    row.setCustomSpacing(8, after: hint)
    row.alignment = .center
    addSubview(row)
    check.translatesAutoresizingMaskIntoConstraints = false
    addSubview(check)
    let leading: CGFloat = gutter ? 30 : 12
    NSLayoutConstraint.activate([
      heightAnchor.constraint(
        equalToConstant: compact ? ChromeMenuPanel.compactRowHeight : ChromeMenuPanel.rowHeight),
      fill.topAnchor.constraint(equalTo: topAnchor, constant: 1),
      fill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
      fill.leadingAnchor.constraint(equalTo: leadingAnchor),
      fill.trailingAnchor.constraint(equalTo: trailingAnchor),
      check.centerYAnchor.constraint(equalTo: centerYAnchor),
      check.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    let hintWidth =
      item.hint.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 16 } ?? 0
    preferredWidth =
      leading + (item.title as NSString).size(withAttributes: [.font: font]).width + 24 + hintWidth
      + (item.children == nil ? 0 : 20) + 10

    isEnabled = item.enabled
    isAccessibilityElement = true
    accessibilityLabel = item.title
    accessibilityValue = item.hint
    var traits: UIAccessibilityTraits = .button
    if item.checked { traits.insert(.selected) }
    if !item.enabled { traits.insert(.notEnabled) }
    accessibilityTraits = traits
    if item.children != nil { accessibilityHint = "Opens submenu" }

    addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    addAction(UIAction { [weak self] _ in self?.onPress?() }, for: .touchDown)
    refresh()
  }

  required init?(coder: NSCoder) { fatalError("Use init(item:gutter:)") }

  @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
    switch recognizer.state {
    case .began, .changed: onHover?(true)
    case .ended, .cancelled: onHover?(false)
    default: break
    }
  }

  private func refresh() {
    let lit = isLit && item.enabled
    fill.backgroundColor = lit ? ChromeMenuPresenter.accent : .clear
    title.textColor = UIColor(white: 1, alpha: item.enabled ? 1 : 0.35)
    hint.textColor =
      lit ? .white : ChromeMenuPresenter.hint.withAlphaComponent(item.enabled ? 1 : 0.5)
    check.tintColor = title.textColor
    chevron.tintColor = title.textColor
  }
}

/// Compact submenu header: a back chevron and the parent row's title.
@MainActor
final class ChromeMenuBackRow: UIControl {
  private let fill = UIView()

  init(title text: String, height: CGFloat) {
    super.init(frame: .zero)
    fill.translatesAutoresizingMaskIntoConstraints = false
    fill.isUserInteractionEnabled = false
    fill.layer.cornerRadius = 6
    fill.layer.cornerCurve = .continuous
    addSubview(fill)
    let chevron = UIImageView(
      image: UIImage(
        systemName: "chevron.left",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
    chevron.tintColor = ChromeMenuPresenter.hint
    let title = UILabel()
    title.text = text
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.textColor = .white
    let row = UIStackView(arrangedSubviews: [chevron, title, UIView()])
    row.spacing = 8
    row.alignment = .center
    row.isUserInteractionEnabled = false
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: height),
      fill.topAnchor.constraint(equalTo: topAnchor, constant: 1),
      fill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
      fill.leadingAnchor.constraint(equalTo: leadingAnchor),
      fill.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    isAccessibilityElement = true
    accessibilityLabel = "Back"
    accessibilityValue = text
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { fatalError("Use init(title:height:)") }

  override var isHighlighted: Bool {
    didSet { fill.backgroundColor = isHighlighted ? ChromePalette.hover : .clear }
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
