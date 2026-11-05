import UIKit

/// iPhone: Folio's floating tool pill, drawn natively in the style of the editor's own floating
/// tool bar (which phone-layout.ts hides) and sized for the phone: 40 pt buttons, a small chevron
/// beside each tool group, horizontal scrolling when it does not fit. Tools go out as Figma's own
/// keyboard shortcuts through `onKey`. Icons are SF Symbols or original drawings (ToolbarIcon).
///
/// Active tool: a tap highlights its tool at once (optimistic); Figma's report then wins, except
/// that a Move report keeps a Hand or Scale choice, because both live in Figma's Move group and
/// their own markers are unverified. A `.none` report never clears a local choice. Tapping the
/// active group again steps through its tools (PhonePillLogic.tap).
///
/// The tools mirror Figma's own row for the current mode (PhonePillLogic.layout): Design shows
/// Move, Frame, Shape, Drawing, Text, Comment and Actions; Dev Mode shows Move, Measurement,
/// Annotation and Comment. Every group exists from the start and only its visibility changes, so
/// a mode switch redraws in place without rebuilding. Dev Mode's Move has no Hand or Scale
/// variants: whether Figma cycles them there is unverified.
///
/// The pill ends in a Design | Dev segment showing Figma's reported mode. A tap sends Shift+D only
/// when it changes the mode; with the mode unknown neither segment is selected and a tap toggles.
/// The segment is pinned at the right edge; only the tools scroll, fading out at the edges where
/// more tools are hidden (like the bar's fixed Layers and Properties).
@MainActor
final class PhoneToolPill: UIView, UIScrollViewDelegate {
  static let buttonSize: CGFloat = 40
  static let chevronWidth: CGFloat = 14
  static let inset: CGFloat = 4
  /// Reports that disagree with a fresh tap wait this long for Figma to catch up.
  private static let grace: TimeInterval = 0.6
  private static let moveVariants: Set<PhoneTool> = [.hand, .scale]

  var onKey: ((String) -> Void)?
  var interfaceScale: CGFloat = 1 {
    didSet { if oldValue != interfaceScale { applyScale() } }
  }

  /// `tool` nil: a one-shot command in a group menu (Place image) that never becomes its face.
  private struct Variant {
    let tool: PhoneTool?
    let key: String
    let icon: String
    let label: String
    let shortcut: String
  }

  @MainActor private final class Group {
    let name: String
    let variants: [Variant]
    let button: UIButton
    var chevron: UIButton?
    var face: Variant

    init(name: String, variants: [Variant], button: UIButton) {
      self.name = name
      self.variants = variants
      self.button = button
      face = variants[0]
    }
  }

  /// A tool group: its name, Figma's top-level tool id, the row it belongs to (nil: both), and
  /// its variants.
  private struct Spec {
    let name: String
    let id: PhoneVisibleTool
    let dev: Bool?
    let variants: [Variant]
  }

