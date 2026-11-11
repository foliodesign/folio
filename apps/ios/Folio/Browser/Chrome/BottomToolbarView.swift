import UIKit

/// Native editing actions, sent through UIKit's standard edit selectors to WebKit.
enum ShortcutEditAction {
  case copy, cut, paste, selectAll

  var selector: Selector {
    switch self {
    case .copy: #selector(UIResponderStandardEditActions.copy(_:))
    case .cut: #selector(UIResponderStandardEditActions.cut(_:))
    case .paste: #selector(UIResponderStandardEditActions.paste(_:))
    case .selectAll: #selector(UIResponderStandardEditActions.selectAll(_:))
    }
  }
}

/// File-tab bottom bar: modifier keys, a flick arrow key and edit commands. In compact layouts
/// (iPhone, narrow iPad windows; maintainer, 2026-11-11) nothing scrolls: Layers, Properties,
/// Keys and Tools sit fixed at the left, Undo, Redo, Cut, Copy and Paste fixed at the right.
/// Keys opens a second row with the modifiers and arrows, Tools one with Duplicate, Select all,
/// Group, Ungroup and Frame selection; one at a time. Figma's tools live in the floating
/// `PhoneToolPill` above the bar. In landscape Properties moves to the right end, the side its
/// panel opens. Buttons narrow below 44 pt when the row would not fit. Keys go out as
/// standard DOM keyboard events (touch-shortcuts.ts); clipboard and select all as native actions.
/// Modifiers behave like real keys: down while a finger or pointer holds the button, and a short
/// unused tap toggles them on until tapped again. Every active modifier is sent as "locked" (2)
/// in the two-bit mask (Shift 0, Option 2, Command 4, Control 6), so the page never spends it.
@MainActor
final class BottomToolbarView: UIView {
  static let height: CGFloat = 44
  /// Same size and weight as the Home tab's symbol, scaled with interface zoom.
  static let iconPointSize: CGFloat = 16
  private static let tapDuration: TimeInterval = 0.35

  var onEdit: ((ShortcutEditAction, UIView) -> Void)?
  var onKey: ((String, Bool?) -> Void)?
  var onModifiers: ((Int) -> Void)?
  /// iPhone: "left" or "right" sidebar sheet toggle.
  var onPanel: ((String) -> Void)?
  var interfaceScale: CGFloat = 1 { didSet { applyScale() } }

  private let left = UIStackView()
  /// Compact: Layers, Properties, Keys and Tools, fixed at the left.
  private let fixed = UIStackView()
  /// Compact: the Tools row (Duplicate, Select all, grouping), above the bar like the keys.
  private let toolsRow = UIStackView()
  /// Compact: holds the keys row and the Tools row; one shows at a time.
  private let drawerStack = UIStackView()
  private let scroll = UIScrollView()
  private let keysScroll = UIScrollView()
  private let right = UIStackView()
  /// iPad: modifiers, arrows and commands in one scrolling row. It looks the same as fixed keys
  /// with right-aligned commands while everything fits, and scrolls instead of clipping when not.
  private let track = UIStackView()
  private let arrows = FlickArrowControl()
  private let hairline = UIView()
  private var rowHeight: NSLayoutConstraint!
  private var hairlineHeight: NSLayoutConstraint!
  private var widths: [NSLayoutConstraint] = []
  private var buttons: [(button: UIButton, icon: String)] = []
  private var modifiers: [Int: UIButton] = [:]
  private var modifierMask = 0
  private var toggled: Set<Int> = []
  private var held: [Int: (wasOn: Bool, start: TimeInterval, used: Bool)] = [:]
  private let phone: Bool
  /// iPad and the iPhone Duo (maintainer, 2026-11-11): the row sits lower, in half of the
  /// home-indicator inset, and further in from the sides, clear of the display's large corners.
  /// Plain iPhones keep the full inset: their corners leave no room to come lower.
  private let roundCorners = !PhoneExperiencePolicy.isPhone || PhoneExperiencePolicy.isDuo
  private var rowBottom: NSLayoutConstraint!
  private var phoneRowHeight: NSLayoutConstraint?
  private var keysTop: NSLayoutConstraint?
  private var scrollTop: NSLayoutConstraint?
  private var panels: [String: UIButton] = [:]
  private var keysButton: UIButton?
  private var toolsButton: UIButton?
  /// Compact: the command buttons by group (Undo/Redo, clipboard, Duplicate/Select all, grouping).
  private var compactGroups: [[UIButton]] = []
  private var buttonWidths: [ObjectIdentifier: NSLayoutConstraint] = [:]
  /// Compact: the second row above the bar.
  enum Drawer { case none, keys, tools }
  private(set) var drawer = Drawer.none
  /// Compact: Undo, Redo, Cut, Copy and Paste fixed at the right (and Properties in landscape);
  /// iPhone Duo `keysInRow`: Layers and Properties.
  private let trailingFixed = UIStackView()
  private(set) var landscape = false
  /// Which commands the bar shows. The iPhone Duo's side column takes some: Undo, Redo, Cut,
  /// Copy and Paste unfolded full screen (`withoutHistoryAndClipboard`), every command and Keys
  /// in compact layouts (`none`, with `keysInRow`). Modifiers and arrows always stay.
  enum Commands { case all, withoutHistoryAndClipboard, none }
  /// iPad row: command buttons and dividers by group (0 Undo/Redo, 1 clipboard, 2 Duplicate/Select
  /// all, 3 grouping); a divider belongs to the group it precedes. Compact layouts place their
  /// commands in `placeRow` instead.
  private var commandViews: [(group: Int, divider: Bool, view: UIView)] = []
  var commands = Commands.all {
    didSet {
      guard commands != oldValue else { return }
      for (group, divider, view) in commandViews {
        switch commands {
        case .all: view.isHidden = false
        case .none: view.isHidden = true
        // Group 2's divider would otherwise lead the row.
        case .withoutHistoryAndClipboard: view.isHidden = group <= 1 || (divider && group == 2)
        }
      }
    }
  }
  /// Compact layouts: whether the modifier and arrow row is open (Keys). Clearing it leaves an
  /// open Tools row alone.
  var keysExpanded: Bool {
    get { drawer == .keys }
    set {
      if newValue {
        setDrawer(.keys)
      } else if drawer == .keys {
        setDrawer(.none)
      }
    }
  }
  /// iPhone Duo compact layouts (maintainer, 2026-11-11): one row with the modifiers and arrows
  /// always shown at the left and Layers and Properties at the right, by the side column. Pair
  /// with `commands = .none`; the commands live in the column.
  var keysInRow = false {
    didSet {
      guard phone, keysInRow != oldValue else { return }
      applyDrawer(.none)
      left.isHidden = !keysInRow
      keysScroll.isHidden = !keysInRow
      if !keysInRow { releaseModifiers() }
      placeRow()
      superview?.setNeedsLayout()
    }
  }
  private var keysAbove: NSLayoutConstraint?
  private var keysTrailing: NSLayoutConstraint?
  private var rowConstraints: [NSLayoutConstraint] = []

