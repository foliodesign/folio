import UIKit

/// iPhone Duo side column (maintainer, 2026-11-11, after Freeform and Reddit on the Duo): the most
/// used edit commands as Liquid Glass down the window's side, over the page, within thumb reach.
/// Window controls (Home, tab title, count, ⋯) stay in the top bar: `DuoTitleBar` in compact
/// layouts, the iPad tab strip when unfolded full screen.
///
/// Undo stands alone at the top of the column; hold it for a menu with Undo and Redo (unfolded
/// full screen, Redo also gets its own button). Cut, Copy and Paste sit at the bottom, and in
/// compact layouts (folded, side by side) a tools button below them holds Duplicate, Select all,
/// Group, Ungroup and Frame selection.
///
/// The top group hangs from the top limit (under the status corner or the top bar), the bottom
/// groups rest on the bottom limit (the screen's bottom edge, a sheet, the keyboard or its key
/// row). When they would meet, Cut goes first, then Copy, Paste and Redo, then the tools and Undo.
///
/// It lies over the whole window and takes touches only on its glass. Metrics are Safari's column
/// on the Duo as measured (simulator 2026-11-09, the maintainer's Duo 2026-11-10):
/// 48 pt controls 54 pt apart, centred 48 pt from the window edge, 13 pt between groups.
@MainActor
final class SideRailView: UIView {
  enum Side { case left, right }

  static let control: CGFloat = 48
  static let pitch: CGFloat = 54
  static let groupGap: CGFloat = 13
  static let edgeCentre: CGFloat = 48
  static let statusGap: CGFloat = 48
  static let bottomCentre: CGFloat = 58
  /// Glyph size in the glass controls: the bottom bar's 16 pt in its 44 pt buttons, scaled to 48.
  static let iconPointSize: CGFloat = 17
  /// The strip of window the column covers, from its edge: up to the controls' far side plus a
  /// small gap. The tool pill stays out of it.
  static let columnWidth: CGFloat = edgeCentre + control / 2 + 12

  /// Window edge the column hugs (physical: the Duo keeps it on the same side in right-to-left).
  var side = Side.right { didSet { if side != oldValue { setNeedsLayout() } } }
  /// Highest allowed centre of the first control, from the top.
  var topCentreLimit: CGFloat = 0 { didSet { if topCentreLimit != oldValue { setNeedsLayout() } } }
  /// Lowest allowed centre of the last control, from the top.
  var bottomCentreLimit: CGFloat = .greatestFiniteMagnitude {
    didSet { if bottomCentreLimit != oldValue { setNeedsLayout() } }
  }
  /// Compact: a tools button follows the clipboard. Regular: Redo has its own button instead.
  var compact = true { didSet { if compact != oldValue { setNeedsLayout() } } }

  var onUndo: (() -> Void)?
  var onRedo: (() -> Void)?
  /// Cut, Copy or Paste, with the button as the sender (Paste's permission callout points at it).
  var onEdit: ((ShortcutEditAction, UIView) -> Void)?
  /// The tools menu's items, built each time it opens.
  var toolsMenu: (() -> [UIMenuElement])?