  /// Tool groups in pill order, the union of Figma's two rows in their own order. Image or
  /// video… is a one-shot command (it opens a file picker), so it stays in the Shape menu but out
  /// of the tap cycle. Measurement and Annotation use Figma's documented Shift+M and Shift+T.
  private static let tools: [Spec] = [
    Spec(
      name: "Move", id: .move, dev: false,
      variants: [
        Variant(tool: .move, key: "move", icon: "cursorarrow", label: "Move", shortcut: "V"),
        Variant(tool: .hand, key: "hand", icon: "hand.raised", label: "Hand", shortcut: "H"),
        Variant(
          tool: .scale, key: "scale", icon: ToolbarIcon.scale, label: "Scale", shortcut: "K"),
      ]),
    Spec(
      name: "Move", id: .move, dev: true,
      variants: [
        Variant(tool: .move, key: "move", icon: "cursorarrow", label: "Move", shortcut: "V")
      ]),
    Spec(
      name: "Frame", id: .frame, dev: false,
      variants: [
        Variant(
          tool: .frame, key: "frame", icon: ToolbarIcon.frame, label: "Frame", shortcut: "F"),
        Variant(
          tool: .section, key: "section", icon: "square.dashed", label: "Section",
          shortcut: "⇧S"),
        Variant(tool: .slice, key: "slice", icon: "crop", label: "Slice", shortcut: "S"),
      ]),
    Spec(
      name: "Shape", id: .rectangle, dev: false,
      variants: [
        Variant(
          tool: .rectangle, key: "rectangle", icon: "square", label: "Rectangle", shortcut: "R"),
        Variant(tool: .line, key: "line", icon: "line.diagonal", label: "Line", shortcut: "L"),
        Variant(
          tool: .arrow, key: "arrow", icon: "arrow.up.right", label: "Arrow", shortcut: "⇧L"),
        Variant(tool: .ellipse, key: "ellipse", icon: "circle", label: "Ellipse", shortcut: "O"),
        Variant(
          tool: nil, key: "placeImage", icon: "photo", label: "Image or video…",
          shortcut: "⇧⌘K"),
      ]),
    Spec(
      name: "Drawing", id: .pen, dev: false,
      variants: [
        Variant(tool: .pen, key: "pen", icon: "pencil.tip", label: "Pen", shortcut: "P"),
        Variant(tool: .pencil, key: "pencil", icon: "pencil", label: "Pencil", shortcut: "⇧P"),
      ]),
    Spec(
      name: "Text", id: .text, dev: false,
      variants: [
        Variant(tool: .text, key: "text", icon: ToolbarIcon.text, label: "Text", shortcut: "T")
      ]),
    Spec(
      name: "Measurement", id: .measurement, dev: true,
      variants: [
        Variant(
          tool: .measurement, key: "measurement", icon: ToolbarIcon.measurement,
          label: "Measurement", shortcut: "⇧M")
      ]),
    Spec(
      name: "Annotation", id: .annotation, dev: true,
      variants: [
        Variant(
          tool: .annotation, key: "annotation", icon: ToolbarIcon.annotation, label: "Annotation",
          shortcut: "⇧T")
      ]),
    Spec(
      name: "Comment", id: .comment, dev: nil,
      variants: [
        Variant(
          tool: .comment, key: "comment", icon: "bubble.left", label: "Comment", shortcut: "C")
      ]),
  ]

  /// Each group's tap cycle, in menu order.
  static var cycles: [[PhoneTool]] { tools.map { $0.variants.compactMap(\.tool) } }

  private let scroll = UIScrollView()
  private let stack = UIStackView()
  /// Divider and Design | Dev segment, outside the scroll view.
  private let pinned = UIStackView()
  private let fade = CAGradientLayer()
  private var pinnedTrailing: NSLayoutConstraint!
  private var groups: [Group] = []
  /// Every group's cell (and Actions) with Figma's tool id and row, shown per PhonePillLogic.layout.
  private var cells: [(view: UIView, id: PhoneVisibleTool, dev: Bool?)] = []
  private var reportedTools: [PhoneVisibleTool] = []
  private var icons: [(button: UIButton, icon: String)] = []
  private var sizes: [(constraint: NSLayoutConstraint, base: CGFloat)] = []
  private var heightConstraint: NSLayoutConstraint!
  private let haptics = UISelectionFeedbackGenerator()