  init(phone: Bool = PhoneExperiencePolicy.isPhone) {
    self.phone = phone
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = ChromePalette.bar
    accessibilityIdentifier = "bottom-toolbar"
    hairline.backgroundColor = ChromePalette.divider
    for stack in [left, right, fixed, trailingFixed, track, toolsRow, drawerStack] {
      stack.axis = .horizontal
      stack.alignment = .fill
      stack.translatesAutoresizingMaskIntoConstraints = false
    }
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.showsHorizontalScrollIndicator = false
    scroll.contentInsetAdjustmentBehavior = .never
    hairline.translatesAutoresizingMaskIntoConstraints = false
    for view in [left, scroll, hairline] as [UIView] { addSubview(view) }
    // iPhone scrolls the commands only; iPad scrolls the whole row (`track`).
    let row: UIStackView = phone ? right : track
    if !phone {
      track.spacing = 12
      track.addArrangedSubview(left)
      track.addArrangedSubview(right)
    }
    scroll.addSubview(row)

    for (symbol, label, key, offset) in [
      ("shift", "Shift", "⇧", 0), ("control", "Control", "⌃", 6), ("option", "Option", "⌥", 2),
      ("command", "Command", "⌘", 4),
    ] {
      left.addArrangedSubview(modifierButton(symbol, label, "\(label) \(key)", offset))
    }
    left.setCustomSpacing(8, after: left.arrangedSubviews.last!)
    arrows.onArrow = { [weak self] key, down in
      self?.markUsed()
      self?.onKey?(key, down)
    }
    left.addArrangedSubview(arrows)
    let arrowWidth = arrows.widthAnchor.constraint(equalToConstant: 44)
    widths.append(arrowWidth)
    arrowWidth.isActive = true
    arrows.heightAnchor.constraint(equalTo: left.heightAnchor).isActive = true

    // Leading spacer keeps the commands right-aligned while they fit; they scroll when not.
    // Phones keep them left-aligned behind the panel and tool buttons.
    let spacer = UIView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    if !phone { right.addArrangedSubview(spacer) }
    let key = { [weak self] (name: String) in self?.onKey?(name, nil) }
    let edit = { [weak self] (action: ShortcutEditAction) in self?.edit(action) }
    let undo: [(String, String, String, () -> Void)] = [
      ("arrow.uturn.backward", "Undo", "⌘Z", { key("undo") }),
      ("arrow.uturn.forward", "Redo", "⇧⌘Z", { key("redo") }),
    ]
    if phone { makeToggles() }
    let groups: [[(String, String, String, () -> Void)]] = [
      undo,
      [
        ("scissors", "Cut", "⌘X", { edit(.cut) }),
        (ToolbarIcon.copy, "Copy", "⌘C", { edit(.copy) }),
        (ToolbarIcon.paste, "Paste", "⌘V", { edit(.paste) }),
      ],
      [
        ("plus.square.on.square", "Duplicate", "⌘D", { key("duplicate") }),
        (ToolbarIcon.selectAll, "Select all", "⌘A", { edit(.selectAll) }),
      ],
      [
        (ToolbarIcon.group, "Group selection", "⌘G", { key("group") }),
        (ToolbarIcon.ungroup, "Ungroup selection", "⇧⌘G", { key("ungroup") }),
        (ToolbarIcon.frame, "Frame selection", "⌥⌘G", { key("frameSelection") }),
      ],
    ]
    for (index, group) in groups.enumerated() {
      if index > 0 && !phone {
        let line = divider()
        right.addArrangedSubview(line)
        commandViews.append((index, true, line))
      }
      var made: [UIButton] = []
      for (icon, label, shortcut, action) in group {
        let button = self.button(icon, label, "\(label) \(shortcut)")
        button.addAction(
          UIAction { [weak self] _ in
            self?.markUsed()
            action()
          }, for: .touchUpInside)
        made.append(button)
        // Compact layouts place them in `placeRow` and the Tools row instead.
        if !phone {
          right.addArrangedSubview(button)
          commandViews.append((index, false, button))
        }
      }
      compactGroups.append(made)
    }

    rowHeight = left.heightAnchor.constraint(equalToConstant: Self.height)
    let edge = Self.edgeInset(roundCorners)
    rowBottom = scroll.bottomAnchor.constraint(
      equalTo: bottomAnchor, constant: -Self.bottomInset(0, roundCorners))
    hairlineHeight = hairline.heightAnchor.constraint(equalToConstant: 1)
    let fill = row.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
    fill.priority = .defaultHigh
    NSLayoutConstraint.activate([
      hairline.topAnchor.constraint(equalTo: topAnchor),
      hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
      hairlineHeight,
      row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
      row.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor),
      fill,
    ])
    if phone {
      // Keys row (modifiers and arrows) and Tools row sit above the bar and start collapsed.
      right.addArrangedSubview(spacer)
      let spacerKeys = UIView()
      spacerKeys.setContentHuggingPriority(.init(1), for: .horizontal)
      left.addArrangedSubview(spacerKeys)
      left.isHidden = true
      for button in compactGroups[2] { toolsRow.addArrangedSubview(button) }
      toolsRow.addArrangedSubview(divider())
      for button in compactGroups[3] { toolsRow.addArrangedSubview(button) }
      let spacerTools = UIView()
      spacerTools.setContentHuggingPriority(.init(1), for: .horizontal)
      toolsRow.addArrangedSubview(spacerTools)
      toolsRow.isHidden = true
      drawerStack.addArrangedSubview(left)
      drawerStack.addArrangedSubview(toolsRow)
      let height = scroll.heightAnchor.constraint(equalToConstant: Self.height)
      phoneRowHeight = height
      keysScroll.translatesAutoresizingMaskIntoConstraints = false
      keysScroll.showsHorizontalScrollIndicator = false
      keysScroll.contentInsetAdjustmentBehavior = .never
      keysScroll.isHidden = true
      addSubview(keysScroll)
      addSubview(fixed)
      addSubview(trailingFixed)
      keysScroll.addSubview(drawerStack)
      let keysFill = drawerStack.widthAnchor.constraint(
        equalTo: keysScroll.frameLayoutGuide.widthAnchor)
      keysFill.priority = .defaultHigh
      keysTop = keysScroll.topAnchor.constraint(equalTo: topAnchor)
      scrollTop = scroll.topAnchor.constraint(equalTo: topAnchor)
      keysAbove = keysScroll.bottomAnchor.constraint(equalTo: scroll.topAnchor)
      keysTrailing = keysScroll.trailingAnchor.constraint(
        equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -edge)
      NSLayoutConstraint.activate([
        scrollTop!, height, rowHeight, keysFill, keysAbove!, keysTrailing!,
        keysScroll.leadingAnchor.constraint(
          equalTo: safeAreaLayoutGuide.leadingAnchor, constant: edge),
        keysScroll.heightAnchor.constraint(equalTo: scroll.heightAnchor),
        drawerStack.topAnchor.constraint(equalTo: keysScroll.contentLayoutGuide.topAnchor),
        drawerStack.bottomAnchor.constraint(equalTo: keysScroll.contentLayoutGuide.bottomAnchor),
        drawerStack.leadingAnchor.constraint(equalTo: keysScroll.contentLayoutGuide.leadingAnchor),
        drawerStack.trailingAnchor.constraint(
          equalTo: keysScroll.contentLayoutGuide.trailingAnchor),
        drawerStack.heightAnchor.constraint(equalTo: keysScroll.frameLayoutGuide.heightAnchor),
        drawerStack.widthAnchor.constraint(
          greaterThanOrEqualTo: keysScroll.frameLayoutGuide.widthAnchor),
        fixed.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: edge),
        fixed.topAnchor.constraint(equalTo: scroll.topAnchor),
        fixed.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        trailingFixed.trailingAnchor.constraint(
          equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -edge),
        trailingFixed.topAnchor.constraint(equalTo: scroll.topAnchor),
        trailingFixed.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        rowBottom,
      ])
      placeRow()
      applyScale()
      return
    }
    NSLayoutConstraint.activate([
      rowHeight,
      scroll.topAnchor.constraint(equalTo: topAnchor),
      rowBottom,
      scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: edge),
      scroll.trailingAnchor.constraint(
        equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -edge),
    ])
    applyScale()
  }

  /// Compact: the Layers and Properties sheet toggles (they show the open sheet), Keys and Tools.
  private func makeToggles() {
    for (side, icon, label) in [
      ("left", "square.3.layers.3d", "Layers"), ("right", "slider.horizontal.3", "Properties"),
    ] {
      let button = self.button(icon, label, label)
      latchedLook(button)
      button.addAction(
        UIAction { [weak self] _ in self?.onPanel?(side) }, for: .touchUpInside)
      panels[side] = button
    }
    let keys = self.button("keyboard", "Keys", "Modifier and arrow keys")
    keys.accessibilityHint = "Shows Shift, Control, Option, Command and the arrow keys."
    keys.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.setDrawer(self.drawer == .keys ? .none : .keys)
      }, for: .touchUpInside)
    let tools = self.button("square.grid.2x2", "Tools", "Duplicate, select all and grouping")
    tools.accessibilityHint = "Shows Duplicate, Select all, Group, Ungroup and Frame selection."
    tools.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.setDrawer(self.drawer == .tools ? .none : .tools)
      }, for: .touchUpInside)
    for button in [keys, tools] { latchedLook(button) }
    keysButton = keys
    toolsButton = tools
  }

  /// iPhone: one-row landscape layout, or the portrait bar (panel toggles both at the left).
  func setLandscape(_ value: Bool) {
    guard phone, value != landscape else { return }
    landscape = value
    placeRow()
  }

  /// Fills the fixed ends. Compact: Layers, Properties, Keys and Tools at the left, Undo, Redo
  /// and the clipboard at the right, Properties moving to the right end in landscape (the side
  /// its panel opens). iPhone Duo `keysInRow`: Layers and Properties at the right of the keys;
  /// the commands live in the side column.
  private func placeRow() {
    guard let layers = panels["left"], let properties = panels["right"], let keys = keysButton,
      let tools = toolsButton
    else { return }
    for stack in [fixed, trailingFixed] {
      for view in stack.arrangedSubviews {
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
    }
    let leading: [UIView]
    var trailing: [UIView]
    if keysInRow {
      leading = []
      trailing = [divider(), layers, properties]
    } else {
      leading = (landscape ? [layers] : [layers, properties]) + [divider(), keys, tools]
      // A divider leads the right end, so Tools and Undo read as two groups even when the ends
      // meet (maintainer, 2026-11-11).
      trailing = [divider()] + compactGroups[0] + [divider()] + compactGroups[1]
      if landscape { trailing += [divider(), properties] }
    }
    for view in leading { fixed.addArrangedSubview(view) }
    for view in trailing { trailingFixed.addArrangedSubview(view) }
    fixed.isHidden = keysInRow
    scroll.isHidden = keysInRow
    layoutRow()
  }

  private func layoutRow() {
    NSLayoutConstraint.deactivate(rowConstraints)
    var row: [NSLayoutConstraint] = [
      scroll.leadingAnchor.constraint(equalTo: fixed.trailingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingFixed.leadingAnchor),
    ]
    keysAbove?.isActive = !keysInRow
    keysTrailing?.isActive = !keysInRow
    if keysInRow {
      row += [
        keysScroll.topAnchor.constraint(equalTo: scroll.topAnchor),
        keysScroll.trailingAnchor.constraint(equalTo: trailingFixed.leadingAnchor),
      ]
    }
    rowConstraints = row
    NSLayoutConstraint.activate(row)
    setNeedsLayout()
  }

  /// Compact: narrows the fixed buttons below 44 pt when both ends would not fit side by side
  /// (iPhone portrait, Slide Over); the divider leading the right end keeps them apart.
  private func fitRow() {
    guard phone else { return }
    let pixels = max(1, traitCollection.displayScale)
    let full = ((max(44, 44 * max(1, interfaceScale))) * pixels).rounded() / pixels
    let views = fixed.arrangedSubviews + trailingFixed.arrangedSubviews
    let buttons = views.compactMap { $0 as? UIButton }
    let dividers = CGFloat(views.count - buttons.count) * 13
    let room = bounds.width - safeAreaInsets.left - safeAreaInsets.right - 8 - dividers
    guard room > 0, !buttons.isEmpty else { return }
    let fitted = (room / CGFloat(buttons.count) * pixels).rounded(.down) / pixels
    // The Duo's row scrolls its keys instead; its two panel toggles keep their size.
    let width = keysInRow ? full : max(30, min(full, fitted))
    for button in buttons {
      if let constraint = buttonWidths[ObjectIdentifier(button)], constraint.constant != width {
        constraint.constant = width
      }
    }
  }

  override func layoutSubviews() {
    fitRow()
    super.layoutSubviews()
  }

  /// Compact: opens the Keys or Tools row, or closes it. Closing the keys releases every held or
  /// latched modifier.
  private func setDrawer(_ next: Drawer) {
    guard phone, !keysInRow, next != drawer else { return }
    applyDrawer(next)
  }

  private func applyDrawer(_ next: Drawer) {
    guard next != drawer else { return }
    if drawer == .keys { releaseModifiers() }
    drawer = next
    keysButton?.isSelected = next == .keys
    toolsButton?.isSelected = next == .tools
    left.isHidden = next != .keys
    toolsRow.isHidden = next != .tools
    keysScroll.isHidden = next == .none
    if next == .none {
      keysTop?.isActive = false
      scrollTop?.isActive = true
    } else {
      scrollTop?.isActive = false
      keysTop?.isActive = true
    }
    superview?.setNeedsLayout()
    UIView.performWithoutAnimation { superview?.layoutIfNeeded() }
  }

  /// Sheet state from the page: "left", "right", or anything else for none.
  func setPanel(_ state: String) {
    for (side, button) in panels {
      let shown = side == state || state == "both"
      button.isSelected = shown
      button.accessibilityValue = shown ? "Shown" : "Hidden"
    }
  }

  /// Solid blue while selected, like the modifier keys.
  private func latchedLook(_ button: UIButton) {
    button.configurationUpdateHandler = { button in
      var configuration = button.configuration
      var background = UIBackgroundConfiguration.clear()
      background.cornerRadius = 6
      background.backgroundInsets = .init(top: 6, leading: 4, bottom: 6, trailing: 4)
      background.backgroundColor =
        button.isSelected
        ? ChromePalette.figmaBlue
        : button.isHovered || button.isHighlighted ? ChromePalette.hover : .clear
      configuration?.background = background
      configuration?.baseForegroundColor = button.isSelected ? .white : ChromePalette.icon
      button.configuration = configuration
    }
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic bottom toolbar") }

  /// Space from the bar's side edges (past the safe area) to its first and last controls.
  static func edgeInset(_ roundCorners: Bool) -> CGFloat { roundCorners ? 12 : 4 }

  /// Space below the row: the whole bottom safe area (home indicator) on plain iPhones, half of
  /// it, rounded, on iPad and the Duo.
  static func bottomInset(_ safeBottom: CGFloat, _ roundCorners: Bool) -> CGFloat {
    roundCorners ? (safeBottom / 2).rounded() : safeBottom
  }

  /// Centre of the bottom row, from the bar's top, from constraints (valid before the bar's own
  /// layout pass): the iPhone Duo's side column lines its bottom control up with it.
  var rowCentre: CGFloat { bounds.height + rowBottom.constant - rowHeight.constant / 2 }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    let inset = Self.bottomInset(safeAreaInsets.bottom, roundCorners)
    if rowBottom.constant != -inset { rowBottom.constant = -inset }
  }

  private func button(_ icon: String, _ label: String, _ tip: String) -> UIButton {
    let button = ChromeTabView.segmentButton(icon, label: label)
    button.largeContentTitle = label
    button.showsLargeContentViewer = true
    button.addInteraction(UILargeContentViewerInteraction())
    button.toolTip = tip
    let width = button.widthAnchor.constraint(equalToConstant: 44)
    width.isActive = true
    widths.append(width)
    buttonWidths[ObjectIdentifier(button)] = width
    buttons.append((button, icon))
    return button
  }

  private func divider() -> UIView {
    let line = UIView()
    line.backgroundColor = ChromePalette.divider
    line.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      line.widthAnchor.constraint(equalToConstant: 1),
      line.heightAnchor.constraint(equalToConstant: 20),
    ])
    let wrapper = UIStackView(arrangedSubviews: [line])
    wrapper.isLayoutMarginsRelativeArrangement = true
    // The row reaches into the home-indicator inset on iPad and the Duo; safe-area margins
    // would lift the line off the row's centre (maintainer, 2026-11-11).
    wrapper.insetsLayoutMarginsFromSafeArea = false
    wrapper.directionalLayoutMargins = .init(top: 0, leading: 6, bottom: 0, trailing: 6)
    wrapper.alignment = .center
    return wrapper
  }

  private func modifierButton(
    _ symbol: String, _ label: String, _ tip: String, _ offset: Int
  ) -> UIButton {
    let button = self.button(symbol, label, tip)
    modifiers[offset] = button
    button.accessibilityHint = "Hold to press. Tap to turn on or off."
    button.configurationUpdateHandler = { [weak self] button in
      let down = self.map { ($0.modifierMask >> offset) & 3 != 0 } ?? false
      var configuration = button.configuration
      var background = UIBackgroundConfiguration.clear()
      background.cornerRadius = 6
      background.backgroundInsets = .init(top: 6, leading: 4, bottom: 6, trailing: 4)
      // Held and toggled look the same: solid blue, like a pressed Figma toggle.
      background.backgroundColor =
        down
        ? ChromePalette.figmaBlue
        : button.isHovered || button.isHighlighted ? ChromePalette.hover : .clear
      configuration?.background = background
      configuration?.baseForegroundColor = down ? .white : ChromePalette.icon
      button.configuration = configuration
    }
    button.addAction(
      UIAction { [weak self] _ in self?.press(offset) }, for: .touchDown)
    button.addAction(
      UIAction { [weak self] _ in self?.release(offset, tap: true) },
      for: [.touchUpInside, .touchUpOutside])
    button.addAction(
      UIAction { [weak self] _ in self?.release(offset, tap: false) }, for: .touchCancel)
    return button
  }

  private func releaseModifiers() {
    held.removeAll()
    toggled.removeAll()
    publish()
  }

  private func press(_ offset: Int) {
    // Pressing another modifier while one is held is a chord, not a tap of the held one.
    markUsed()
    held[offset] = (toggled.contains(offset), ProcessInfo.processInfo.systemUptime, false)
    publish()
  }

  private func release(_ offset: Int, tap: Bool) {
    guard let hold = held.removeValue(forKey: offset) else { return }
    let short = ProcessInfo.processInfo.systemUptime - hold.start < Self.tapDuration
    // A short unused tap toggles; a hold returns the key to where it started.
    if tap && short && !hold.used {
      if hold.wasOn { toggled.remove(offset) } else { toggled.insert(offset) }
    }
    publish()
  }

  /// A key sent from elsewhere (the phone tool pill) counts as using held modifiers.
  func noteKeyUse() { markUsed() }

  private func markUsed() {
    for offset in held.keys { held[offset]?.used = true }
  }

  private func publish() {
    let mask = toggled.union(held.keys).reduce(0) { $0 | (2 << $1) }
    render(mask)
    onModifiers?(mask)
  }

  private func edit(_ action: ShortcutEditAction) {
    onEdit?(action, self)
  }

  /// Page-reported state, or 0 to release everything (tab switch, blur, navigation).
  func updateMask(_ value: Int) {
    if value & 0xFF == 0 {
      held.removeAll()
      toggled.removeAll()
    } else {
      toggled = Set([0, 2, 4, 6].filter { (value >> $0) & 3 != 0 && held[$0] == nil })
    }
    render(value & 0xFF)
  }

  private func render(_ mask: Int) {
    modifierMask = mask
    for (offset, button) in modifiers {
      let down = (mask >> offset) & 3 != 0
      button.accessibilityValue = down ? "On" : "Off"
      button.accessibilityTraits = down ? [.button, .selected] : .button
      button.setNeedsUpdateConfiguration()
    }
  }

  private func applyScale() {
    let pixels = max(1, traitCollection.displayScale)
    let snap = { (value: CGFloat) in (value * pixels).rounded() / pixels }
    // Phone controls keep at least their 100% size, whatever the interface zoom.
    let scale = phone ? max(1, interfaceScale) : interfaceScale
    rowHeight.constant = snap(max(40, Self.height * scale))
    phoneRowHeight?.constant = rowHeight.constant
    hairlineHeight.constant = snap(max(1 / pixels, scale))
    for width in widths { width.constant = snap(max(44, 44 * scale)) }
    setNeedsLayout()
    let pointSize = Self.iconPointSize * scale
    for (button, icon) in buttons {
      button.configuration?.image = ToolbarIcon.image(icon, pointSize: pointSize)
      button.configuration?.preferredSymbolConfigurationForImage = nil
    }
    arrows.symbolConfiguration = ToolbarIcon.configuration(
      FlickArrowControl.idle, pointSize: pointSize)
  }
}

