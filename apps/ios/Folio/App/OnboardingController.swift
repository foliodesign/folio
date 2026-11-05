import UIKit

/// Welcome tour: shown once on first launch, replayable from ⋯ and Settings > General.
/// It writes only through existing stores (touch mode, Pencil bindings) and only when the
/// user picks something; untouched choices keep their automatic defaults. It never looks at
/// or drives Figma sign-in.
@MainActor
final class OnboardingController: UIViewController, UIScrollViewDelegate {
  private enum Page { case welcome, touch, pencil, tour, done }

  /// Presents the tour unless the presenter is busy, and records it as seen.
  static func present(from presenter: UIViewController) {
    guard presenter.presentedViewController == nil else { return }
    FolioPreferences().onboardingSeen = true
    let tour = OnboardingController()
    tour.modalPresentationStyle = .formSheet
    tour.preferredContentSize = CGSize(width: 560 * tour.scale, height: 680 * tour.scale)
    presenter.present(tour, animated: true)
  }

  private let phone = PhoneExperiencePolicy.isPhone
  /// Follows interface zoom like the chrome, floored so small phone zooms stay legible.
  private let scale = CGFloat(max(0.85, FolioWindows.zoom.state.scale))
  /// Phones without proven Pencil support (not a Duo) are Touch Only, so the tour skips both
  /// the touch-mode and the Pencil pages.
  private lazy var pages: [Page] =
    PhoneExperiencePolicy.supportsPencil()
    ? [.welcome, .touch, .pencil, .tour, .done]
    : [.welcome, .tour, .done]
  private var page = 0
  private var laidOutWidth: CGFloat = 0
  private let pager = UIScrollView()
  private let pageControl = UIPageControl()
  private let skipButton = UIButton(type: .system)
  private let backButton = UIButton(type: .system)
  private let nextButton = UIButton(type: .system)
  private var touchCards: [(TouchMode, UIButton)] = []

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "folioOnboarding"
    view.backgroundColor = ChromePalette.bar
    view.tintColor = ChromePalette.figmaBlue

    pager.isPagingEnabled = true
    pager.showsHorizontalScrollIndicator = false
    pager.alwaysBounceVertical = false
    pager.delegate = self
    let strip = UIStackView(arrangedSubviews: pages.map(makePage))
    strip.axis = .horizontal
    strip.distribution = .fillEqually
    pager.addSubview(strip)

    skipButton.configuration = plainConfiguration("Skip")
    skipButton.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
    backButton.configuration = plainConfiguration("Back")
    backButton.addAction(
      UIAction { [weak self] _ in self?.go(to: (self?.page ?? 1) - 1) }, for: .touchUpInside)
    nextButton.addAction(UIAction { [weak self] _ in self?.advance() }, for: .touchUpInside)
    pageControl.numberOfPages = pages.count
    pageControl.currentPageIndicatorTintColor = ChromePalette.primaryText
    pageControl.pageIndicatorTintColor = ChromePalette.divider
    pageControl.addAction(
      UIAction { [weak self] _ in self?.go(to: self?.pageControl.currentPage ?? 0) },
      for: .valueChanged)