  private var local: PhoneTool?
  private var localAt: TimeInterval = -.infinity
  private var reported = PhoneTool.none
  private var graceTask: Task<Void, Never>?
  private var localMode: PhoneMode?
  private var localModeAt: TimeInterval = -.infinity
  private var reportedMode = PhoneMode.unknown
  private let segment = UIStackView()
  private var modeButtons: [(button: UIButton, mode: PhoneMode)] = []
  private(set) var shown = true
  /// What the last render showed; nil forces the next one.
  private var rendered: String?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    accessibilityIdentifier = "phone-tool-pill"
    backgroundColor = ChromePalette.bar
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOffset = CGSize(width: 0, height: 2)
    layer.shadowRadius = 8
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.delegate = self
    scroll.showsHorizontalScrollIndicator = false
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.alwaysBounceHorizontal = false
    scroll.clipsToBounds = true
    fade.startPoint = CGPoint(x: 0, y: 0.5)
    fade.endPoint = CGPoint(x: 1, y: 0.5)
    stack.axis = .horizontal
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.isLayoutMarginsRelativeArrangement = true
    pinned.axis = .horizontal
    pinned.alignment = .center
    pinned.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scroll)
    addSubview(pinned)
    scroll.addSubview(stack)

    for spec in Self.tools { addGroup(spec) }
    let actions = command(
      Variant(
        tool: nil, key: "actions", icon: ToolbarIcon.actions, label: "Actions", shortcut: "⌘K"))
    stack.addArrangedSubview(actions)
    cells.append((actions, .actions, false))
    pinned.addArrangedSubview(divider())
    pinned.addArrangedSubview(modeSegment())

    heightConstraint = heightAnchor.constraint(equalToConstant: 0)
    pinnedTrailing = pinned.trailingAnchor.constraint(equalTo: trailingAnchor)
    // Hug the tools and the segment; the owner caps the width, and the tools scroll past it.
    let hugPinned = scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
    hugPinned.priority = .defaultHigh + 1
    NSLayoutConstraint.activate([
      heightConstraint, hugPinned,
      scroll.topAnchor.constraint(equalTo: topAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: pinned.leadingAnchor),
      pinned.centerYAnchor.constraint(equalTo: centerYAnchor),
      pinnedTrailing,
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
    ])
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
      self.applyAppearance()
    }
    applyAppearance()
    applyScale()
    render()
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic tool pill") }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    updateFade()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) { updateFade() }

  /// Fades the tools out at an edge only where more tools lie beyond it.
  private func updateFade() {
    let width = scroll.bounds.width
    let hidden = scroll.contentSize.width - width
    guard width > 0, hidden > 1 else {
      scroll.layer.mask = nil
      return
    }
    let edge = min(0.25, 20 / width)
    let x = scroll.contentOffset.x
    let start = x > 1 ? UIColor.clear : UIColor.black
    let end = x < hidden - 1 ? UIColor.clear : UIColor.black
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fade.frame = scroll.bounds
    fade.colors = [start, .black, .black, end].map(\.cgColor)
    fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
    scroll.layer.mask = fade
    CATransaction.commit()
  }

  // MARK: Active tool

  /// Figma's active tool, editor mode and visible tool row from phone-layout.ts. A nil row (a
  /// sheet request's reply, which carries none) keeps the last reported row.
  func report(_ tool: PhoneTool, mode: PhoneMode = .unknown, tools: [PhoneVisibleTool]? = nil) {
    reported = tool
    reportedMode = mode
    if let tools { reportedTools = tools }
    reconcile()
  }

  /// New tab or layout off: forget the local choice.
  func reset() {
    graceTask?.cancel()
    local = nil
    localAt = -.infinity
    reported = .none
    localMode = nil
    localModeAt = -.infinity
    reportedMode = .unknown
    reportedTools = []
    render()
  }

  /// Reports that disagree with a fresh tap wait out the grace period.
  private func reconcile() {
    let now = ProcessInfo.processInfo.systemUptime
    if let local, now - localAt >= Self.grace, reported != .none,
      !(reported == .move && Self.moveVariants.contains(local))
    {
      self.local = nil
    }
    if localMode != nil, now - localModeAt >= Self.grace, reportedMode != .unknown {
      localMode = nil
    }
    render()
  }

  private func scheduleReconcile() {
    graceTask?.cancel()
    graceTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(Self.grace))
      guard !Task.isCancelled else { return }
      self?.reconcile()
    }
  }

  private var mode: PhoneMode { localMode ?? reportedMode }

  private func chooseMode(_ target: PhoneMode) {
    let current = mode
    guard PhonePillLogic.sendsToggle(tapped: target, current: current) else { return }
    onKey?("toggleDevMode")
    // Unknown: the toggle's direction is unknown too, so wait for Figma's report.
    guard current != .unknown else { return }
    haptics.selectionChanged()
    localMode = target
    localModeAt = ProcessInfo.processInfo.systemUptime
    render()
    scheduleReconcile()
  }

  private var current: PhoneTool? {
    local ?? (reported == .none ? nil : reported)
  }

  private func choose(_ variant: Variant) {
    onKey?(variant.key)
    guard let tool = variant.tool else { return }
    if current != tool { haptics.selectionChanged() }
    local = tool
    localAt = ProcessInfo.processInfo.systemUptime
    render()
    scheduleReconcile()
  }

  /// Repeated identical reports (every selection re-posts Figma's state) change nothing.
  private func render() {
    let tool = current
    let key = "\(tool.map(\.rawValue) ?? "-")|\(mode.rawValue)|\(reportedTools.map(\.rawValue))"
    guard key != rendered else { return }
    rendered = key
    for group in groups {
      if let tool, let variant = group.variants.first(where: { $0.tool == tool }) {
        adopt(variant, in: group)
      }
      let selected = tool != nil && group.face.tool == tool
      group.button.isSelected = selected
      group.button.accessibilityTraits = selected ? [.button, .selected] : .button
      group.chevron?.menu = menu(for: group)
      group.button.menu = group.chevron?.menu
    }
    let mode = mode
    let layout = PhonePillLogic.layout(reported: reportedTools, mode: mode)
    var changed = false
    for cell in cells {
      let hidden = !layout.tools.contains(cell.id) || (cell.dev.map { $0 != layout.dev } ?? false)
      if cell.view.isHidden != hidden {
        cell.view.isHidden = hidden
        changed = true
      }
    }
    if changed { setNeedsLayout() }
    for (button, value) in modeButtons {
      button.isSelected = value == mode
      button.accessibilityTraits = value == mode ? [.button, .selected] : .button
    }
  }

  /// A group shows the last chosen or reported variant, like the editor's own tool groups.
  private func adopt(_ variant: Variant, in group: Group) {
    guard group.face.key != variant.key else { return }
    group.face = variant
    group.button.accessibilityLabel = variant.label
    group.button.largeContentTitle = variant.label
    group.button.toolTip = "\(variant.label) \(variant.shortcut)"
    if let index = icons.firstIndex(where: { $0.button === group.button }) {
      icons[index].icon = variant.icon
    }
    applyScale()
  }

  // MARK: Building

  private func addGroup(_ spec: Spec) {
    let name = spec.name
    let variants = spec.variants
    let first = variants[0]
    let button = self.button(first.icon, first.label, "\(first.label) \(first.shortcut)")
    selectableLook(button)
    let group = Group(name: name, variants: variants, button: button)
    groups.append(group)
    button.addAction(
      UIAction { [weak self, weak group] _ in
        guard let self, let group, let face = group.face.tool else { return }
        let next = PhonePillLogic.tap(
          face: face, current: self.current, cycle: group.variants.compactMap(\.tool))
        self.choose(group.variants.first { $0.tool == next } ?? group.face)
      }, for: .touchUpInside)
    let cell = UIStackView(arrangedSubviews: [button])
    cell.axis = .horizontal
    cell.alignment = .center
    if variants.count > 1 {
      button.accessibilityHint = "Tap again for the next tool. Touch and hold for all tools."
      var configuration = UIButton.Configuration.plain()
      configuration.contentInsets = .zero
      let chevron = UIButton(configuration: configuration)
      chevron.translatesAutoresizingMaskIntoConstraints = false
      chevron.showsMenuAsPrimaryAction = true
      chevron.accessibilityLabel = "\(name) tools"
      chevron.configurationUpdateHandler = { button in
        var configuration = button.configuration
        configuration?.baseForegroundColor =
          button.isHighlighted ? ChromePalette.primaryText : ChromePalette.icon
        button.configuration = configuration
      }
      size(chevron, width: Self.chevronWidth)
      icons.append((chevron, "chevron.down"))
      group.chevron = chevron
      cell.addArrangedSubview(chevron)
    }
    stack.addArrangedSubview(cell)
    cells.append((cell, spec.id, spec.dev))
  }

  private func menu(for group: Group) -> UIMenu? {
    guard group.variants.count > 1 else { return nil }
    let tool = current
    return UIMenu(
      title: group.name,
      children: group.variants.map { variant in
        UIAction(
          title: variant.label, subtitle: variant.shortcut,
          image: ToolbarIcon.image(variant.icon, pointSize: BottomToolbarView.iconPointSize),
          state: variant.tool != nil && variant.tool == tool ? .on : .off
        ) { [weak self] _ in self?.choose(variant) }
      })
  }

  private func command(_ variant: Variant) -> UIButton {
    let button = self.button(variant.icon, variant.label, "\(variant.label) \(variant.shortcut)")
    button.addAction(
      UIAction { [weak self] _ in self?.onKey?(variant.key) }, for: .touchUpInside)
    return button
  }

  private func button(_ icon: String, _ label: String, _ tip: String) -> UIButton {
    let button = ChromeTabView.segmentButton(icon, label: label)
    button.largeContentTitle = label
    button.showsLargeContentViewer = true
    button.addInteraction(UILargeContentViewerInteraction())
    button.toolTip = tip
    size(button, width: Self.buttonSize)
    icons.append((button, icon))
    return button
  }

  private func size(_ view: UIView, width: CGFloat) {
    let w = view.widthAnchor.constraint(equalToConstant: width)
    let h = view.heightAnchor.constraint(equalToConstant: Self.buttonSize)
    NSLayoutConstraint.activate([w, h])
    sizes.append((w, width))
    sizes.append((h, Self.buttonSize))
  }

  /// Solid blue with a white glyph while selected, the editor's selected-tool look.
  private func selectableLook(_ button: UIButton) {
    button.configurationUpdateHandler = { button in
      var configuration = button.configuration
      var background = UIBackgroundConfiguration.clear()
      background.cornerRadius = 7
      background.backgroundInsets = .init(top: 2, leading: 2, bottom: 2, trailing: 2)
      background.backgroundColor =
        button.isSelected
        ? ChromePalette.figmaBlue
        : button.isHovered || button.isHighlighted ? ChromePalette.hover : .clear
      configuration?.background = background
      configuration?.baseForegroundColor = button.isSelected ? .white : ChromePalette.icon
      button.configuration = configuration
    }
  }

  /// Design | Dev, like the segment at the end of the editor's own tool bar: a rounded track
  /// with the selected side filled (neutral for Design, the editor's green for Dev).
  private func modeSegment() -> UIView {
    segment.axis = .horizontal
    segment.alignment = .center
    segment.backgroundColor = ChromePalette.segmentTrack
    segment.layer.cornerCurve = .continuous
    segment.accessibilityLabel = "Editor mode"
    for (mode, icon, label) in [
      (PhoneMode.design, ToolbarIcon.designMode, "Design"),
      (PhoneMode.dev, "chevron.left.forwardslash.chevron.right", "Dev Mode"),
    ] {
      let button = self.button(icon, label, "\(label) ⇧D")
      button.configurationUpdateHandler = { button in
        var configuration = button.configuration
        var background = UIBackgroundConfiguration.clear()
        background.cornerRadius = 7
        background.backgroundInsets = .init(top: 4, leading: 4, bottom: 4, trailing: 4)
        let dev = mode == .dev
        background.backgroundColor =
          button.isSelected
          ? (dev ? ChromePalette.devGreen : ChromePalette.bar)
          : button.isHighlighted ? ChromePalette.hover : .clear
        if button.isSelected, !dev {
          background.strokeColor = ChromePalette.floatingEdge
          background.strokeWidth = 1
        }
        configuration?.background = background
        configuration?.baseForegroundColor =
          button.isSelected ? (dev ? .white : ChromePalette.primaryText) : ChromePalette.icon
        button.configuration = configuration
      }
      button.addAction(
        UIAction { [weak self] _ in self?.chooseMode(mode) }, for: .touchUpInside)
      modeButtons.append((button, mode))
      segment.addArrangedSubview(button)
    }
    return segment
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
    wrapper.directionalLayoutMargins = .init(top: 0, leading: 4, bottom: 0, trailing: 4)
    wrapper.alignment = .center
    return wrapper
  }

  // MARK: Appearance

  /// Shown or hidden with a short fade and a small drop; no movement with Reduce Motion.
  func setShown(_ visible: Bool, animated: Bool) {
    guard visible != shown else { return }
    shown = visible
    if visible { isHidden = false }
    let offset = UIAccessibility.isReduceMotionEnabled ? 0 : 6.0
    let changes = {
      self.alpha = visible ? 1 : 0
      self.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: offset)
    }
    guard animated else {
      changes()
      isHidden = !visible
      return
    }
    UIView.animate(
      withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction],
      animations: changes
    ) { _ in
      if !self.shown { self.isHidden = true }
    }
  }

  private func applyAppearance() {
    let dark = traitCollection.userInterfaceStyle == .dark
    layer.borderColor = ChromePalette.floatingEdge.resolvedColor(with: traitCollection).cgColor
    layer.shadowOpacity = dark ? 0.35 : 0.15
  }

  private func applyScale() {
    let pixels = max(1, traitCollection.displayScale)
    let snap = { (value: CGFloat) in (value * pixels).rounded() / pixels }
    // Like the phone bar: never smaller than the 100% size, whatever the interface zoom.
    let scale = max(1, interfaceScale)
    for (constraint, base) in sizes { constraint.constant = snap(base * scale) }
    // The editor's 48 pt tool bar: 40 pt buttons with 4 pt insets.
    let inset = snap(Self.inset * scale)
    stack.directionalLayoutMargins = .init(
      top: inset, leading: inset, bottom: inset, trailing: 0)
    pinnedTrailing.constant = -inset
    heightConstraint.constant = snap(Self.buttonSize * scale) + 2 * inset
    layer.cornerRadius = snap(12 * scale)
    segment.layer.cornerRadius = snap(9 * scale)
    let pointSize = BottomToolbarView.iconPointSize * scale
    for (button, icon) in icons {
      button.configuration?.image =
        icon == "chevron.down"
        ? ToolbarIcon.chevron(pointSize: pointSize) : ToolbarIcon.image(icon, pointSize: pointSize)
      button.configuration?.preferredSymbolConfigurationForImage = nil
    }
    setNeedsLayout()
  }
}
