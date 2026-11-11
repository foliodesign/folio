import UIKit

/// Read-only, transient rendering values. No view/controller, history items or persisted titles.
struct B3BrowserChromeState {
  struct Tab {
    let id: UUID
    let home: Bool
    let title: String?
    let pinned: Bool
    var discarded: Bool = false
    var symbol: String = "doc"
  }
  let tabs: [Tab]
  let selectedID: UUID
  let canGoBack: Bool
  let canGoForward: Bool
  let loading: Bool
  var canReopenClosedTab: Bool = false
  var home: Tab { tabs[0] }
}

/// One flat top bar: Home, file tabs as flat segments with zoom-scaled 1 pt dividers, '+', and a
/// trailing ⋯ menu. Visual only; every action is forwarded to the owner.
@MainActor
final class BrowserChromeView: UIView, UIDragInteractionDelegate, UIDropInteractionDelegate {
  static let height: CGFloat = 40

  var keepTabsLoaded = 0
  var interfaceZoom: InterfaceZoomState? {
    didSet {
      let scale = CGFloat(interfaceZoom?.scale ?? 1)
      homeWidth.constant = snapped(Self.homeRailWidth * scale)
      homeTab.interfaceScale = scale
      borderHeight.constant = snapped(scale)
      updateStackWidth()
      for view in tabViews.values { view.interfaceScale = scale }
      setNeedsLayout()
    }
  }
  var onInterfaceZoom: ((InterfaceZoomAction) -> Void)?
  var onKeepTabsLoaded: ((Int) -> Void)?
  var onToggleBottomToolbar: (() -> Void)?
  var showsBottomToolbar = true
  var onNewWindow: (() -> Void)?
  var onDragTab: ((UUID) -> TabTransfer?)?
  var onDropTab: ((TabTransfer, UUID?) -> Bool)?
  var onMoveToWindow: ((UUID) -> Void)?
  var onCreateDesign: (() -> Void)?
  var onCloseTab: ((UUID) -> Void)?
  var onSelect: ((UUID) -> Void)?
  var onClose: (() -> Void)?
  var onReopenClosedTab: (() -> Void)?
  var onOpenCurrentFile: (() -> Void)?
  var onDownloads: (() -> Void)?
  var onSettings: (() -> Void)?
  var onDeveloperTools: (() -> Void)?
  var onWelcomeTour: (() -> Void)?
  /// iPhone only: opens the tab list sheet.
  var onShowTabs: (() -> Void)?
  var onBack: (() -> Void)?
  var onForward: (() -> Void)?
  var onReload: (() -> Void)?
  var onPin: ((UUID) -> Void)?
  var onCopy: ((UUID) -> Void)?
  var onCloseOthers: ((UUID) -> Void)?
  #if DEBUG
    var onFixtureSetup: (() -> Void)?
  #endif