/// The chrome's one icon system: every glyph is a symbol (or an original drawing) at the bar's
/// point size, times a per-glyph optical factor so every glyph looks the same size, with the
/// symbol weight stepped so every line is as thick as the drawings'. Drawings scale their
/// geometry, not their stroke. Unlisted keys use factor 1.
@MainActor
enum ToolbarIcon {
  static let copy = "folio.copy"
  static let paste = "folio.paste"
  static let selectAll = "folio.selectAll"
  static let group = "folio.group"
  static let ungroup = "folio.ungroup"
  static let frame = "folio.frame"
  static let text = "folio.text"
  static let scale = "folio.scale"
  static let designMode = "folio.designMode"
  static let actions = "folio.actions"
  static let measurement = "folio.measurement"
  static let annotation = "folio.annotation"

  /// Drawings' stroke in 16-unit grid space, matching a light symbol's line.
  private static let line: CGFloat = 1.2
  /// Stroke and dash scale for the drawing being rendered, so geometry scales but lines do not.
  private static var lineWidth = line
  private static var dash: CGFloat = 1

  /// Optical size factors, measured (2026-11-11, maintainer: Undo and Cut looked larger than
  /// Copy and Paste). Each glyph is scaled so the fourth root of (convex hull area × bounding box
  /// area) of its ink is 15 pt at 16 pt, with no side past 18 pt; thin glyphs (⌃, the line tool,
  /// the pencil) match the others' width instead, and ⋯ and the chevrons keep their own size.
  /// Checked against the Duo simulator's render: an SF Symbol at a given point size draws about
  /// 1.27 times larger on iOS than on the Mac, where the glyphs were measured.
  private static let optics: [String: CGFloat] = [
    "arrow.uturn.backward": 0.9,
    "arrow.uturn.forward": 0.9,
    "scissors": 0.72,
    "plus.square.on.square": 0.7,
    "keyboard": 0.72,
    "square.3.layers.3d": 0.74,
    "slider.horizontal.3": 0.84,
    "shift": 0.84,
    "control": 1.04,
    "option": 0.86,
    "command": 0.78,
    "arrow.up.and.down.and.arrow.left.and.right": 0.76,
    "cursorarrow": 0.9,
    "hand.raised": 0.84,
    "square.dashed": 0.82,
    "crop": 0.78,
    "square": 0.82,
    "line.diagonal": 1.12,
    "arrow.up.right": 1.08,
    "circle": 0.74,
    "photo": 0.72,
    "pencil.tip": 0.96,
    "pencil": 1.02,
    "bubble.left": 0.68,
    "chevron.left.forwardslash.chevron.right": 0.66,
    "square.grid.2x2": 0.82,
    "house": 0.7,
    "house.fill": 0.7,
    copy: 1.14,
    paste: 1.08,
    selectAll: 1.08,
    group: 0.94,
    ungroup: 1.02,
    frame: 1.06,
    scale: 1.22,
    text: 1.38,
    measurement: 1.08,
    annotation: 1.04,
    actions: 1.1,
    designMode: 1.32,
  ]