  private let undo = SideRailView.button("arrow.uturn.backward", label: "Undo")
  private let redo = SideRailView.button("arrow.uturn.forward", label: "Redo")
  private let cut = SideRailView.button("scissors", label: "Cut")
  private let copy = SideRailView.button(ToolbarIcon.copy, label: "Copy")
  private let paste = SideRailView.button(ToolbarIcon.paste, label: "Paste")
  private let tools = SideRailView.button("square.grid.2x2", label: "More edit commands")
  private let historyGlass = SideRailView.glass()
  private let editGlass = SideRailView.glass()
  private let toolsGlass = SideRailView.glass()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    accessibilityIdentifier = "duo-column"
    for button in [undo, redo] { historyGlass.contentView.addSubview(button) }
    for button in [cut, copy, paste] { editGlass.contentView.addSubview(button) }
    toolsGlass.contentView.addSubview(tools)
    for glass in [historyGlass, editGlass, toolsGlass] { addSubview(glass) }
    undo.addAction(UIAction { [weak self] _ in self?.onUndo?() }, for: .touchUpInside)
    redo.addAction(UIAction { [weak self] _ in self?.onRedo?() }, for: .touchUpInside)
    for (button, action) in [(cut, ShortcutEditAction.cut), (copy, .copy), (paste, .paste)] {
      button.addAction(
        UIAction { [weak self, weak button] _ in
          guard let button else { return }
          self?.onEdit?(action, button)
        }, for: .touchUpInside)
    }
    // A tap undoes; a hold opens Undo and Redo, like Safari's back button and its history.
    undo.menu = UIMenu(children: [
      UIAction(title: "Undo", image: Self.image("arrow.uturn.backward")) { [weak self] _ in
        self?.onUndo?()
      },
      UIAction(title: "Redo", image: Self.image("arrow.uturn.forward")) { [weak self] _ in
        self?.onRedo?()
      },
    ])
    tools.showsMenuAsPrimaryAction = true
    tools.menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { [weak self] completion in
        completion(self?.toolsMenu?() ?? [])
      }
    ])
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic side rail") }

  /// Only the glass takes touches; everything else falls through to the page.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    [historyGlass, editGlass, toolsGlass].contains {
      !$0.isHidden && $0.frame.insetBy(dx: -4, dy: -4).contains(point)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let x = side == .right ? bounds.maxX - Self.edgeCentre : Self.edgeCentre
    var history: [UIButton] = compact ? [undo] : [undo, redo]
    var edit: [UIButton] = [cut, copy, paste]
    var tail: [UIButton] = compact ? [tools] : []
    func height() -> CGFloat {
      let groups = [history, edit, tail].filter { !$0.isEmpty }
      return groups.reduce(0) { $0 + Self.height($1.count) }
        + CGFloat(max(0, groups.count - 1)) * Self.groupGap
    }
    // Whatever does not fit goes, never overlaps: Cut, Copy, Paste, Redo, then the tools and
    // Undo (a tall status corner and the keyboard with its key row can leave no room at all;
    // a field being edited has its own clipboard menu).
    let room = bottomCentreLimit - topCentreLimit + Self.control
    for button in [cut, copy, paste] where height() > room { edit.removeAll { $0 === button } }
    if height() > room { history = [undo] }
    if height() > room { tail = [] }
    if height() > room { history = [] }
    for button in [undo, redo, cut, copy, paste] {
      button.isHidden = !(history + edit).contains(button)
    }
    historyGlass.isHidden = history.isEmpty
    editGlass.isHidden = edit.isEmpty
    toolsGlass.isHidden = tail.isEmpty
    var y = topCentreLimit - Self.control / 2
    if !history.isEmpty { place(historyGlass, history, x: x, y: &y) }
    let groups = [edit, tail].filter { !$0.isEmpty }
    y =
      bottomCentreLimit + Self.control / 2
      - groups.reduce(0) { $0 + Self.height($1.count) + Self.groupGap } + Self.groupGap
    if !edit.isEmpty { place(editGlass, edit, x: x, y: &y) }
    if !tail.isEmpty { place(toolsGlass, tail, x: x, y: &y) }
  }

  /// Lays the buttons out down one glass capsule whose top is `y`, then moves `y` past it.
  private func place(
    _ glass: UIVisualEffectView, _ buttons: [UIButton], x: CGFloat, y: inout CGFloat
  ) {
    let height = Self.height(buttons.count)
    glass.frame = CGRect(x: x - Self.control / 2, y: y, width: Self.control, height: height)
    for (index, button) in buttons.enumerated() {
      button.frame = CGRect(
        x: 0, y: CGFloat(index) * Self.pitch, width: Self.control, height: Self.control)
    }
    y += height + Self.groupGap
  }

  /// A capsule of `count` controls, `pitch` apart.
  private static func height(_ count: Int) -> CGFloat {
    CGFloat(count) * pitch - (pitch - control)
  }

  static func glass() -> UIVisualEffectView {
    let effect = UIGlassEffect()
    effect.isInteractive = true
    let view = UIVisualEffectView(effect: effect)
    view.cornerConfiguration = .capsule()
    return view
  }

  /// A glyph from the chrome's icon system at the glass controls' size, so every symbol and
  /// drawing in the column, the top bar and their menus looks the same size.
  static func image(_ key: String) -> UIImage? {
    ToolbarIcon.image(key, pointSize: iconPointSize)
  }

  /// SF Symbol name or one of `ToolbarIcon`'s original drawings.
  static func button(_ symbol: String, label: String) -> UIButton {
    var configuration = UIButton.Configuration.plain()
    configuration.image = image(symbol)
    configuration.contentInsets = .zero
    let button = UIButton(configuration: configuration)
    button.configurationUpdateHandler = { button in
      var configuration = button.configuration
      configuration?.baseForegroundColor =
        button.isHighlighted ? ChromePalette.icon : ChromePalette.primaryText
      button.configuration = configuration
    }
    button.accessibilityLabel = label
    return button
  }
}

/// Open files as a count badge, like the compact top bar; opens the tab list.
@MainActor
final class SideRailCountButton: UIControl {
  private let badge = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)

  override init(frame: CGRect) {
    super.init(frame: frame)
    badge.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    badge.textColor = ChromePalette.primaryText
    badge.textAlignment = .center
    badge.layer.borderWidth = 1.6
    badge.layer.cornerRadius = 5
    badge.layer.cornerCurve = .continuous
    badge.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    addSubview(badge)
    addSubview(spinner)
    NSLayoutConstraint.activate([
      badge.centerXAnchor.constraint(equalTo: centerXAnchor),
      badge.centerYAnchor.constraint(equalTo: centerYAnchor),
      badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
      badge.heightAnchor.constraint(equalToConstant: 22),
      spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    isAccessibilityElement = true
    accessibilityTraits = .button
    accessibilityHint = "Shows open tabs"
    applyBorder()
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
      self.applyBorder()
    }
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic count button") }

  func update(count: Int, loading: Bool) {
    badge.text = String(count)
    badge.isHidden = loading
    if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    accessibilityLabel = "\(count) open \(count == 1 ? "file" : "files")"
  }

  override var isHighlighted: Bool {
    didSet { badge.alpha = isHighlighted ? 0.6 : 1 }
  }

  private func applyBorder() {
    badge.layer.borderColor = ChromePalette.primaryText.resolvedColor(with: traitCollection).cgColor
  }
}