  private let homeTab = ChromeTabView(iconOnly: true)
  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private let create = ChromeTabView.segmentButton("plus", label: "New Design file")
  private let more = ChromeTabView.segmentButton("ellipsis", label: "More")
  /// Compact layout: Home, current tab with count, ⋯. The owner switches it live (iPhone Duo
  /// fold/unfold, narrow iPad windows).
  var compact = PhoneExperiencePolicy.isPhone {
    didSet {
      guard compact != oldValue else { return }
      menu?.dismiss()
      applyCompact()
      if let lastSession { render(lastSession) }
    }
  }
  private let tabsButton = PhoneTabsButton()
  private let hairline = UIView()
  private var stackWidth: NSLayoutConstraint!
  private var borderHeight: NSLayoutConstraint!
  private var tabWidths: [UUID: NSLayoutConstraint] = [:]
  private var homeWidth: NSLayoutConstraint!
  private var moreTrailing: NSLayoutConstraint!
  private var homeLeading: NSLayoutConstraint!
  /// Phones: where the page starts, in this view's coordinates (set by the owner), so Home lines
  /// up with the page exactly rather than with a safe-area guide.
  var pageLeading: CGFloat = 0 { didSet { if pageLeading != oldValue { setNeedsLayout() } } }
  /// iPhone Duo inner display, strip in the status row (maintainer, 2026-11-11): Home starts past
  /// Figma's 48 pt navigation rail, where the first file tab used to start, so the display's
  /// large corner above the rail stays empty.
  var clearsPageRail = false {
    didSet { if clearsPageRail != oldValue { setNeedsLayout() } }
  }
  private var cornerGuide: UILayoutGuide!
  /// Gap between iPad's window controls and Home (maintainer, 2026-11-11: it sat too close).
  private static let windowControlsGap: CGFloat = 6
  /// Space kept free at the trailing end for the system status items when the strip shares the
  /// iPhone Duo's status row (set by the owner; 0 elsewhere).
  var statusRowReserve: CGFloat = 0 {
    didSet {
      guard statusRowReserve != oldValue else { return }
      moreTrailing.constant = -4 - statusRowReserve
      setNeedsLayout()
    }
  }
  private var tabViews: [UUID: ChromeTabView] = [:]
  private var tabWidth: CGFloat = 220
  private var lastSelectedID: UUID?
  private var lastSession: B3BrowserChromeState?
  /// The tab being dragged inside this strip. It stays in the stack, invisible, as the gap that
  /// follows the finger, so the other tabs slide aside before the drop, like a collection-view reorder.
  private var liftedTab: ChromeTabView?
  /// Its index when lifted, restored when the drag leaves the strip.
  private var liftedOrigin: Int?
  private weak var menu: ChromeMenuPresenter?
  private static let tabSpacing: CGFloat = 0
  private static let minTabWidth: CGFloat = 132
  private static let maxTabWidth: CGFloat = 240
  private static let buttonWidth: CGFloat = 44
  // Home includes its trailing divider; do not add border width to the rail width.
  private static let homeRailWidth: CGFloat = 48

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = ChromePalette.bar
    let guide = layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))

    // Behind the tabs: unselected segments show it, the selected one covers it.
    hairline.translatesAutoresizingMaskIntoConstraints = false
    hairline.backgroundColor = ChromePalette.divider

    homeTab.translatesAutoresizingMaskIntoConstraints = false
    homeTab.configure(title: "Home", symbol: "house", pinned: false, loading: false)
    homeTab.accessibilityIdentifier = "tab-0"
    homeTab.addAction(
      UIAction { [weak self] _ in
        guard let self, let id = self.homeTab.tabID else { return }
        self.onSelect?(id)
      }, for: .touchUpInside)

    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    scroll.alwaysBounceVertical = false
    scroll.contentInsetAdjustmentBehavior = .never
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.distribution = .fill
    stack.spacing = Self.tabSpacing
    scroll.addSubview(stack)
    scroll.addInteraction(UIDropInteraction(delegate: self))

    create.accessibilityIdentifier = "browser-create-design"
    create.addAction(UIAction { [weak self] _ in self?.onCreateDesign?() }, for: .touchUpInside)
    more.accessibilityIdentifier = "browser-more"
    more.addAction(UIAction { [weak self] _ in self?.toggleMenu() }, for: .touchUpInside)

    for view in [hairline, homeTab, scroll, create, more] as [UIView] { addSubview(view) }
    do {
      // Compact: Home, current tab title with tab count, ⋯. Built on every device; the strip
      // and '+' stay laid out but hidden while compact, so the iPad constraint set is unchanged.
      tabsButton.translatesAutoresizingMaskIntoConstraints = false
      tabsButton.accessibilityIdentifier = "browser-tabs"
      tabsButton.addAction(UIAction { [weak self] _ in self?.onShowTabs?() }, for: .touchUpInside)
      addSubview(tabsButton)
      NSLayoutConstraint.activate([
        tabsButton.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -4),
        tabsButton.leadingAnchor.constraint(equalTo: homeTab.trailingAnchor, constant: 4),
        tabsButton.topAnchor.constraint(equalTo: topAnchor),
        tabsButton.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
      applyCompact()
    }

    stackWidth = stack.widthAnchor.constraint(equalToConstant: 0)
    homeWidth = homeTab.widthAnchor.constraint(equalToConstant: Self.homeRailWidth)
    borderHeight = hairline.heightAnchor.constraint(equalToConstant: 1)
    // Phones: Home starts at `pageLeading` (plus Figma's rail in the Duo's status row), set in
    // layout. iPad: past the window controls when they share the bar, with a gap set in layout.
    homeLeading = homeTab.leadingAnchor.constraint(
      equalTo: PhoneExperiencePolicy.isPhone ? leadingAnchor : guide.leadingAnchor)
    cornerGuide = guide
    moreTrailing = more.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -4)
    let fitTabs = scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
    fitTabs.priority = .defaultHigh
    NSLayoutConstraint.activate([
      homeLeading!,
      homeTab.topAnchor.constraint(equalTo: topAnchor),
      homeTab.bottomAnchor.constraint(equalTo: bottomAnchor),
      homeWidth!,

      scroll.leadingAnchor.constraint(equalTo: homeTab.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: topAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      fitTabs,
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
      stackWidth,

      create.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
      create.topAnchor.constraint(equalTo: topAnchor),
      create.bottomAnchor.constraint(equalTo: bottomAnchor),
      create.widthAnchor.constraint(equalToConstant: Self.buttonWidth),
      create.trailingAnchor.constraint(lessThanOrEqualTo: more.leadingAnchor, constant: -8),

      moreTrailing,
      more.topAnchor.constraint(equalTo: topAnchor),
      more.bottomAnchor.constraint(equalTo: bottomAnchor),
      more.widthAnchor.constraint(equalToConstant: Self.buttonWidth),

      hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
      hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
      borderHeight!,
    ])
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic tab strip") }

  private func applyCompact() {
    scroll.isHidden = compact
    create.isHidden = compact
    tabsButton.isHidden = !compact
    setNeedsLayout()
  }

  /// Called after each render, so other chrome (the iPhone Duo side rail) follows the same state.
  var onRendered: ((B3BrowserChromeState) -> Void)?

  func render(_ session: B3BrowserChromeState) {
    lastSession = session
    defer { onRendered?(session) }
    if compact {
      let selected = session.tabs.first { $0.id == session.selectedID } ?? session.home
      tabsButton.update(
        title: selected.home ? "Home" : selected.title ?? "Loading…",
        count: session.tabs.count - 1, loading: session.loading)
    }
    homeTab.tabID = session.home.id
    homeTab.isCurrent = session.selectedID == session.home.id

    let documents = session.tabs.enumerated().filter { !$0.element.home }
    let ids = Set(documents.map(\.element.id))
    for (id, view) in tabViews where !ids.contains(id) {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
      tabViews[id] = nil
      tabWidths[id] = nil
    }
    for (position, (index, tab)) in documents.enumerated() {
      let view = tabViews[tab.id] ?? makeTab(tab.id)
      view.configure(
        title: tab.title ?? "Loading…", symbol: tab.symbol, pinned: tab.pinned,
        loading: session.loading && tab.id == session.selectedID)
      view.alpha = view === liftedTab ? 0 : (tab.discarded ? 0.55 : 1)
      view.isCurrent = tab.id == session.selectedID
      view.accessibilityIdentifier = "tab-\(index)"
      // While a tab is lifted, the gap owns the order; the drop or cancel re-renders.
      if liftedTab == nil, stack.arrangedSubviews.firstIndex(of: view) != position {
        stack.insertArrangedSubview(view, at: position)
      }
    }
    updateStackWidth()

    if lastSelectedID != session.selectedID {
      lastSelectedID = session.selectedID
      if let selected = tabViews[session.selectedID] {
        layoutIfNeeded()
        scroll.scrollRectToVisible(selected.frame.insetBy(dx: -24, dy: 0), animated: true)
      }
    }
  }

  private func snapped(_ value: CGFloat) -> CGFloat {
    let pixels = max(1, traitCollection.displayScale)
    return (value * pixels).rounded() / pixels
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: 0, dy: -max(0, (44 - bounds.height) / 2)).contains(point)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled,
      self.point(inside: point, with: event)
    else { return nil }
    // Invisible extensions preserve 44 pt targets without adding visible bar height.
    for button in compact ? [more, tabsButton] : [more, create] {
      let local = convert(point, to: button)
      if button.point(inside: local, with: event) { return button }
    }
    let homePoint = convert(point, to: homeTab)
    if homeTab.point(inside: homePoint, with: event) { return homeTab }
    if point.x >= scroll.frame.minX, point.x < scroll.frame.maxX {
      for tab in stack.arrangedSubviews {
        if let hit = tab.hitTest(convert(point, to: tab), with: event) { return hit }
      }
    }
    return super.hitTest(point, with: event)
  }

  override func layoutSubviews() {
    let leading: CGFloat
    if PhoneExperiencePolicy.isPhone {
      let zoom = CGFloat(interfaceZoom?.scale ?? 1)
      leading = pageLeading + (clearsPageRail ? snapped(Self.homeRailWidth * zoom) : 0)
    } else {
      // The corner-adapted guide is indented only where the window controls sit in the bar.
      let controls = cornerGuide.layoutFrame.minX > safeAreaInsets.left + 1
      leading = controls ? Self.windowControlsGap : 0
    }
    if homeLeading.constant != leading { homeLeading.constant = leading }
    super.layoutSubviews()
    let scale = CGFloat(interfaceZoom?.scale ?? 1)
    homeWidth.constant = snapped(Self.homeRailWidth * scale)
    borderHeight.constant = snapped(scale)
    updateStackWidth()
    // Keep the first separator over the sidebar; remaining tabs fit or scroll.
    let count = CGFloat(tabViews.values.filter { !$0.isPinned }.count)
    guard count > 0 else { return }
    let pinnedWidth =
      CGFloat(tabViews.values.filter(\.isPinned).count)
      * snapped(Self.homeRailWidth * scale)
    let available = more.frame.minX - 8 - Self.buttonWidth - scroll.frame.minX - pinnedWidth
    let firstWidth = snapped(250 * CGFloat(interfaceZoom?.scale ?? 1))
    let fitted = snapped((available - firstWidth) / max(1, count - 1))
    let width = min(Self.maxTabWidth, max(Self.minTabWidth, fitted))
    if abs(width - tabWidth) > 0.5 {
      tabWidth = width
      updateStackWidth()
      super.layoutSubviews()
    }
  }

  private func updateStackWidth() {
    let scale = CGFloat(interfaceZoom?.scale ?? 1)
    var total: CGFloat = 0
    var firstDocument = true
    for view in stack.arrangedSubviews {
      guard let tab = view as? ChromeTabView, let id = tab.tabID else { continue }
      // Keep the first file segment at its existing zoom-scaled width.
      let width =
        tab.isPinned
        ? snapped(Self.homeRailWidth * scale)
        : firstDocument ? snapped(250 * scale) : tabWidth
      if !tab.isPinned { firstDocument = false }
      tabWidths[id]?.constant = width
      total += width
    }
    stackWidth.constant = total
  }

  private func toggleMenu() { toggleMenu(from: more, beside: false) }

  /// Closes the ⋯ menu if open (layout switches).
  func menuDismiss() { menu?.dismiss() }

  /// The ⋯ menu opened from another control, such as the iPhone Duo side rail's ⋯ (beside it).
  func toggleMenu(from source: UIView, beside: Bool) {
    if let menu {
      menu.dismiss()
      return
    }
    guard let window = source.window else { return }
    menu = ChromeMenuPresenter.present(
      in: window, below: source.convert(source.bounds, to: window), compact: compact,
      beside: beside
    ) { [weak self] in self?.menuItems() ?? [] }
  }

  private func makeTab(_ id: UUID) -> ChromeTabView {
    let view = ChromeTabView(iconOnly: false)
    view.interfaceScale = CGFloat(interfaceZoom?.scale ?? 1)
    view.tabID = id
    let drag = UIDragInteraction(delegate: self)
    drag.isEnabled = true
    view.addInteraction(drag)
    view.addAction(UIAction { [weak self] _ in self?.onSelect?(id) }, for: .touchUpInside)
    view.onClose = { [weak self] in self?.onCloseTab?(id) }
    view.menuProvider = { [weak self, weak view] in
      guard let self else { return nil }
      let pinned = view?.isPinned ?? false
      let move: [UIMenuElement] =
        PhoneExperiencePolicy.supportsMultipleWindows(on: self.window?.windowScene?.screen)
        ? [
          UIAction(
            title: "Move to New Window", image: UIImage(systemName: "rectangle.on.rectangle")
          ) { [weak self] _ in self?.onMoveToWindow?(id) }
        ] : []
      return UIMenu(
        children: move + [
          UIAction(
            title: pinned ? "Unpin Tab" : "Pin Tab",
            image: UIImage(systemName: pinned ? "pin.slash" : "pin")
          ) { [weak self] _ in self?.onPin?(id) },
          UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { [weak self] _ in
            self?.onCopy?(id)
          },
          UIMenu(
            options: .displayInline,
            children: [
              UIAction(
                title: "Close Tab", image: UIImage(systemName: "xmark"),
                attributes: pinned ? .disabled : []
              ) { [weak self] _ in
                self?.onCloseTab?(id)
              },
              UIAction(title: "Close Other Tabs", attributes: .destructive) { [weak self] _ in
                self?.onCloseOthers?(id)
              },
            ]),
        ])
    }
    let width = view.widthAnchor.constraint(equalToConstant: tabWidth)
    width.isActive = true
    tabWidths[id] = width
    tabViews[id] = view
    return view
  }

  func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession)
    -> [UIDragItem]
  {
    guard let view = interaction.view as? ChromeTabView, let id = view.tabID,
      let transfer = onDragTab?(id)
    else { return [] }
    let provider = NSItemProvider()
    provider.registerObject(transfer.activity, visibility: .all)
    let item = UIDragItem(itemProvider: provider)
    item.localObject = transfer
    return [item]
  }

  func dragInteraction(
    _ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession
  ) -> UITargetedDragPreview? {
    guard let view = interaction.view else { return nil }
    let parameters = UIDragPreviewParameters()
    parameters.backgroundColor = ChromePalette.selectedTab
    parameters.visiblePath = UIBezierPath(rect: view.bounds)
    return UITargetedDragPreview(view: view, parameters: parameters)
  }

  func dragInteraction(
    _ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession
  ) -> Bool { true }

  func dragInteraction(
    _ interaction: UIDragInteraction, willAnimateLiftWith animator: any UIDragAnimating,
    session: UIDragSession
  ) {
    guard let view = interaction.view as? ChromeTabView else { return }
    animator.addCompletion { [weak self, weak view] position in
      guard position == .end, let self, let view else { return }
      self.liftedTab = view
      self.liftedOrigin = self.stack.arrangedSubviews.firstIndex(of: view)
      view.alpha = 0
    }
  }

  func dragInteraction(
    _ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation
  ) {
    endLift()
    // System scene connection can follow drag completion. Keep its capability briefly;
    // expiration/cancellation only retires the token, never closes a tab.
    let tokens = session.items.compactMap { ($0.localObject as? TabTransfer)?.token }
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
      for token in tokens { FolioWindows.transfers.removeValue(forKey: token) }
    }
  }

  func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
    session.items.count == 1 && session.items.first?.localObject is TabTransfer
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession)
    -> UIDropProposal
  {
    if let lifted = liftedTab,
      (session.items.first?.localObject as? TabTransfer)?.tabID == lifted.tabID
    {
      moveGap(lifted, to: session.location(in: stack).x)
    }
    return UIDropProposal(operation: .move)
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
    guard let lifted = liftedTab, let origin = liftedOrigin else { return }
    animateStack { self.stack.insertArrangedSubview(lifted, at: origin) }
  }

  /// Lands the drop preview in the gap rather than under the finger.
  func dropInteraction(
    _ interaction: UIDropInteraction, previewForDropping item: UIDragItem,
    withDefault defaultPreview: UITargetedDragPreview
  ) -> UITargetedDragPreview? {
    guard let lifted = liftedTab, (item.localObject as? TabTransfer)?.tabID == lifted.tabID
    else { return defaultPreview }
    return defaultPreview.retargetedPreview(
      with: UIDragPreviewTarget(container: stack, center: lifted.center))
  }

  /// Moves the invisible lifted tab to the slot under `x`, within its pinned or unpinned group,
  /// so the neighbours slide aside to show where it will land.
  private func moveGap(_ lifted: ChromeTabView, to x: CGFloat) {
    let tabs = stack.arrangedSubviews.compactMap { $0 as? ChromeTabView }
    guard let current = tabs.firstIndex(of: lifted) else { return }
    let others = tabs.filter { $0 !== lifted }
    let pinned = others.filter(\.isPinned).count
    let slot = others.firstIndex { x < $0.frame.midX } ?? others.count
    let target = lifted.isPinned ? min(slot, pinned) : max(slot, pinned)
    guard target != current else { return }
    animateStack { self.stack.insertArrangedSubview(lifted, at: target) }
  }

  private func animateStack(_ change: @escaping () -> Void) {
    UIView.animate(
      withDuration: 0.2, delay: 0,
      options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
    ) {
      change()
      self.stack.layoutIfNeeded()
    }
  }

  /// Ends a local drag: the lifted tab reappears and the strip re-renders the session order
  /// (the new order after a drop, the old one after a cancel).
  private func endLift() {
    guard liftedTab != nil else { return }
    liftedTab = nil
    liftedOrigin = nil
    guard let session = lastSession else { return }
    animateStack { self.render(session) }
  }

  func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
    guard let transfer = session.items.first?.localObject as? TabTransfer else { return }
    let tabs = stack.arrangedSubviews.compactMap { $0 as? ChromeTabView }
    let before: UUID?
    if let lifted = liftedTab, lifted.tabID == transfer.tabID,
      let index = tabs.firstIndex(of: lifted)
    {
      // The gap already shows the landing slot; drop before its right-hand neighbour.
      before = index + 1 < tabs.count ? tabs[index + 1].tabID : nil
    } else {
      let x = session.location(in: stack).x
      before = tabs.first { x < $0.frame.midX }?.tabID
    }
    _ = onDropTab?(transfer, before)
  }

  /// The ⋯ menu as data, rebuilt each time it opens or refreshes. Add features here.
  private func menuItems() -> [ChromeMenuItem] {
    guard let session = lastSession else { return [] }
    let onHome = session.selectedID == session.home.id
    var items: [ChromeMenuItem] =
      PhoneExperiencePolicy.supportsMultipleWindows(on: self.window?.windowScene?.screen)
      ? [
        ChromeMenuItem(title: "New window", hint: "⌃⌘N") { [weak self] in self?.onNewWindow?() },
        .separator,
      ] : []
    items += [
      ChromeMenuItem(title: "Back", enabled: session.canGoBack) { [weak self] in self?.onBack?() },
      ChromeMenuItem(title: "Forward", enabled: session.canGoForward) { [weak self] in
        self?.onForward?()
      },
      ChromeMenuItem(title: "Reload") { [weak self] in self?.onReload?() },
      .separator,
      ChromeMenuItem(title: "Open in new tab", enabled: !onHome) { [weak self] in
        self?.onOpenCurrentFile?()
      },
      ChromeMenuItem(title: "Downloads", hint: "⌃⌘J") { [weak self] in self?.onDownloads?() },
      .separator,
    ]
    if let zoom = interfaceZoom {
      items.append(
        ChromeMenuItem(title: "Interface zoom", hint: zoom.percent, children: zoomItems(zoom)))
    }
    // Touch mode exists only where Apple Pencil does: iPad and the iPhone Duo.
    let input = InputStrategies()
    if PhoneExperiencePolicy.supportsPencil() {
      items.append(
        ChromeMenuItem(
          title: "Touch mode", hint: input.touchMode.title,
          children: TouchMode.allCases.map { mode in
            ChromeMenuItem(title: mode.title, checked: input.touchMode == mode) {
              input.touchMode = mode
            }
          }))
    }
    items += [
      ChromeMenuItem(
        title: "Keep tabs loaded", hint: keepTabsLoaded == 0 ? "Automatic" : String(keepTabsLoaded),
        children: PhoneExperiencePolicy.tabLimitChoices.map { count in
          ChromeMenuItem(
            title: count == 0 ? "Automatic" : "\(count) tabs", checked: count == keepTabsLoaded
          ) {
            [weak self] in self?.onKeepTabsLoaded?(count)
          }
        })
    ]
    // Compact layouts always show the bottom toolbar.
    if !compact {
      items.append(
        ChromeMenuItem(
          title: showsBottomToolbar ? "Hide bottom toolbar" : "Show bottom toolbar", hint: "⌃⇧⌘B"
        ) { [weak self] in self?.onToggleBottomToolbar?() })
    }
    items += [
      .separator,
      ChromeMenuItem(title: "Close tab", hint: "⌃⌘W", enabled: !onHome) { [weak self] in
        self?.onClose?()
      },
      ChromeMenuItem(
        title: "Reopen closed tab", hint: "⌃⇧⌘T", enabled: session.canReopenClosedTab
      ) { [weak self] in self?.onReopenClosedTab?() },
      .separator,
      ChromeMenuItem(title: "Welcome tour") { [weak self] in self?.onWelcomeTour?() },
      ChromeMenuItem(title: "Settings…", hint: "⌘,") { [weak self] in self?.onSettings?() },
      ChromeMenuItem(title: "Developer Tools", hint: "⌥⌘I") { [weak self] in
        self?.onDeveloperTools?()
      },
    ]
    #if DEBUG
      if onFixtureSetup != nil {
        items += [
          .separator,
          ChromeMenuItem(title: "New tab (fixture)") { [weak self] in self?.onFixtureSetup?() },
        ]
      }
    #endif
    return items
  }

  private func zoomItems(_ zoom: InterfaceZoomState) -> [ChromeMenuItem] {
    var items = [
      ChromeMenuItem(title: "Zoom in", hint: "⌥⌘=", enabled: zoom.canIncrease, keepsOpen: true) {
        [weak self] in self?.onInterfaceZoom?(.increase)
      },
      ChromeMenuItem(title: "Zoom out", hint: "⌥⌘-", enabled: zoom.canDecrease, keepsOpen: true) {
        [weak self] in self?.onInterfaceZoom?(.decrease)
      },
      .separator,
    ]
    items += InterfaceZoomPreset.available.reversed().map { preset in
      ChromeMenuItem(title: preset.title, checked: preset.rawValue == zoom.scale) { [weak self] in
        self?.onInterfaceZoom?(.preset(preset))
      }
    }
    items += [
      .separator,
      ChromeMenuItem(title: "Reset to 100%", hint: "⌥⌘0", enabled: zoom.scale != 1) {
        [weak self] in self?.onInterfaceZoom?(.reset)
      },
    ]
    return items
  }
}