    for item in [pager, strip, skipButton, backButton, nextButton, pageControl] as [UIView] {
      item.translatesAutoresizingMaskIntoConstraints = false
    }
    for item in [pager, skipButton, backButton, nextButton, pageControl] as [UIView] {
      view.addSubview(item)
    }
    let safe = view.safeAreaLayoutGuide
    let inset = (phone ? 16 : 20) * scale
    NSLayoutConstraint.activate([
      skipButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10 * scale),
      skipButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -inset),
      pager.topAnchor.constraint(equalTo: skipButton.bottomAnchor),
      pager.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      pager.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      pager.bottomAnchor.constraint(equalTo: nextButton.topAnchor, constant: -12 * scale),
      strip.topAnchor.constraint(equalTo: pager.contentLayoutGuide.topAnchor),
      strip.bottomAnchor.constraint(equalTo: pager.contentLayoutGuide.bottomAnchor),
      strip.leadingAnchor.constraint(equalTo: pager.contentLayoutGuide.leadingAnchor),
      strip.trailingAnchor.constraint(equalTo: pager.contentLayoutGuide.trailingAnchor),
      strip.heightAnchor.constraint(equalTo: pager.frameLayoutGuide.heightAnchor),
      strip.widthAnchor.constraint(
        equalTo: pager.frameLayoutGuide.widthAnchor, multiplier: CGFloat(pages.count)),
      nextButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -inset),
      nextButton.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -inset),
      nextButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 40 * scale),
      backButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: inset),
      backButton.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
      pageControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      pageControl.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
    ])
    updateControls()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // Keep the current page in place across rotation and sheet resizing.
    guard pager.bounds.width != laidOutWidth else { return }
    laidOutWidth = pager.bounds.width
    pager.contentOffset = CGPoint(x: CGFloat(page) * laidOutWidth, y: 0)
  }

  override var keyCommands: [UIKeyCommand]? {
    let commands = [
      UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(skip)),
      UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(continueCommand)),
      UIKeyCommand(
        input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(continueCommand)),
      UIKeyCommand(
        input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(previous)),
    ]
    for command in commands { command.wantsPriorityOverSystemBehavior = true }
    return commands
  }
  @objc private func skip() { finish() }
  @objc private func continueCommand() { advance() }
  @objc private func previous() { go(to: page - 1) }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === pager, pager.isDragging || pager.isDecelerating,
      pager.bounds.width > 0
    else { return }
    let current = min(
      pages.count - 1, max(0, Int((pager.contentOffset.x / pager.bounds.width).rounded())))
    if current != page {
      page = current
      updateControls()
    }
  }

  private func advance() {
    if page == pages.count - 1 { finish() } else { go(to: page + 1) }
  }

  private func go(to index: Int) {
    guard pages.indices.contains(index) else { return }
    page = index
    pager.setContentOffset(CGPoint(x: CGFloat(index) * pager.bounds.width, y: 0), animated: true)
    updateControls()
  }

  private func finish() { dismiss(animated: true) }

  private func updateControls() {
    let last = page == pages.count - 1
    pageControl.currentPage = page
    backButton.isHidden = page == 0
    skipButton.isHidden = last
    var next = UIButton.Configuration.filled()
    next.baseBackgroundColor = ChromePalette.figmaBlue
    next.baseForegroundColor = .white
    next.cornerStyle = .medium
    next.contentInsets = .init(
      top: 8 * scale, leading: 18 * scale, bottom: 8 * scale, trailing: 18 * scale)
    next.title = last ? "Get started" : "Continue"
    next.titleTextAttributesTransformer = font(15, .semibold)
    nextButton.configuration = next
  }

  // MARK: - Pages

  private func makePage(_ page: Page) -> UIView {
    let content: [UIView]
    switch page {
    case .welcome:
      content =
        [
          heading("square.on.square", "Welcome to Folio"),
          body(
            "Folio opens figma.com directly in a native browser and adds tabs, windows and \(phone ? "iPhone" : "iPad") input. It's an independent app, not made by or affiliated with Figma."
          ),
          note(
            "person.badge.key",
            "Sign in with your email and password or your organization's SSO. Google sign-in doesn't work in embedded browsers, so Folio hides that option on Figma's sign-in page."
          ),
        ]
        + (PhoneExperiencePolicy.supportsPencil()
          ? []
          : [
            note(
              "hand.point.up.left",
              "One finger points and drags on the canvas (Touch Only); two fingers pan.")
          ])
    case .touch:
      let current = InputStrategies().touchMode
      touchCards = TouchMode.allCases.map { mode in
        let card = UIButton(type: .system)
        card.accessibilityIdentifier = "folioOnboarding-\(mode.rawValue)"
        card.addAction(
          UIAction { [weak self] _ in self?.chooseTouchMode(mode) }, for: .touchUpInside)
        return (mode, card)
      }
      renderTouchCards(selected: current)
      content =
        [
          heading("hand.point.up.left", "How do you work?"),
          body("Pick how one finger behaves on the canvas."),
        ] + touchCards.map(\.1) + [caption("You can change this any time in Settings > Input.")]
    case .pencil:
      content = [
        heading("applepencil.tip", "Apple Pencil shortcuts"),
        body("Choose what Apple Pencil gestures do in Folio. Drawing itself is unchanged."),
        pencilRow(
          squeeze: false, symbol: "hand.tap", title: "Double-tap",
          detail: "Supported Apple Pencil models"),
        pencilRow(
          squeeze: true, symbol: "hand.pinch", title: "Squeeze", detail: "Apple Pencil Pro"),
        caption("Also in Settings > Input > Apple Pencil."),
      ]
    case .tour:
      var rows = [
        tourRow(
          "square.on.square", "Tabs",
          phone
            ? "Files open as tabs. The tab button switches between them; Home is always there."
            : "Files open in tabs. Drag a tab to reorder it or move it to another window; pin it from its menu."
        ),
        tourRow(
          "keyboard", "Bottom toolbar",
          phone
            ? "In a file it holds Figma's tools, panel toggles and edit commands. Keys opens Shift, Control, Option, Command and arrows."
            : "In a file it holds Shift, Control, Option and Command, arrow keys, and edit commands. Tap a modifier to keep it on; tap again to release."
        ),
        tourRow(
          "ellipsis.circle", "The ⋯ menu",
          "Interface zoom, downloads, the toolbars, Settings and this tour."),
      ]
      rows.append(shortcuts())
      content = [heading("map", "A quick tour")] + rows
    case .done:
      content = [
        heading("checkmark.circle", "You're set"),
        body("Folio opens Figma's Home next. Sign in there if you haven't already."),
        caption("Replay this tour from ⋯ > Welcome tour or Settings > General."),
      ]
    }
    let stack = UIStackView(arrangedSubviews: content)
    stack.axis = .vertical
    stack.spacing = 14 * scale
    if let first = content.first { stack.setCustomSpacing(18 * scale, after: first) }
    return scrollingPage(stack)
  }

  private func scrollingPage(_ stack: UIStackView) -> UIView {
    let scroll = UIScrollView()
    scroll.alwaysBounceVertical = false
    let container = UIView()
    for item in [container, stack] { item.translatesAutoresizingMaskIntoConstraints = false }
    scroll.addSubview(container)
    container.addSubview(stack)
    let pad = (phone ? 24 : 40) * scale
    let fill = stack.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -2 * pad)
    // Above the labels' compression resistance, so multi-line text cannot narrow the column.
    fill.priority = .required - 1
    NSLayoutConstraint.activate([
      container.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      container.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      container.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      container.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      container.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
      container.heightAnchor.constraint(
        greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
      stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      stack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 8 * scale),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460 * scale),
      fill,
    ])
    return scroll
  }

  private func chooseTouchMode(_ mode: TouchMode) {
    // An explicit choice, saved like the Settings control; it wins over automatic detection.
    InputStrategies().touchMode = mode
    renderTouchCards(selected: mode)
  }

  private func renderTouchCards(selected: TouchMode) {
    for (mode, card) in touchCards {
      let chosen = mode == selected
      var configuration = UIButton.Configuration.plain()
      configuration.title = mode.title
      configuration.subtitle =
        mode == .pencilAndTouch
        ? "One finger pans the canvas. Apple Pencil draws, selects and drags."
        : "One finger points and drags like a mouse. Two fingers pan."
      configuration.image = symbol(
        mode == .pencilAndTouch ? "applepencil.and.scribble" : "hand.point.up.left", 20)
      configuration.imagePlacement = .leading
      configuration.imagePadding = 14 * scale
      configuration.titleAlignment = .leading
      configuration.titlePadding = 3 * scale
      configuration.titleTextAttributesTransformer = font(15, .semibold, ChromePalette.primaryText)
      configuration.subtitleTextAttributesTransformer = font(
        13, .regular, ChromePalette.secondaryText)
      configuration.baseForegroundColor = chosen ? ChromePalette.figmaBlue : ChromePalette.icon
      configuration.contentInsets = .init(
        top: 14 * scale, leading: 16 * scale, bottom: 14 * scale, trailing: 16 * scale)
      configuration.background.backgroundColor = ChromePalette.selectedTab
      configuration.background.cornerRadius = 10 * scale
      configuration.background.strokeColor =
        chosen ? ChromePalette.figmaBlue : ChromePalette.divider
      configuration.background.strokeWidth = chosen ? 2 : 1
      card.configuration = configuration
      card.contentHorizontalAlignment = .leading
      card.accessibilityTraits = chosen ? [.button, .selected] : .button
    }
  }

  private func pencilRow(squeeze: Bool, symbol name: String, title: String, detail: String)
    -> UIView
  {
    let preferences = FolioPreferences()
    let current = preferences.pencilBinding(squeeze: squeeze)
    let picker = UIButton(type: .system)
    picker.accessibilityIdentifier = "folioOnboarding-\(squeeze ? "squeeze" : "doubleTap")"
    picker.accessibilityLabel = title
    picker.menu = UIMenu(
      children: preferences.pencilActions.map { action in
        UIAction(
          title: action.title, image: UIImage(systemName: action.symbol),
          state: action == current ? .on : .off
        ) { _ in preferences.setPencilBinding(action, squeeze: squeeze) }
      })
    picker.showsMenuAsPrimaryAction = true
    picker.changesSelectionAsPrimaryAction = true
    var configuration = UIButton.Configuration.plain()
    configuration.indicator = .popup
    configuration.baseForegroundColor = ChromePalette.primaryText
    configuration.titleTextAttributesTransformer = font(14, .medium, ChromePalette.primaryText)
    configuration.background.backgroundColor = ChromePalette.hover
    configuration.background.cornerRadius = 8 * scale
    configuration.contentInsets = .init(
      top: 7 * scale, leading: 12 * scale, bottom: 7 * scale, trailing: 10 * scale)
    picker.configuration = configuration
    picker.setContentCompressionResistancePriority(.required, for: .horizontal)
    picker.setContentHuggingPriority(.required, for: .horizontal)

    let labels = UIStackView(arrangedSubviews: [
      label(title, 15, .semibold, ChromePalette.primaryText), label(detail, 12),
    ])
    labels.axis = .vertical
    labels.spacing = 2 * scale
    let row = UIStackView(arrangedSubviews: [tile(name, 32), labels, picker])
    row.alignment = .center
    row.spacing = 12 * scale
    return card(row)
  }

  private func tourRow(_ name: String, _ title: String, _ text: String) -> UIView {
    let labels = UIStackView(arrangedSubviews: [
      label(title, 15, .semibold, ChromePalette.primaryText), label(text, 13),
    ])
    labels.axis = .vertical
    labels.spacing = 3 * scale
    let row = UIStackView(arrangedSubviews: [tile(name, 32), labels])
    row.alignment = .top
    row.spacing = 12 * scale
    return row
  }

  private func shortcuts() -> UIView {
    let pairs = [
      ("⌃⌘1–9", "Select a tab"), ("⌃⌘W", "Close tab"), ("⌃⇧⌘T", "Reopen closed tab"),
      ("⌃⇧⌘B", "Bottom toolbar"), ("⌥⌘= ⌥⌘−", "Interface zoom"), ("⌘,", "Settings"),
    ]
    let rows = pairs.map { keys, action in
      let key = label(keys, 13, .medium, ChromePalette.primaryText)
      key.widthAnchor.constraint(equalToConstant: 92 * scale).isActive = true
      key.font = .monospacedDigitSystemFont(ofSize: 13 * scale, weight: .medium)
      let row = UIStackView(arrangedSubviews: [key, label(action, 13)])
      row.spacing = 10 * scale
      return row as UIView
    }
    let title = label("With a keyboard", 13, .semibold, ChromePalette.primaryText)
    let stack = UIStackView(arrangedSubviews: [title] + rows)
    stack.axis = .vertical
    stack.spacing = 6 * scale
    stack.setCustomSpacing(10 * scale, after: title)
    return card(stack)
  }

  // MARK: - Building blocks

  private func heading(_ name: String, _ text: String) -> UIView {
    let title = label(text, phone ? 24 : 26, .bold, ChromePalette.primaryText)
    let stack = UIStackView(arrangedSubviews: [tile(name, 56), title])
    stack.axis = .vertical
    stack.alignment = .leading
    stack.spacing = 16 * scale
    title.accessibilityTraits = .header
    return stack
  }

  private func body(_ text: String) -> UILabel { label(text, 15) }

  private func caption(_ text: String) -> UILabel {
    label(text, 12, .regular, ChromePalette.secondaryText.withAlphaComponent(0.8))
  }

  private func note(_ name: String, _ text: String) -> UIView {
    let image = UIImageView(image: symbol(name, 15))
    image.tintColor = ChromePalette.icon
    image.setContentHuggingPriority(.required, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [image, label(text, 13)])
    row.alignment = .firstBaseline
    row.spacing = 10 * scale
    return card(row, fill: ChromePalette.groupFill, border: false)
  }

  private func card(
    _ content: UIView, fill: UIColor = ChromePalette.selectedTab, border: Bool = true
  )
    -> UIView
  {
    let box = UIView()
    box.backgroundColor = fill
    box.layer.cornerRadius = 10 * scale
    box.layer.cornerCurve = .continuous
    if border {
      box.layer.borderWidth = 1
      box.layer.borderColor = ChromePalette.divider.resolvedColor(with: traitCollection).cgColor
      registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (owner: Self, _) in
        box.layer.borderColor =
          ChromePalette.divider.resolvedColor(with: owner.traitCollection)
          .cgColor
      }
    }
    content.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(content)
    let pad = 14 * scale
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: box.topAnchor, constant: pad),
      content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -pad),
      content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: pad),
      content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -pad),
    ])
    return box
  }

  /// Original SF Symbol on a rounded tile in the selected-tab grey.
  private func tile(_ name: String, _ size: CGFloat) -> UIView {
    let box = UIView()
    box.backgroundColor = ChromePalette.hover
    box.layer.cornerRadius = size * scale * 0.26
    box.layer.cornerCurve = .continuous
    let image = UIImageView(image: symbol(name, size * 0.46))
    image.tintColor = ChromePalette.figmaBlue
    image.contentMode = .center
    for item in [box, image] { item.translatesAutoresizingMaskIntoConstraints = false }
    box.addSubview(image)
    NSLayoutConstraint.activate([
      box.widthAnchor.constraint(equalToConstant: size * scale),
      box.heightAnchor.constraint(equalToConstant: size * scale),
      image.centerXAnchor.constraint(equalTo: box.centerXAnchor),
      image.centerYAnchor.constraint(equalTo: box.centerYAnchor),
    ])
    box.isAccessibilityElement = false
    return box
  }

  private func symbol(_ name: String, _ size: CGFloat) -> UIImage? {
    UIImage(
      systemName: name,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: size * scale, weight: .regular))
  }

  private func label(
    _ text: String, _ size: CGFloat, _ weight: UIFont.Weight = .regular,
    _ color: UIColor = ChromePalette.secondaryText
  ) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .systemFont(ofSize: size * scale, weight: weight)
    label.textColor = color
    label.numberOfLines = 0
    return label
  }

  private func plainConfiguration(_ title: String) -> UIButton.Configuration {
    var configuration = UIButton.Configuration.plain()
    configuration.title = title
    configuration.baseForegroundColor = ChromePalette.secondaryText
    configuration.titleTextAttributesTransformer = font(15, .medium)
    return configuration
  }

  private func font(_ size: CGFloat, _ weight: UIFont.Weight, _ color: UIColor? = nil)
    -> UIConfigurationTextAttributesTransformer
  {
    let font = UIFont.systemFont(ofSize: size * scale, weight: weight)
    return UIConfigurationTextAttributesTransformer {
      var attributes = $0
      attributes.font = font
      if let color { attributes.foregroundColor = color }
      return attributes
    }
  }
}