  /// The image at its optical size, symbol configuration included: callers set no
  /// `preferredSymbolConfigurationForImage` of their own.
  static func image(_ key: String, pointSize: CGFloat) -> UIImage? {
    let factor = optics[key] ?? 1
    guard let body = drawings[key] else {
      return UIImage(systemName: key, withConfiguration: configuration(key, pointSize: pointSize))
    }
    // Design grid is 16 units; a light 16 pt symbol spans about 18 pt.
    let side = (pointSize * 18 / 16).rounded()
    return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
      let cg = context.cgContext
      cg.scaleBy(x: side / 16, y: side / 16)
      cg.translateBy(x: 8, y: 8)
      cg.scaleBy(x: factor, y: factor)
      cg.translateBy(x: -8, y: -8)
      lineWidth = line / factor
      dash = factor
      UIColor.black.set()
      body()
    }.withRenderingMode(.alwaysTemplate)
  }

  /// A symbol's configuration at its optical size. A shrunk symbol thins its line too, so its
  /// weight steps up to keep the drawings' stroke (about 0.084 of the point size): light, regular
  /// and medium strokes measure 0.077, 0.103 and 0.125 of theirs.
  static func configuration(_ key: String, pointSize: CGFloat) -> UIImage.SymbolConfiguration {
    let factor = optics[key] ?? 1
    let weight: UIImage.SymbolWeight = factor < 0.74 ? .medium : factor < 0.94 ? .regular : .light
    return UIImage.SymbolConfiguration(pointSize: pointSize * factor, weight: weight)
  }

  /// Group menu chevrons: small, but bold enough to read beside the tools.
  static func chevron(pointSize: CGFloat) -> UIImage? {
    UIImage(
      systemName: "chevron.down",
      withConfiguration: UIImage.SymbolConfiguration(
        pointSize: pointSize / 2, weight: .semibold))
  }

  private static let drawings: [String: () -> Void] = [
    copy: {
      // Front sheet, with the back sheet peeking out top-left.
      stroke(
        UIBezierPath(roundedRect: CGRect(x: 5.5, y: 5.5, width: 8, height: 8), cornerRadius: 1.5))
      let back = UIBezierPath()
      back.move(to: CGPoint(x: 10.5, y: 3.5))
      back.addLine(to: CGPoint(x: 10.5, y: 3.2))
      back.addQuadCurve(to: CGPoint(x: 9.3, y: 2.5), controlPoint: CGPoint(x: 10.5, y: 2.5))
      back.addLine(to: CGPoint(x: 3.7, y: 2.5))
      back.addQuadCurve(to: CGPoint(x: 2.5, y: 3.7), controlPoint: CGPoint(x: 2.5, y: 2.5))
      back.addLine(to: CGPoint(x: 2.5, y: 9.3))
      back.addQuadCurve(to: CGPoint(x: 3.2, y: 10.5), controlPoint: CGPoint(x: 2.5, y: 10.5))
      back.addLine(to: CGPoint(x: 3.5, y: 10.5))
      stroke(back)
    },
    paste: {
      // Clipboard with its clip and an arrow dropping in.
      let board = UIBezierPath()
      board.move(to: CGPoint(x: 5.5, y: 3))
      board.addLine(to: CGPoint(x: 4, y: 3))
      board.addQuadCurve(to: CGPoint(x: 2.5, y: 4.5), controlPoint: CGPoint(x: 2.5, y: 3))
      board.addLine(to: CGPoint(x: 2.5, y: 12))
      board.addQuadCurve(to: CGPoint(x: 4, y: 13.5), controlPoint: CGPoint(x: 2.5, y: 13.5))
      board.addLine(to: CGPoint(x: 12, y: 13.5))
      board.addQuadCurve(to: CGPoint(x: 13.5, y: 12), controlPoint: CGPoint(x: 13.5, y: 13.5))
      board.addLine(to: CGPoint(x: 13.5, y: 4.5))
      board.addQuadCurve(to: CGPoint(x: 12, y: 3), controlPoint: CGPoint(x: 13.5, y: 3))
      board.addLine(to: CGPoint(x: 10.5, y: 3))
      stroke(board)
      stroke(
        UIBezierPath(roundedRect: CGRect(x: 5.5, y: 1.5, width: 5, height: 3), cornerRadius: 1))
      let arrow = UIBezierPath()
      arrow.move(to: CGPoint(x: 8, y: 6.5))
      arrow.addLine(to: CGPoint(x: 8, y: 11))
      arrow.move(to: CGPoint(x: 6, y: 9))
      arrow.addLine(to: CGPoint(x: 8, y: 11))
      arrow.addLine(to: CGPoint(x: 10, y: 9))
      stroke(arrow)
    },
    selectAll: {
      // Dashed marquee with solid corner handles, like a canvas selection.
      dashed(UIBezierPath(rect: CGRect(x: 3, y: 3, width: 10, height: 10)))
      for x in [3.0, 13.0] {
        for y in [3.0, 13.0] {
          UIBezierPath(rect: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)).fill()
        }
      }
    },
    group: {
      // Dashed bounding box around a square and a circle.
      dashed(
        UIBezierPath(roundedRect: CGRect(x: 1.5, y: 1.5, width: 13, height: 13), cornerRadius: 1))
      stroke(UIBezierPath(rect: CGRect(x: 4, y: 4, width: 4, height: 4)))
      stroke(UIBezierPath(ovalIn: CGRect(x: 7.5, y: 7.5, width: 4.5, height: 4.5)))
    },
    ungroup: {
      // The circle has left the dashed box; the square stays behind.
      dashed(
        UIBezierPath(roundedRect: CGRect(x: 1.5, y: 1.5, width: 9, height: 9), cornerRadius: 1))
      stroke(UIBezierPath(rect: CGRect(x: 4, y: 4, width: 3.5, height: 3.5)))
      stroke(UIBezierPath(ovalIn: CGRect(x: 10, y: 10, width: 4.5, height: 4.5)))
    },
    frame: {
      // Frame tool mark: two crossing pairs of lines.
      let grid = UIBezierPath()
      for value in [5.0, 11.0] {
        grid.move(to: CGPoint(x: value, y: 2))
        grid.addLine(to: CGPoint(x: value, y: 14))
        grid.move(to: CGPoint(x: 2, y: value))
        grid.addLine(to: CGPoint(x: 14, y: value))
      }
      stroke(grid)
    },
    text: {
      // Plain capital T with short serifs.
      let letter = UIBezierPath()
      letter.move(to: CGPoint(x: 3.5, y: 4.5))
      letter.addLine(to: CGPoint(x: 3.5, y: 3))
      letter.addLine(to: CGPoint(x: 12.5, y: 3))
      letter.addLine(to: CGPoint(x: 12.5, y: 4.5))
      letter.move(to: CGPoint(x: 8, y: 3))
      letter.addLine(to: CGPoint(x: 8, y: 13))
      letter.move(to: CGPoint(x: 6.5, y: 13))
      letter.addLine(to: CGPoint(x: 9.5, y: 13))
      stroke(letter)
    },
    scale: {
      // Small square in the lower left, an arrow pulling its corner out to the upper right.
      stroke(
        UIBezierPath(roundedRect: CGRect(x: 2.5, y: 7.5, width: 6, height: 6), cornerRadius: 1))
      let arrow = UIBezierPath()
      arrow.move(to: CGPoint(x: 8.5, y: 7.5))
      arrow.addLine(to: CGPoint(x: 13.5, y: 2.5))
      arrow.move(to: CGPoint(x: 9.5, y: 2.5))
      arrow.addLine(to: CGPoint(x: 13.5, y: 2.5))
      arrow.addLine(to: CGPoint(x: 13.5, y: 6.5))
      stroke(arrow)
    },
    actions: {
      // Outline four-point sparkle, so Actions reads as a line icon like its neighbours.
      let star = UIBezierPath()
      let tips = [
        CGPoint(x: 8, y: 1.5), CGPoint(x: 14.5, y: 8), CGPoint(x: 8, y: 14.5),
        CGPoint(x: 1.5, y: 8),
      ]
      star.move(to: tips[0])
      for index in 0..<4 {
        let next = tips[(index + 1) % 4]
        let a = tips[index]
        // Pull each concave edge toward the centre, short of it.
        let control = CGPoint(x: 8 + (a.x + next.x - 16) * 0.22, y: 8 + (a.y + next.y - 16) * 0.22)
        star.addQuadCurve(to: next, controlPoint: control)
      }
      star.close()
      stroke(star)
    },
    measurement: {
      // A dimension line between two end bars, with a ruler's ticks above it.
      let rule = UIBezierPath()
      rule.move(to: CGPoint(x: 2, y: 5.5))
      rule.addLine(to: CGPoint(x: 2, y: 13.5))
      rule.move(to: CGPoint(x: 14, y: 5.5))
      rule.addLine(to: CGPoint(x: 14, y: 13.5))
      rule.move(to: CGPoint(x: 2, y: 9.5))
      rule.addLine(to: CGPoint(x: 14, y: 9.5))
      for x in [5.0, 8.0, 11.0] {
        rule.move(to: CGPoint(x: x, y: 2.5))
        rule.addLine(to: CGPoint(x: x, y: x == 8 ? 6 : 4.5))
      }
      stroke(rule)
    },
    annotation: {
      // A note card with a folded corner and two lines of text.
      let card = UIBezierPath()
      card.move(to: CGPoint(x: 10, y: 14))
      card.addLine(to: CGPoint(x: 3.5, y: 14))
      card.addQuadCurve(to: CGPoint(x: 2, y: 12.5), controlPoint: CGPoint(x: 2, y: 14))
      card.addLine(to: CGPoint(x: 2, y: 3.5))
      card.addQuadCurve(to: CGPoint(x: 3.5, y: 2), controlPoint: CGPoint(x: 2, y: 2))
      card.addLine(to: CGPoint(x: 12.5, y: 2))
      card.addQuadCurve(to: CGPoint(x: 14, y: 3.5), controlPoint: CGPoint(x: 14, y: 2))
      card.addLine(to: CGPoint(x: 14, y: 10))
      card.addLine(to: CGPoint(x: 10, y: 14))
      card.addLine(to: CGPoint(x: 10, y: 10))
      card.addLine(to: CGPoint(x: 14, y: 10))
      card.move(to: CGPoint(x: 5, y: 5.5))
      card.addLine(to: CGPoint(x: 11, y: 5.5))
      card.move(to: CGPoint(x: 5, y: 8))
      card.addLine(to: CGPoint(x: 8.5, y: 8))
      stroke(card)
    },
    designMode: {
      // The pen nib of Folio's Design file icon, for the pill's Design segment.
      let nib = UIBezierPath()
      nib.move(to: CGPoint(x: 2.5, y: 13.5))
      nib.addLine(to: CGPoint(x: 4.2, y: 6.6))
      nib.addLine(to: CGPoint(x: 9.2, y: 4.6))
      nib.addLine(to: CGPoint(x: 11.4, y: 6.8))
      nib.addLine(to: CGPoint(x: 9.4, y: 11.8))
      nib.close()
      nib.move(to: CGPoint(x: 9.2, y: 4.6))
      nib.addLine(to: CGPoint(x: 10.9, y: 2.9))
      nib.addLine(to: CGPoint(x: 13.1, y: 5.1))
      nib.addLine(to: CGPoint(x: 11.4, y: 6.8))
      nib.move(to: CGPoint(x: 2.5, y: 13.5))
      nib.addLine(to: CGPoint(x: 6.1, y: 9.9))
      stroke(nib)
      stroke(UIBezierPath(ovalIn: CGRect(x: 6.1, y: 7.9, width: 2, height: 2)))
    },
  ]

  private static func stroke(_ path: UIBezierPath) {
    path.lineWidth = lineWidth
    path.lineJoinStyle = .round
    path.lineCapStyle = .round
    path.stroke()
  }

  private static func dashed(_ path: UIBezierPath) {
    path.setLineDash([1.6 / dash, 1.6 / dash], count: 2, phase: 0)
    path.lineWidth = lineWidth
    path.lineCapStyle = .butt
    path.stroke()
  }
}