/// iPhone tab switcher button: the selected tab's title and a tab-count badge.
@MainActor
final class PhoneTabsButton: UIControl {
  private let title = UILabel()
  private let badge = UILabel()
  private let chevron = UIImageView(
    image: UIImage(
      systemName: "chevron.down",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)))
  private let spinner = UIActivityIndicatorView(style: .medium)

  override init(frame: CGRect) {
    super.init(frame: frame)
    title.font = .systemFont(ofSize: 13, weight: .medium)
    title.textColor = ChromePalette.primaryText
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    badge.textColor = ChromePalette.primaryText
    badge.textAlignment = .center
    badge.layer.borderColor = ChromePalette.icon.cgColor
    badge.layer.borderWidth = 1.5
    badge.layer.cornerRadius = 5
    badge.layer.cornerCurve = .continuous
    chevron.tintColor = ChromePalette.icon
    spinner.hidesWhenStopped = true
    spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
    let row = UIStackView(arrangedSubviews: [spinner, title, chevron, UIView(), badge])
    row.spacing = 6
    row.alignment = .center
    row.isUserInteractionEnabled = false
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
      badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
      badge.heightAnchor.constraint(equalToConstant: 22),
    ])
    accessibilityTraits = .button
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
      self.badge.layer.borderColor =
        ChromePalette.icon.resolvedColor(with: self.traitCollection)
        .cgColor
    }
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic tabs button") }

  func update(title text: String, count: Int, loading: Bool) {
    title.text = text
    badge.text = String(count)
    badge.layer.borderColor = ChromePalette.icon.resolvedColor(with: traitCollection).cgColor
    if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    accessibilityLabel = "\(text), \(count) open \(count == 1 ? "file" : "files")"
    accessibilityHint = "Shows open tabs"
  }

  override var isHighlighted: Bool {
    didSet { backgroundColor = isHighlighted ? ChromePalette.hover : .clear }
  }
}