/// One key for four arrows: flick toward a direction to press it, keep holding to auto-repeat
/// like a hardware key. Release sends key up.
@MainActor
final class FlickArrowControl: UIControl {
  var onArrow: ((String, Bool) -> Void)?
  var symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .light) {
    didSet { render() }
  }

  static let idle = "arrow.up.and.down.and.arrow.left.and.right"
  private let plate = UIView()
  private let image = UIImageView()
  private let haptics = UIImpactFeedbackGenerator(style: .light)
  private var origin = CGPoint.zero
  private var current: String?
  private var timer: Timer?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    plate.isUserInteractionEnabled = false
    plate.layer.cornerRadius = 6
    plate.layer.borderWidth = 1
    plate.translatesAutoresizingMaskIntoConstraints = false
    image.contentMode = .center
    image.translatesAutoresizingMaskIntoConstraints = false
    addSubview(plate)
    addSubview(image)
    NSLayoutConstraint.activate([
      plate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      plate.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      plate.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      plate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      image.centerXAnchor.constraint(equalTo: centerXAnchor),
      image.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    isAccessibilityElement = true
    toolTip = "Arrow keys: flick ← ↑ ↓ →, hold to repeat"
    accessibilityLabel = "Arrow keys"
    accessibilityHint = "Flick toward a direction to press that arrow key. Hold to repeat."
    accessibilityCustomActions = [
      ("Left", "ArrowLeft"), ("Up", "ArrowUp"), ("Down", "ArrowDown"), ("Right", "ArrowRight"),
    ].map { name, key in
      UIAccessibilityCustomAction(name: name) { [weak self] _ in
        self?.onArrow?(key, true)
        self?.onArrow?(key, false)
        return true
      }
    }
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.render() }
    render()
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic arrow control") }

  override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    origin = touch.location(in: self)
    haptics.prepare()
    return true
  }

  override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    let point = touch.location(in: self)
    let dx = point.x - origin.x
    let dy = point.y - origin.y
    guard max(abs(dx), abs(dy)) >= 12 else { return true }
    let key =
      abs(dx) > abs(dy) ? (dx < 0 ? "ArrowLeft" : "ArrowRight") : (dy < 0 ? "ArrowUp" : "ArrowDown")
    if key != current {
      stop()
      press(key)
    }
    return true
  }

  override func endTracking(_ touch: UITouch?, with event: UIEvent?) { stop() }
  override func cancelTracking(with event: UIEvent?) { stop() }

  private func press(_ key: String) {
    current = key
    step()
    render()
    // Hardware-like repeat: a pause, then a steady rate while the finger stays down.
    timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.current == key else { return }
        self.timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.step() }
        }
      }
    }
  }

  private func step() {
    guard let current else { return }
    onArrow?(current, true)
    haptics.impactOccurred(intensity: 0.6)
    haptics.prepare()
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
    if let current { onArrow?(current, false) }
    current = nil
    render()
  }

  private func render() {
    let symbol: String =
      switch current {
      case "ArrowLeft": "arrow.left"
      case "ArrowRight": "arrow.right"
      case "ArrowUp": "arrow.up"
      case "ArrowDown": "arrow.down"
      default: Self.idle
      }
    image.image = UIImage(systemName: symbol, withConfiguration: symbolConfiguration)
    image.tintColor = current == nil ? ChromePalette.icon : .white
    plate.backgroundColor = current == nil ? .clear : ChromePalette.figmaBlue
    plate.layer.borderColor =
      (current == nil ? ChromePalette.divider : ChromePalette.figmaBlue)
      .resolvedColor(with: traitCollection).cgColor
  }
}
