import UIKit
import WebKit
import os

@MainActor
final class BrowserWindowController: UIViewController {
  private static let windows = NSHashTable<BrowserWindowController>.weakObjects()
  private static var lastPressureEviction = Date.distantPast
  private static let retentionKey = "folio.keepTabsLoaded"
  // Zero means Automatic. Migrate once so a new explicit choice of 3 remains a hard cap.
  private var keepTabsLoaded: Int {
    let defaults = UserDefaults.standard
    if !defaults.bool(forKey: "folio.tabRetention.automaticMigrated") {
      let old = defaults.integer(forKey: Self.retentionKey)
      defaults.set(old == 3 ? 0 : old == 2 ? 3 : old, forKey: Self.retentionKey)
      defaults.set(true, forKey: "folio.tabRetention.automaticMigrated")
    }
    let value = defaults.integer(forKey: Self.retentionKey)
    return PhoneExperiencePolicy.tabLimitChoices.contains(value) ? value : 0
  }
  // This is the host allowance, not WebContent usage. Use a conservative floor.
  private static let memoryFloor: UInt64 = 128 * 1024 * 1024
  let session: WindowSession
  var onInterfaceZoom: ((InterfaceZoomAction) -> Void)?
  var onAdoptMainWebView: ((WKWebView) -> Void)?
  /// The scene switched between the compact (phone-size or narrow iPad window) and the regular
  /// layout.
  var onCompactLayout: ((Bool) -> Void)?
  private let websiteDataStore: WKWebsiteDataStore
  private let memory: MemoryLabStore
  private let makeWebView: (WKWebViewConfiguration) -> WKWebView
  private let memoryOwnership = MemoryLabOwnership()
  private var controllers: [UUID: FigmaWebViewController] = [:]
  private var active: FigmaWebViewController?
  private var windowRouteEvidence: [String] = []
  private let strip = BrowserChromeView()
  private let content = UIView()
  private var bottomBar = BottomToolbarView()
  /// Compact layout: iPhone phone-size scenes and narrow iPad windows
  /// (`PhoneExperiencePolicy.usesCompactLayout`). False on regular iPad windows and unfolded Duo.
  private(set) var compactLayout = PhoneExperiencePolicy.isPhone
  /// iPhone phone-size layout in compact height: one-row bar and side panels.
  private(set) var phoneLandscape = false
  /// iPhone sidebar sheet: grab bar and its offset above the browser bottom.
  private let sheetHandle = PhoneSheetHandle()
  private var displayedSheetFraction = 0.5
  private var sheetDragInFlight = false
  private var pendingSheetDrags: [(Double, PhoneSheetHandle.DragPhase)] = []
  private var phonePanelRequest = UUID()
  private var sheetHandleBottom: NSLayoutConstraint?
  /// iPhone: floating tool pill above the bottom bar, and the tab its tool state belongs to.
  private let toolPill = PhoneToolPill()
  private var toolPillTab: ObjectIdentifier?
  /// The pill rests 8 pt above the bar, or above the grab bar while a sheet is open, so it
  /// follows sheet drags and a keyboard-raised sheet. Hidden when no room is left above.
  private var toolPillBottom: NSLayoutConstraint?
  private var toolPillAboveSheet: NSLayoutConstraint?
  private var toolPillWanted = false
  /// Centred over the canvas: in landscape between the open side panels, never over one.
  private var toolPillCenter: NSLayoutConstraint?
  private var toolPillWidth: NSLayoutConstraint?
  /// On-screen width (CSS px) of the open landscape side panels, from the page.
  private var pillPanels: (left: Double, right: Double) = (0, 0)
  /// Last reported Figma popover state; sheet replies carry none and keep it.
  private var phoneOverlay = false
  /// iPhone: key row on the keyboard for numeric sheet fields. While a sheet is open the web
  /// view keeps its full height under the keyboard, so Figma never re-lays out for it; the
  /// sheet's bottom rides on the keyboard (`keyboardOverlap`, points) and its top rises to at
  /// least `raisedSheet`, all in one jump when the keyboard starts to move (phone-layout.ts).
  private let keyRow = PhoneKeyRow()
  /// iPhone Duo inner display in landscape (maintainer, 2026-11-11): a 1 pt line down the page's
  /// right edge, so Figma's section dividers in the properties panel end on a border, as they do
  /// on the other three sides, instead of running out into the system column.
  private let pageTrailingBorder = UIView()
  private var raisedSheet = 0.0
  private var keyboardOverlap: CGFloat = 0
  private var keyboardBound: NSLayoutConstraint?
  private var keyboardObserver: NSObjectProtocol?
  private var fieldNumeric = false
  private var interfaceScale: CGFloat = 1
  private var shortcutObservers: [NSObjectProtocol] = []
  private var shownContentBottom: NSLayoutConstraint?
  private var hiddenContentBottom: NSLayoutConstraint?
  private var stripHeight: NSLayoutConstraint?
  /// Strip top below the safe area (normal) or inside the status row (iPhone Duo inner display).
  private var stripSafeTop: NSLayoutConstraint?
  private var stripStatusTop: NSLayoutConstraint?
  /// iPhone Duo side column (`SideRailView`): an overlay over the whole window, hidden elsewhere.
  private let rail = SideRailView()
  /// iPhone Duo top bar for compact column layouts (`DuoTitleBar`).
  private let titleBar = DuoTitleBar()
  /// The column's side while it shows, and whether the window is compact (Duo top bar).
  private var duoColumn: (side: SideRailView.Side, compact: Bool)?
  private var duoColumnReport = ""
  /// Hidden strip under the Duo top bar: its bottom sets the page's top (72 pt).
  private var stripColumnTop: NSLayoutConstraint?
  private var stripColumnHeight: NSLayoutConstraint?
  private var stripCollapsed: NSLayoutConstraint?
  /// Content edges: inside the horizontal safe area, or out to the window edge (the Duo's
  /// compact column, where the canvas runs behind the glass).
  private var contentLeadingSafe: NSLayoutConstraint?
  private var contentLeadingEdge: NSLayoutConstraint?
  private var contentTrailingSafe: NSLayoutConstraint?
  private var contentTrailingEdge: NSLayoutConstraint?
  /// Docked keyboard's top in this view, or nil when down.
  private var keyboardTop: CGFloat?
  /// Room the tool pill leaves for the Duo column (points, from the column's side).
  private var pillColumnInset: CGFloat = 0
  private var pillColumnRight = true
  private var duoChromeObserver: NSObjectProtocol?
  private let fixture: Bool
  private let fixtureDefaultsName: String?
  private var fixtureNumbers: [UUID: Int] = [:]
  private var timer: Timer?
  private var warningObserver: NSObjectProtocol?

  init(
    session: WindowSession? = nil, websiteDataStore: WKWebsiteDataStore = .default(),
    memory: MemoryLabStore = MemoryLabStore(), useFixture: Bool = false,
    defaults: UserDefaults = .standard,
    makeWebView: @escaping (WKWebViewConfiguration) -> WKWebView = {
      WKWebView(frame: .zero, configuration: $0)
    }
  ) {
    #if DEBUG
      fixture = useFixture || ProcessInfo.processInfo.arguments.contains("--tabs-lab")
    #else
      fixture = false
    #endif
    let fixtureName =
      (fixture || DebugLabConfiguration.offline) && session == nil ? "folio.fixture.\(UUID())" : nil
    fixtureDefaultsName = fixtureName
    let sessionDefaults = fixtureName.flatMap(UserDefaults.init(suiteName:)) ?? defaults
    self.session =
      session
      ?? WindowSession(
        defaults: sessionDefaults, migrateLegacy: !fixture && !DebugLabConfiguration.offline)
    self.websiteDataStore = websiteDataStore
    self.memory = memory
    self.makeWebView = makeWebView
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("Use injected window session") }

  isolated deinit {
    timer?.invalidate()
    for observer in shortcutObservers { NotificationCenter.default.removeObserver(observer) }
    if let fixtureDefaultsName {
      UserDefaults(suiteName: fixtureDefaultsName)?.removePersistentDomain(
        forName: fixtureDefaultsName)
    }
    if let warningObserver { NotificationCenter.default.removeObserver(warningObserver) }
    if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    Self.windows.add(self)
    view.backgroundColor = ChromePalette.bar
    strip.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(strip)
    view.insertSubview(content, belowSubview: strip)
    view.addSubview(bottomBar)
    rail.translatesAutoresizingMaskIntoConstraints = false
    rail.isHidden = true
    titleBar.translatesAutoresizingMaskIntoConstraints = false
    titleBar.isHidden = true
    view.addSubview(titleBar)
    view.addSubview(rail)
    // Compact chrome is built on every device and stays hidden until the scene is compact, so a
    // narrow iPad window can switch to it and back without relaunch.
    do {
      sheetHandle.isHidden = true
      view.insertSubview(sheetHandle, aboveSubview: content)
      sheetHandleBottom = sheetHandle.bottomAnchor.constraint(equalTo: content.bottomAnchor)
      NSLayoutConstraint.activate([
        sheetHandle.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        sheetHandle.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        sheetHandle.heightAnchor.constraint(equalToConstant: PhoneSheetHandle.height),
        sheetHandleBottom!,
      ])
      // Floats over the canvas, above the bar (and the keyboard), like the editor's own tool bar.
      toolPill.setShown(false, animated: false)
      // Rests on the keyboard and moves with it, above the sheet.
      view.insertSubview(keyRow, aboveSubview: content)
      attachFloatingPill()
      NSLayoutConstraint.activate([
        keyRow.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        keyRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
        keyRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
      ])
      keyRow.onKey = { [weak self] key in self?.active?.phoneFieldKey(key) }
      toolPill.onKey = { [weak self] key in
        self?.bottomBar.noteKeyUse()
        self?.active?.touchShortcutKey(key)
      }
      sheetHandle.onFraction = { [weak self] fraction, phase in
        guard let self else { return }
        // Keep boundaries, but replace unsent moves with the newest sample.
        if self.pendingSheetDrags.last?.1 == .move { self.pendingSheetDrags.removeLast() }
        self.pendingSheetDrags.append((fraction, phase))
        self.sendSheetDrag()
      }
      keyboardObserver = NotificationCenter.default.addObserver(
        forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
      ) { [weak self] note in
        let info = note.userInfo
        let end = (info?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        MainActor.assumeIsolated { self?.keyboardWillMove(to: end) }
      }
    }
    // The bar resizes the web view rather than covering it; its background runs under the
    // home indicator. Docked keyboards cover the bar and bound the browser viewport.
    shownContentBottom = content.bottomAnchor.constraint(equalTo: bottomBar.topAnchor)
    hiddenContentBottom = content.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    // Keep the unoccluded attachment until the docked keyboard guide is higher.
    // Floating/undocked keyboards stay WebKit's responsibility, without a full-width inset.
    view.keyboardLayoutGuide.followsUndockedKeyboard = false
    view.keyboardLayoutGuide.usesBottomSafeArea = false
    shownContentBottom?.priority = .defaultHigh
    hiddenContentBottom?.priority = .defaultHigh
    keyboardBound = content.bottomAnchor.constraint(
      lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor)
    keyboardBound?.isActive = true
    hiddenContentBottom?.isActive = true
    bottomBar.isHidden = true
    content.topAnchor.constraint(equalTo: strip.bottomAnchor).isActive = true
    // Corner-adapted top: in windowed mode the bar sits beside the system window
    // controls; the strip insets its own content past them.
    stripHeight = strip.heightAnchor.constraint(equalToConstant: BrowserChromeView.height)
    let barGuide = view.layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
    stripSafeTop = strip.topAnchor.constraint(equalTo: barGuide.topAnchor)
    stripStatusTop = strip.topAnchor.constraint(equalTo: view.topAnchor)
    stripCollapsed = strip.heightAnchor.constraint(equalToConstant: 0)
    stripColumnTop = strip.topAnchor.constraint(
      equalTo: view.topAnchor, constant: Self.columnTitleBarTop)
    stripColumnHeight = strip.heightAnchor.constraint(
      equalToConstant: Self.columnTitleBarHeight)
    let phone = PhoneExperiencePolicy.isPhone
    contentLeadingSafe = content.leadingAnchor.constraint(
      equalTo: phone ? view.safeAreaLayoutGuide.leadingAnchor : view.leadingAnchor)
    contentLeadingEdge = content.leadingAnchor.constraint(equalTo: view.leadingAnchor)
    contentTrailingSafe = content.trailingAnchor.constraint(
      equalTo: phone ? view.safeAreaLayoutGuide.trailingAnchor : view.trailingAnchor)
    contentTrailingEdge = content.trailingAnchor.constraint(equalTo: view.trailingAnchor)
    NSLayoutConstraint.activate([
      rail.topAnchor.constraint(equalTo: view.topAnchor),
      rail.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      rail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      rail.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      titleBar.topAnchor.constraint(equalTo: view.topAnchor),
      titleBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      titleBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      titleBar.heightAnchor.constraint(equalToConstant: DuoTitleBar.height),
      contentLeadingSafe!,
      contentTrailingSafe!,
      stripSafeTop!,
      strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stripHeight!,
      bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    strip.onKeepTabsLoaded = { [weak self] count in
      UserDefaults.standard.set(count, forKey: Self.retentionKey)
      self?.enforceTabRetention()
    }
    wire(bottomBar)
    wireRail()
    // iPhone switches on size classes; iPad on window width, checked in viewDidLayoutSubviews.
    // Vertical size class also drives the compact landscape variant.
    registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) {
      (self: Self, _) in self.updateCompactLayout()
    }
    strip.onToggleBottomToolbar = { [weak self] in self?.toggleBottomToolbar() }
    for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
      shortcutObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated { self?.releaseShortcuts() }
        })
    }
    strip.onInterfaceZoom = { [weak self] action in self?.onInterfaceZoom?(action) }
    strip.onNewWindow = { [weak self] in
      FolioWindows.newWindow(from: self?.view.window?.windowScene)
    }
    strip.onMoveToWindow = { [weak self] id in
      guard let self, let transfer = FolioWindows.begin(id, source: self) else { return }
      FolioWindows.newWindow(from: self.view.window?.windowScene, transfer: transfer)
    }
    strip.onDragTab = { [weak self] id in
      guard let self else { return nil }
      return FolioWindows.begin(id, source: self)
    }
    strip.onDropTab = { [weak self] transfer, before in
      guard let self else { return false }
      return FolioWindows.accept(transfer, into: self, before: before)
    }
    strip.onSelect = { [weak self] id in
      self?.session.select(id)
      self?.showSelectedTab(ownerSelection: true)
    }
    strip.onCreateDesign = { [weak self] in
      self?.addTab(url: TabNavigationRouter.newDesignURL)
    }
    strip.onCloseTab = { [weak self] id in self?.closeTab(id) }
    strip.onReopenClosedTab = { [weak self] in self?.reopenClosedTab() }
    strip.onClose = { [weak self] in self?.closeSelectedTab() }
    strip.onOpenCurrentFile = { [weak self] in self?.active?.openCurrentFileInNewTab() }
    strip.onBack = { [weak self] in self?.active?.webView.goBack() }
    strip.onForward = { [weak self] in self?.active?.webView.goForward() }
    strip.onReload = { [weak self] in self?.confirmReload() }
    strip.onPin = { [weak self] id in
      self?.session.togglePin(id)
      if let self { self.strip.render(self.chromeState) }
    }
    strip.onCopy = { [weak self] id in
      guard let tab = self?.session.tabs.first(where: { $0.id == id }),
        let url = Privacy.recoveryURL(tab.routingURL ?? tab.recoveryURL)
      else { return }
      UIPasteboard.general.url = url
    }
    strip.onCloseOthers = { [weak self] id in self?.confirmCloseOthers(id) }
    strip.onDownloads = { [weak self] in self?.active?.downloads.showDownloadCenter() }
    strip.onSettings = { [weak self] in self?.showSettings() }
    strip.onDeveloperTools = { [weak self] in self?.showDeveloperTools() }
    strip.onWelcomeTour = { [weak self] in
      guard let self else { return }
      OnboardingController.present(from: self)
    }
    strip.onShowTabs = { [weak self] in self?.showPhoneTabs() }
    #if DEBUG
      if fixture && ProcessInfo.processInfo.arguments.contains("--tabs-url-alert") {
        strip.onFixtureSetup = { [weak self] in self?.promptForTab() }
      }
    #endif
    do {
      try memory.interrupt(status: "app-restarted", availableBytes: currentAvailableMemory)
    } catch { sampleMemory("Memory restart persistence failed") }
    sampleMemory("App started")
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.sampleMemory("Native memory sample")
        #if targetEnvironment(simulator)
          // Simulator processes have no iOS dirty-memory limit. The API returns
          // zero there; it is not evidence of exhausted host allowance.
          let reading = self?.currentAvailableMemory
          self?.enforceTabRetention(
            lowMemory: Self.hostAllowanceRequiresEviction(reading == 0 ? nil : reading))
        #else
          self?.enforceTabRetention(
            lowMemory: (self?.currentAvailableMemory ?? UInt64.max) < Self.memoryFloor)
        #endif
      }
    }
    warningObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.sampleMemory("UIApplication memory warning")
        self?.enforceTabRetention(memoryWarning: true)
      }
    }
    showSelectedTab()
    #if DEBUG
      if fixture && ProcessInfo.processInfo.arguments.contains("--browser-chrome-visibility") {
        installChromeVisibilityRegressionControls()
      }
    #endif
    #if DEBUG
      // iPhone layout check on the editor-shaped fixture: optional landscape, then Layers,
      // Properties, Layers, Properties toggled 4 s apart from 8 s.
      if fixture && ProcessInfo.processInfo.arguments.contains("--phone-layout-check") {
        let tab = addTab(url: URL(string: "https://www.figma.com/design/fixture1")!)
        session.select(tab.id)
        showSelectedTab()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
          guard ProcessInfo.processInfo.arguments.contains("--phone-landscape") else { return }
          self?.view.window?.windowScene?.requestGeometryUpdate(
            .iOS(interfaceOrientations: .landscapeRight))
        }
        for (index, side) in ["left", "right", "left", "right"].enumerated() {
          DispatchQueue.main.asyncAfter(deadline: .now() + 8 + Double(index) * 4) { [weak self] in
            self?.togglePhonePanel(side)
          }
        }
      }
    #endif
  }

  private func wire(_ bar: BottomToolbarView) {
    bar.onModifiers = { [weak self] mask in self?.active?.setTouchShortcutModifiers(mask) }
    bar.onKey = { [weak self] key, down in self?.active?.touchShortcutKey(key, down: down) }
    bar.onEdit = { [weak self] action, sender in
      self?.active?.touchShortcutEdit(action, sender: sender)
    }
    bar.onPanel = { [weak self] side in self?.togglePhonePanel(side) }
  }

  /// The pill floats over the canvas, 8 pt above the bar (or the grab bar), in portrait and in
  /// landscape. The content view stays inside the horizontal safe area and above the home
  /// indicator, so the pill does too.
  private func attachFloatingPill() {
    view.insertSubview(toolPill, belowSubview: keyRow)
    let bottom = toolPill.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
    let aboveSheet = toolPill.bottomAnchor.constraint(
      equalTo: sheetHandle.topAnchor, constant: -8)
    let center = toolPill.centerXAnchor.constraint(equalTo: content.centerXAnchor)
    let width = toolPill.widthAnchor.constraint(
      lessThanOrEqualTo: content.widthAnchor, constant: -16)
    toolPillBottom = bottom
    toolPillAboveSheet = aboveSheet
    toolPillCenter = center
    toolPillWidth = width
    NSLayoutConstraint.activate([bottom, center, width])
  }

  /// Centre and width cap of the canvas between the open side panels (points).
  static func pillSpan(
    contentWidth: CGFloat, left: CGFloat, right: CGFloat
  ) -> (offset: CGFloat, inset: CGFloat) {
    let left = max(0, min(left, contentWidth))
    let right = max(0, min(right, contentWidth - left))
    return ((left - right) / 2, left + right + 16)
  }

  /// Re-centres the pill between the open side panels, with the panel transition's timing.
  private func placeToolPill(animated: Bool) {
    let scale = max(interfaceScale, 0.1)
    let span = Self.pillSpan(
      contentWidth: content.bounds.width,
      left: CGFloat(pillPanels.left) * scale + (pillColumnRight ? 0 : pillColumnInset),
      right: CGFloat(pillPanels.right) * scale + (pillColumnRight ? pillColumnInset : 0))
    guard toolPillCenter?.constant != span.offset || toolPillWidth?.constant != -span.inset
    else { return }
    toolPillCenter?.constant = span.offset
    toolPillWidth?.constant = -span.inset
    guard animated, toolPill.shown, view.window != nil else { return }
    UIView.animate(
      withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]
    ) {
      self.view.layoutIfNeeded()
    }
  }

  /// Compact layout in compact height (iPhone landscape): one-row bar and side panels.
  private func updateLandscape() {
    let landscape = compactLayout && traitCollection.verticalSizeClass == .compact
    guard landscape != phoneLandscape || bottomBar.landscape != landscape else { return }
    phoneLandscape = landscape
    releaseShortcuts()
    for controller in controllers.values { controller.phoneLandscape = landscape }
    bottomBar.setLandscape(landscape)
    refreshPhonePanel()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    updateCompactLayout()
  }

  /// Compact chrome for phone-size scenes and narrow iPad windows, iPad chrome otherwise
  /// (regular iPad windows, unfolded iPhone Duo). Swaps only native chrome; the selected tab,
  /// its WebView and Figma's state stay as they are.
  private func updateCompactLayout() {
    let compact = PhoneExperiencePolicy.usesCompactLayout(
      traitCollection, width: view.bounds.width, current: compactLayout)
    defer { updateLandscape() }
    if !compact { PhoneExperiencePolicy.noteRegularLayout() }
    guard compact != compactLayout else { return }
    compactLayout = compact
    releaseShortcuts()
    strip.compact = compact
    for controller in controllers.values { controller.compactLayout = compact }
    replaceBottomBar(phone: compact)
    // The bottom toolbar can be hidden only in the regular layout.
    updateBottomBar()
    if !compact {
      // Nothing compact-only survives into the regular layout: keyboard-raised sheet, key row.
      raisedSheet = 0
      fieldNumeric = false
      updateKeyRow()
    }
    onCompactLayout?(compact)
    refreshPhonePanel()
  }

  /// The phone strip and the iPad row are different layouts; rebuild rather than morph.
  private func replaceBottomBar(phone: Bool) {
    let old = bottomBar
    let bar = BottomToolbarView(phone: phone)
    bar.interfaceScale = old.interfaceScale
    bar.isHidden = old.isHidden
    wire(bar)
    view.insertSubview(bar, aboveSubview: old)
    old.removeFromSuperview()
    bottomBar = bar
    let shown = content.bottomAnchor.constraint(equalTo: bar.topAnchor)
    shown.priority = .defaultHigh
    shownContentBottom = shown
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    shown.isActive = !bar.isHidden
    view.setNeedsLayout()
  }

  private func releaseShortcuts() {
    bottomBar.updateMask(0)
    active?.releaseTouchShortcuts()
  }

  /// Persisted for all windows; shown only in file tabs. Compact layouts always show it.
  private func toggleBottomToolbar() {
    guard !compactLayout else { return }
    setBottomToolbarVisible(!FolioPreferences().bottomToolbarVisible)
  }

  private func setBottomToolbarVisible(_ visible: Bool) {
    FolioPreferences().bottomToolbarVisible = visible
    for window in Self.windows.allObjects { window.updateBottomBar() }
  }

  /// One window per launch checks for the first-run welcome tour.
  private static var onboardingChecked = false
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !Self.onboardingChecked else { return }
    Self.onboardingChecked = true
    var automated = fixture || DebugLabConfiguration.offline
    #if DEBUG
      // Lab and UI-test launches pass flags; they never get the tour.
      automated = automated || ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--") }
    #endif
    guard !automated, !FolioPreferences().onboardingSeen else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.view.window != nil else { return }
      OnboardingController.present(from: self)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // iPad: the window width picks the layout. Switch after this layout pass, not inside it.
    if !PhoneExperiencePolicy.isPhone, view.window != nil,
      PhoneExperiencePolicy.compactWindow(width: view.bounds.width, current: compactLayout)
        != compactLayout
    {
      DispatchQueue.main.async { [weak self] in self?.updateCompactLayout() }
    }
    // The sheet's top (CSS) sits at fraction × browser height; the grab bar rests on it.
    let height = content.bounds.height
    sheetHandle.referenceHeight = height
    sheetHandleBottom?.constant = -(height * max(displayedSheetFraction, raisedSheet)).rounded()
    updateToolPillShown()
    placeWindowChrome()
  }

  /// iPhone Duo inner display: the top safe area (about 82 pt) is a status row that holds the
  /// clock, indicators and camera at its trailing end only. Like Safari, the regular strip rises
  /// into that row, centred `statusRowCentre` from the top, and stops short of the indicators.
  /// iPad's 24 pt status bar and compact phone layouts (Dynamic Island iPhones) never qualify.
  private static let statusRowMinimumInset: CGFloat = 60
  private static let statusRowCentre: CGFloat = 47.5
  /// Clock, Wi-Fi and camera, plus room for one Live Activity beside the camera.
  private static let statusRowTrailingReserve: CGFloat = 216

  /// iPhone Duo column layouts, else the top bar and its row. Compact (folded, side by side):
  /// the Duo top bar, the side column with tools, the page out to the column's edge. Regular
  /// (unfolded full screen): the iPad strip and bottom bar stay, minus what the column carries.
  private func placeWindowChrome() {
    let column = duoColumnPlacement()
    if column?.side != duoColumn?.side || column?.compact != duoColumn?.compact {
      duoColumn = column
      strip.menuDismiss()
      let compactColumn = column?.compact == true
      rail.isHidden = column == nil
      rail.compact = compactColumn
      titleBar.isHidden = !compactColumn
      // Under the Duo top bar the strip stays laid out but hidden; ⋯ opens its menu.
      strip.isHidden = compactColumn
      NSLayoutConstraint.deactivate(
        [
          stripSafeTop, stripStatusTop, stripColumnTop, stripColumnHeight, stripHeight,
          stripCollapsed, contentLeadingSafe, contentLeadingEdge, contentTrailingSafe,
          contentTrailingEdge,
        ]
        .compactMap { $0 })
      if let column, column.compact {
        stripColumnTop?.isActive = true
        stripColumnHeight?.isActive = true
        // The canvas runs behind the column, out to the window edge.
        (column.side == .left ? contentLeadingEdge : contentLeadingSafe)?.isActive = true
        (column.side == .right ? contentTrailingEdge : contentTrailingSafe)?.isActive = true
      } else {
        stripSafeTop?.isActive = true
        stripHeight?.isActive = true
        contentLeadingSafe?.isActive = true
        contentTrailingSafe?.isActive = true
      }
      bottomBar.commands =
        column == nil ? .all : compactColumn ? .none : .withoutHistoryAndClipboard
      // Folded and side by side the modifiers stay in the bar's one row, Layers and Properties
      // at its right; Keys is gone.
      if !compactColumn { bottomBar.keysExpanded = false }
      bottomBar.keysInRow = compactColumn
      pillColumnInset = compactColumn ? SideRailView.columnWidth : 0
      pillColumnRight = column?.side != .left
      placeToolPill(animated: false)
      renderDuoChrome(chromeState)
    }
    if let column {
      placeColumn(column)
      if column.compact {
        if strip.statusRowReserve != 0 { strip.statusRowReserve = 0 }
        placePageTrailingBorder(shown: false)
        return
      }
    }
    let safeTop = view.safeAreaInsets.top
    let inRow = !compactLayout && safeTop >= Self.statusRowMinimumInset
    let height = stripHeight?.constant ?? BrowserChromeView.height
    let top = max(0, (Self.statusRowCentre - height / 2).rounded())
    if stripStatusTop?.constant != top { stripStatusTop?.constant = top }
    if stripStatusTop?.isActive != inRow {
      stripSafeTop?.isActive = !inRow
      stripStatusTop?.isActive = inRow
    }
    let reserve = inRow ? Self.statusRowTrailingReserve : 0
    if strip.statusRowReserve != reserve { strip.statusRowReserve = reserve }
    // Only the Duo's inner display runs the full-width layout on a phone; in portrait Home sits
    // clear of the corner already (maintainer, 2026-11-11), so the square is landscape only.
    let duoLandscape =
      PhoneExperiencePolicy.isPhone && !compactLayout && view.bounds.width > view.bounds.height
    strip.clearsPageRail = duoLandscape
    strip.pageLeading = content.frame.minX - strip.frame.minX
    placePageTrailingBorder(shown: duoLandscape && content.frame.maxX < view.bounds.maxX - 1)
  }

  private func placePageTrailingBorder(shown: Bool) {
    if pageTrailingBorder.superview == nil {
      pageTrailingBorder.backgroundColor = ChromePalette.divider
      pageTrailingBorder.isUserInteractionEnabled = false
      view.insertSubview(pageTrailingBorder, aboveSubview: content)
    }
    pageTrailingBorder.isHidden = !shown
    guard shown else { return }
    // As thick as Figma's 1 px lines at the interface zoom, like the bars' hairlines.
    let pixels = max(1, view.traitCollection.displayScale)
    let width = max(1 / pixels, (interfaceScale * pixels).rounded() / pixels)
    pageTrailingBorder.frame = CGRect(
      x: content.frame.maxX, y: content.frame.minY, width: width, height: content.frame.height)
  }

  /// The hidden strip's frame under the Duo top bar, so the page starts at its 72 pt bottom.
  private static let columnTitleBarTop: CGFloat = 22
  private static let columnTitleBarHeight: CGFloat = 50

  /// The system's vertical column (outer display, inner display in landscape, the right of two
  /// windows side by side) shows up as a wide horizontal safe-area inset. A window beside the
  /// other one with no column of its own (the left of two) puts its column on its outer edge.
  /// The inner display in portrait, full width, has none and keeps the top bar.
  private static let systemColumnMinimumInset: CGFloat = 40
  /// Safari's status corner on the outer display without Live Activities (measured, simulator
  /// 2026-11-10); used only when UIKit's bar layout region is unavailable or reports none.
  private static let statusCornerFallback: CGFloat = 170

  private func duoColumnPlacement() -> (side: SideRailView.Side, compact: Bool)? {
    guard PhoneExperiencePolicy.usesDuoColumn, view.window != nil else { return nil }
    let insets = view.safeAreaInsets
    if insets.right >= Self.systemColumnMinimumInset { return (.right, compactLayout) }
    if insets.left >= Self.systemColumnMinimumInset { return (.left, compactLayout) }
    guard let screen = view.window?.windowScene?.screen else { return nil }
    let frame = view.convert(view.bounds, to: screen.coordinateSpace)
    guard compactLayout, frame.width < screen.bounds.width - 1 else { return nil }
    return (frame.minX <= 1 ? .left : .right, true)
  }

  /// Column ends: under the status corner and the top bar, above the home indicator, the bottom
  /// bar, an open sheet and the keyboard. Follows each layout pass, so Live Activities that
  /// stretch the status corner and the keyboard move it. The Duo top bar keeps clear of the
  /// system column it shares an edge with.
  private func placeColumn(_ column: (side: SideRailView.Side, compact: Bool)) {
    let insets = view.safeAreaInsets
    let system = max(insets.left, insets.right) >= Self.systemColumnMinimumInset
    // The 27.1 SDK's bar layout region ends below the status corner (170 pt folded, 120 pt
    // unfolded; simulator 2026-11-11). The corner-adapted safe area does not (about 17 pt).
    var corner: CGFloat = 0
    if system {
      corner = Self.statusCornerFallback
      #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
          let bar =
            view.edgeInsets(
              for: .bar(
                onEdge: column.side == .right ? UIRectEdge.right : UIRectEdge.left,
                extent: SideRailView.columnWidth)
            ).top
          if bar > 0 { corner = bar }
        }
      #endif
    }
    let gap = SideRailView.groupGap + SideRailView.control / 2
    let barBottom = column.compact ? DuoTitleBar.height : strip.frame.maxY
    rail.side = column.side
    rail.topCentreLimit = max(
      system ? corner + SideRailView.statusGap : 0, barBottom + gap)
    var limit = view.bounds.maxY - max(SideRailView.bottomCentre, insets.bottom + 24)
    // In the system column the column runs down to the screen's bottom edge, over the bottom
    // bar's background: the bar keeps its buttons inside the safe area, clear of it.
    if !bottomBar.isHidden && !system { limit = min(limit, bottomBar.frame.minY - gap) }
    // There, its bottom control stays level with the bar's row, which sits lower on the Duo.
    if !bottomBar.isHidden && system { limit = bottomBar.frame.minY + bottomBar.rowCentre }
    if !sheetHandle.isHidden { limit = min(limit, sheetHandle.frame.minY - gap) }
    if let keyboardTop { limit = min(limit, keyboardTop - gap) }
    // The number key row floats above the keyboard, across the column.
    if !keyRow.isHidden { limit = min(limit, keyRow.frame.minY - gap) }
    rail.bottomCentreLimit = limit
    let edge: CGFloat = 18
    titleBar.insets = (
      insets.left >= Self.systemColumnMinimumInset ? insets.left + 6 : edge,
      insets.right >= Self.systemColumnMinimumInset ? insets.right + 6 : edge
    )
    let report =
      "side=\(column.side) compact=\(column.compact) system=\(system) insets=\(Int(insets.left)),\(Int(insets.top)),\(Int(insets.right)),\(Int(insets.bottom)) corner=\(Int(corner))"
    if report != duoColumnReport {
      duoColumnReport = report
      active?.diagnostics.lifecycle("iPhone Duo column \(report)")
    }
  }

  private func wireRail() {
    titleBar.onHome = { [weak self] in self?.selectHome() }
    titleBar.onTabs = { [weak self] in self?.showPhoneTabs() }
    titleBar.onMore = { [weak self] source in self?.strip.toggleMenu(from: source, beside: false) }
    rail.onUndo = { [weak self] in self?.active?.touchShortcutKey("undo", down: nil) }
    rail.onRedo = { [weak self] in self?.active?.touchShortcutKey("redo", down: nil) }
    rail.onEdit = { [weak self] action, sender in
      self?.active?.touchShortcutEdit(action, sender: sender)
    }
    rail.toolsMenu = { [weak self] in self?.duoToolsMenu() ?? [] }
    strip.onRendered = { [weak self] state in self?.renderDuoChrome(state) }
    duoChromeObserver = NotificationCenter.default.addObserver(
      forName: PhoneExperiencePolicy.duoChromeChanged, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.view.setNeedsLayout() }
    }
  }

  /// The side column's tools menu: the bottom bar's other commands.
  private func duoToolsMenu() -> [UIMenuElement] {
    let key = { [weak self] (name: String) in self?.active?.touchShortcutKey(name, down: nil) }
    let edit = { [weak self] (action: ShortcutEditAction) in
      guard let self else { return }
      self.active?.touchShortcutEdit(action, sender: self.rail)
    }
    func item(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> UIAction {
      UIAction(title: title, image: SideRailView.image(icon)) { _ in run() }
    }
    return [
      UIMenu(
        options: .displayInline,
        children: [
          item("Duplicate", "plus.square.on.square") { key("duplicate") },
          item("Select All", ToolbarIcon.selectAll) { edit(.selectAll) },
        ]),
      UIMenu(
        options: .displayInline,
        children: [
          item("Group Selection", ToolbarIcon.group) { key("group") },
          item("Ungroup Selection", ToolbarIcon.ungroup) { key("ungroup") },
          item("Frame Selection", ToolbarIcon.frame) { key("frameSelection") },
        ]),
    ]
  }

  private func renderDuoChrome(_ state: B3BrowserChromeState) {
    guard let duoColumn else { return }
    let selected = state.tabs.first { $0.id == state.selectedID } ?? state.home
    let home = state.selectedID == state.home.id
    rail.isHidden = home
    if duoColumn.compact {
      titleBar.update(
        title: selected.home ? "Home" : selected.title ?? "Loading…", homeSelected: home,
        documentCount: state.tabs.count - 1, loading: state.loading)
    }
  }

  /// Keep one request in flight. Native controls follow the sample applied by WebKit,
  /// rather than running ahead while old input samples queue up across the process boundary.
  private func sendSheetDrag() {
    guard !sheetDragInFlight, !pendingSheetDrags.isEmpty, let tab = active else { return }
    let (fraction, phase) = pendingSheetDrags.removeFirst()
    sheetDragInFlight = true
    tab.phoneSheetDrag(phase, fraction: fraction) { [weak self, weak tab] applied in
      guard let self else { return }
      self.sheetDragInFlight = false
      guard tab === self.active, applied, !self.sheetHandle.isHidden else {
        self.pendingSheetDrags.removeAll()
        return
      }
      self.displayedSheetFraction = fraction
      UIView.performWithoutAnimation {
        self.sheetHandleBottom?.constant =
          -(self.content.bounds.height * max(fraction, self.raisedSheet)).rounded()
        self.view.layoutIfNeeded()
        self.updateToolPillShown()
      }
      self.sendSheetDrag()
    }
  }

  /// Shown when wanted and the canvas above the sheet is tall enough for it plus both gaps.
  private func updateToolPillShown() {
    var fits = true
    if toolPillAboveSheet?.isActive == true {
      let room = sheetHandle.frame.minY - content.frame.minY
      fits = room >= max(toolPill.bounds.height, 44) + 16
    }
    toolPill.setShown(toolPillWanted && fits && keyboardOverlap == 0, animated: view.window != nil)
  }

  /// iPhone: the docked keyboard is about to move. Sheet, grab bar, key row and pill jump once
  /// to their final state, without animation; only the keyboard itself animates.
  private func keyboardWillMove(to frame: CGRect?) {
    guard isViewLoaded, let screen = view.window?.windowScene?.screen else { return }
    var overlap: CGFloat = 0
    let top = frame.flatMap {
      $0.isEmpty ? nil : view.convert($0, from: screen.coordinateSpace).minY
    }
    let docked = top.flatMap { $0 < view.bounds.maxY - 1 ? $0 : nil }
    if docked != keyboardTop {
      keyboardTop = docked
      if duoColumn != nil { view.setNeedsLayout() }
    }
    if let frame, !frame.isEmpty {
      // The content bottom without the keyboard: the bar's top, or the view's bottom.
      let bottom = bottomBar.isHidden ? view.bounds.maxY : bottomBar.frame.minY
      overlap = max(0, bottom - view.convert(frame, from: screen.coordinateSpace).minY)
    }
    guard overlap != keyboardOverlap else { return }
    keyboardOverlap = overlap
    // Regular layouts keep their own keyboard handling; only the compact sheet snaps here.
    if compactLayout { applyKeyboard() }
  }

  /// The sheet's minimum fraction while the keyboard is up: room for 120 CSS px of fields (the
  /// focused one plus some context; the page scrolls it in), plus the 52 px key row for numeric
  /// fields, never past 0.85. Zero when the keyboard is down. The page gets the same overlap and
  /// floor and places the sheet's top at the same fraction of the browser height as the grab bar.
  static func sheetFloor(height: CGFloat, overlap: CGFloat, want: CGFloat) -> Double {
    guard overlap > 0, height > 0 else { return 0 }
    return Double(min(0.85, max(0, 1 - (height - overlap - want) / height)))
  }

  private func applyKeyboard() {
    raisedSheet = Self.sheetFloor(
      height: content.bounds.height, overlap: keyboardOverlap,
      want: (fieldNumeric ? 172 : 120) * interfaceScale)
    updateKeyRow()
    if keyboardOverlap > 0 { toolPill.setShown(false, animated: false) }
    let snap = { [weak self] in
      guard let self else { return }
      UIView.performWithoutAnimation {
        self.view.setNeedsLayout()
        self.view.layoutIfNeeded()
      }
    }
    snap()
    guard !sheetHandle.isHidden, let tab = active else { return }
    tab.phoneKeyboard(
      overlap: Double(keyboardOverlap / max(interfaceScale, 0.1)), floor: raisedSheet)
  }

  private func updateKeyRow() {
    let shown =
      fieldNumeric && keyboardOverlap > 0 && compactLayout
      && active?.phoneNumberKeyboard == true
    // The Duo column rests on the key row; place it again when the row comes or goes.
    if shown == keyRow.isHidden, duoColumn != nil { view.setNeedsLayout() }
    keyRow.setShown(shown)
  }

  private func togglePhonePanel(_ side: String) {
    guard let tab = active else { return }
    let request = UUID()
    phonePanelRequest = request
    tab.phonePanel(side, fraction: sheetHandle.fraction) {
      [weak self, weak tab] state, _, tool, mode in
      guard let self, let tab, tab === self.active, self.phonePanelRequest == request else {
        return
      }
      self.showPhonePanel(state, tool: tool, mode: mode)
    }
  }

  private func refreshPhonePanel(applyLayout: Bool = true) {
    guard let tab = active else { return showPhonePanel("off") }
    if applyLayout {
      tab.applyPhoneLayout()
      return
    }
    let request = UUID()
    phonePanelRequest = request
    // Another tab starts blank; the same tab (Figma's URL changes on every selection) keeps
    // its pill and panels until the reply, so nothing blinks.
    if ObjectIdentifier(tab) != toolPillTab { showPhonePanel("off") }
    tab.phonePanel(nil, fraction: sheetHandle.fraction) {
      [weak self, weak tab] state, _, tool, mode in
      guard let self, tab === self.active, self.phonePanelRequest == request else { return }
      self.showPhonePanel(state, tool: tool, mode: mode)
    }
  }

  private func showPhonePanel(
    _ state: String, tool: PhoneTool = .none, mode: PhoneMode = .unknown,
    tools: [PhoneVisibleTool]? = nil, overlay: Bool? = nil,
    panels: (left: Double, right: Double)? = nil
  ) {
    let state = compactLayout && active?.phoneLayoutActive == true ? state : "off"
    bottomBar.setPanel(state)
    let tab = active.map(ObjectIdentifier.init)
    if state == "off" || tab != toolPillTab {
      toolPillTab = tab
      toolPill.reset()
      phoneOverlay = false
      pillPanels = (0, 0)
    }
    if let overlay { phoneOverlay = overlay }
    let overlay = phoneOverlay
    if state != "off" { toolPill.report(tool, mode: mode, tools: tools) }
    // Tools float over the canvas; with a sheet open they sit above its grab bar, in landscape
    // between the open side panels, and hide while a Figma popover is open.
    let sides = active?.phoneSides == true
    let shown = (state == "left" || state == "right") && !bottomBar.isHidden && !sides
    let sidePanels = sides && ["left", "right", "both"].contains(state) && !bottomBar.isHidden
    active?.phoneSheetOpen = shown
    if !shown {
      pendingSheetDrags.removeAll()
      displayedSheetFraction = sheetHandle.fraction
    }
    let wantsPill =
      !bottomBar.isHidden && (state == "none" || ((shown || sidePanels) && !overlay))
    if shown != (toolPillAboveSheet?.isActive == true) {
      toolPillBottom?.isActive = !shown
      toolPillAboveSheet?.isActive = shown
      view.setNeedsLayout()
    }
    if let panels { pillPanels = sides ? panels : (0, 0) }
    if !sides { pillPanels = (0, 0) }
    placeToolPill(animated: sides)
    toolPillWanted = wantsPill
    updateToolPillShown()
    sheetHandle.setCovered(shown && overlay, animated: view.window != nil)
    if !shown && !sidePanels { showPhoneField(PhoneFieldState(numeric: false)) }
    guard sheetHandle.isHidden == shown else { return }
    sheetHandle.isHidden = !shown
    // An open sheet takes the keyboard itself, so the web view is not resized under it.
    keyboardBound?.isActive = !shown
    view.setNeedsLayout()
    if shown, keyboardOverlap > 0 {
      view.layoutIfNeeded()
      applyKeyboard()
    }
  }

  /// A sheet field gained or lost focus: the numeric key row.
  private func showPhoneField(_ state: PhoneFieldState) {
    fieldNumeric = state.numeric
    updateKeyRow()
  }

  private func updateBottomBar() {
    guard isViewLoaded else { return }
    defer { refreshPhonePanel() }
    let enabled = compactLayout || FolioPreferences().bottomToolbarVisible
    strip.showsBottomToolbar = enabled
    let visible = enabled && session.selectedID != session.home.id
    guard bottomBar.isHidden == visible else { return }
    if !visible { releaseShortcuts() }
    bottomBar.isHidden = !visible
    hiddenContentBottom?.isActive = false
    shownContentBottom?.isActive = false
    (visible ? shownContentBottom : hiddenContentBottom)?.isActive = true
    view.setNeedsLayout()
    view.layoutIfNeeded()
  }

  /// Owner-supplied interface zoom state, offered in the ⋯ menu.
  func setInterfaceZoom(_ state: InterfaceZoomState) {
    strip.interfaceZoom = state
    bottomBar.interfaceScale = CGFloat(state.scale)
    toolPill.interfaceScale = CGFloat(state.scale)
    interfaceScale = CGFloat(state.scale)
    if isViewLoaded { placeToolPill(animated: false) }
    let pixels = view.traitCollection.displayScale
    stripHeight?.constant =
      (max(36, BrowserChromeView.height * CGFloat(state.scale)) * pixels).rounded() / pixels
  }

  /// The separately owned container uses the same native selection path as Home.
  func selectHome() { showHome(loading: nil) }

  func showHome(loading url: URL?) {
    session.select(session.home.id)
    loadViewIfNeeded()
    showSelectedTab(ownerSelection: true)
    if let url, TabNavigationRouter.classify(url) == .dashboard {
      controller(for: session.home).loadDashboard(url)
    }
  }

  #if DEBUG
    /// Opt-in plain controls for local-fixture runtime checks, not product chrome.
    private func installChromeVisibilityRegressionControls() {
      let home = UIButton(type: .system)
      home.setTitle("Select Home", for: .normal)
      home.accessibilityIdentifier = "b4-select-home"
      home.addAction(UIAction { [weak self] _ in self?.selectHome() }, for: .touchUpInside)
      let controls = UIStackView(arrangedSubviews: [home])
      controls.spacing = 12
      controls.backgroundColor = .secondarySystemBackground
      controls.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(controls)
      NSLayoutConstraint.activate([
        controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        controls.heightAnchor.constraint(equalToConstant: 44),
      ])
    }
  #endif

  static func hostAllowanceRequiresEviction(_ availableBytes: UInt64?) -> Bool {
    guard let availableBytes else { return false }
    return availableBytes < memoryFloor
  }

  private var currentAvailableMemory: UInt64 {
    UInt64(os_proc_available_memory())
  }

  private func sampleMemory(_ event: String) {
    do { try memory.append(event: event, availableBytes: currentAvailableMemory) } catch {
      active?.diagnostics.lifecycle("Memory report persistence failed")
    }
  }

  /// Esc closed a Folio overlay: give the keyboard back to the selected page.
  func restoreActiveBrowserFocus() {
    active?.restoreBrowserFocus(reason: .nativeAlertDismissed)
  }

  /// Download Center "Show source tab": selects the tab in whichever window holds it.
  static func showTab(_ id: UUID) {
    guard let owner = windows.allObjects.first(where: { $0.session.tabs.contains { $0.id == id } })
    else { return }
    owner.session.select(id)
    owner.showSelectedTab(ownerSelection: true)
    if let scene = owner.view.window?.windowScene, scene.activationState != .foregroundActive {
      UIApplication.shared.requestSceneSessionActivation(
        scene.session, userActivity: nil, options: nil)
    }
  }

  func showSelectedTab(ownerSelection: Bool = false) {
    let initialAttachment = active == nil
    let tab = session.selected
    tab.lastUsed = Date()
    guard active?.tabSession.id != tab.id else {
      enforceTabRetention()
      strip.render(chromeState)
      updateBottomBar()
      if ownerSelection { active?.restoreBrowserFocus(reason: .sameTabSelected) }
      return
    }
    releaseShortcuts()
    if let old = active {
      old.captureTabSnapshot()
      old.setTabActive(false)
      old.willMove(toParent: nil)
      old.view.removeFromSuperview()
      old.removeFromParent()
    }
    let controller = controller(for: tab)
    active = controller
    addChild(controller)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(controller.view)
    NSLayoutConstraint.activate([
      controller.view.topAnchor.constraint(equalTo: content.topAnchor),
      controller.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
    ])
    updateBottomBar()
    // Complete geometry before appearance/focus or a related child starts loading.
    view.layoutIfNeeded()
    controller.didMove(toParent: self)
    controller.setTabActive(true, restoreFocus: ownerSelection || initialAttachment)
    enforceTabRetention()
    strip.render(chromeState)
  }

  private func enforceTabRetention(memoryWarning: Bool = false, lowMemory: Bool = false) {
    let pressure = memoryWarning || lowMemory
    if pressure {
      // Every window receives the same UIApplication notification. Evict once.
      guard Date().timeIntervalSince(Self.lastPressureEviction) > 0.5 else { return }
      Self.lastPressureEviction = Date()
    }
    let windows = Self.windows.allObjects
    let live = windows.flatMap { window in
      window.controllers.values.filter { controller in
        controller.tabSession.kind == .document
          && window.session.tabs.contains(where: { $0.id == controller.tabSession.id })
      }.map { (window, $0) }
    }
    let candidates = live.filter { window, controller in
      controller.tabSession.id != window.session.selectedID
        && !controller.hasProtectedTabWork && controller.dashboardReload == nil
        && !controller.tabSession.creatingFile
    }.sorted {
      if $0.1.tabSession.isPinned != $1.1.tabSession.isPinned {
        return !$0.1.tabSession.isPinned
      }
      return $0.1.tabSession.lastUsed < $1.1.tabSession.lastUsed
    }
    let limit = keepTabsLoaded == 0 ? PhoneExperiencePolicy.automaticTabLimit : keepTabsLoaded
    let count = pressure ? min(1, candidates.count) : limit == 0 ? 0 : max(0, live.count - limit)
    for (window, controller) in candidates.prefix(count) {
      if !pressure && controller.tabSession.snapshot == nil && !controller.snapshotAttempted {
        controller.captureTabSnapshot()
      }
      // Normal eviction waits for the departure image; pressure releases immediately.
      if !pressure && controller.snapshotPending { break }
      let tab = controller.tabSession
      // No page-content edit inspection. Native tab-use recency is the fallback.
      let title = tab.displayTitle
      let reason =
        memoryWarning ? "iPadOS memory warning" : lowMemory ? "low host allowance" : "hard cap"
      let event = "Tab discarded; tab=\(tab.id) reason=\(reason)"
      controller.diagnostics.memoryEvent(event)
      window.active?.diagnostics.lifecycle(event)
      controller.closeTab()
      tab.displayTitle = title
      tab.discarded = true
      window.controllers.removeValue(forKey: tab.id)
    }
    for window in windows {
      window.strip.keepTabsLoaded = keepTabsLoaded
      window.strip.render(window.chromeState)
    }
  }

  private func controller(for tab: TabSession) -> FigmaWebViewController {
    if let existing = controllers[tab.id] { return existing }
    let controller = FigmaWebViewController(
      tab: tab, websiteDataStore: websiteDataStore, memory: memory,
      fixtureNumber: fixture ? fixtureNumbers[tab.id] ?? 0 : nil,
      memoryOwnership: memoryOwnership, windowID: session.id, makeWebView: makeWebView)
    controller.compactLayout = compactLayout
    controller.phoneLandscape = phoneLandscape
    controller.onPencilAction = { [weak self, weak controller] action in
      guard let self, self.active === controller else { return }
      switch action {
      case .none, .systemSetting: break
      case .showBottomToolbar: self.toggleBottomToolbar()
      case .nextTab: self.cycleTab(offset: 1)
      case .previousTab: self.cycleTab(offset: -1)
      default:
        if let edit = action.nativeEdit {
          controller?.touchShortcutEdit(edit, sender: self.content)
        } else {
          controller?.touchShortcutKey(action.rawValue)
        }
      }
    }
    controller.onSnapshotReady = { [weak self] in self?.enforceTabRetention() }
    controller.onBackgroundTermination = { [weak self] event in
      self?.active?.diagnostics.lifecycle(event)
    }
    controller.onShortcutState = { [weak self, weak controller] mask in
      guard let self, self.active === controller else { return }
      self.bottomBar.updateMask(mask)
    }
    controller.onRoute = { [weak self, weak controller] url, configuration in
      guard let self, controller != nil else { return nil }
      return self.route(url, configuration: configuration)
    }
    controller.onRouteEvidenceRecorded = { [weak self] line in
      guard let self else { return }
      self.windowRouteEvidence.append(
        "\(ISO8601DateFormatter().string(from: Date())) \(Privacy.sanitize(line))")
      if self.windowRouteEvidence.count > 128 { self.windowRouteEvidence.removeFirst() }
    }
    controller.diagnostics.windowRouteReport = { [weak self] in self?.windowRouteEvidence ?? [] }
    controller.onHomeFileObserved = { [weak self] url in _ = self?.route(url) }
    controller.onDocumentDashboardObserved = { [weak self, weak tab] url in
      guard let self, let tab else { return }
      if tab.creatingFile || tab.fileKey == nil {
        self.showHome(loading: url)
        if let source = self.controllers[tab.id], !source.hasProtectedTabWork {
          self.closeTab(tab.id)
        }
      } else {
        // Keep protected work visible and alive. Otherwise retain session order while
        // hiding only its chrome representation during the bounded verification.
        if let source = self.controllers[tab.id], !source.hasProtectedTabWork {
          source.reloadFileAfterDashboardHandoff()
        }
        self.showHome(loading: url)
        if self.hidesDashboardHandoffTab(tab.id) {
          self.controllers[tab.id]?.recordWindowEvidence("handoffTab=hidden sessionKept=true")
        }
      }
    }
    controller.onDashboardReloadVisibilityChanged = { [weak self, weak tab] in
      guard let self, let tab else { return }
      self.controllers[tab.id]?.recordWindowEvidence(
        "handoffTab=visibility hidden=\(self.hidesDashboardHandoffTab(tab.id))")
      self.strip.render(self.chromeState)
    }
    controller.onDashboardReloadRejected = { [weak self, weak tab] in
      guard let self, let tab else { return }
      guard let source = self.controllers[tab.id], self.session.selectedID != tab.id,
        !source.hasProtectedTabWork
      else {
        self.controllers[tab.id]?.recordWindowEvidence(
          "reloadAfterHandoff=protected tabKept=true")
        self.strip.render(self.chromeState)
        return
      }
      // Recheck protection at the actual close, including work started after handoff.
      source.recordWindowEvidence("reloadAfterHandoff=verified closed=true")
      self.closeTab(tab.id, remember: false)
    }
    controller.onOpenLink = { [weak self] url, foreground in
      guard let self else { return }
      _ = self.route(url, foreground: foreground)
    }
    controller.onAdoptRelatedBrowser = { [weak self] url, browser in
      guard let self, case .file(let key) = TabNavigationRouter.classify(url) else {
        return .declined
      }
      if let existing = self.session.tabs.first(where: {
        $0.kind == .document && $0.routingURL.map(TabNavigationRouter.classify) == .file(key)
      }) {
        self.session.select(existing.id)
        self.showSelectedTab(ownerSelection: true)
        return .selectedExisting
      }
      // Adoption uses the exact related child, never reloads/replays its initial request.
      let tab = self.session.add(url: url)
      if self.fixture { self.fixtureNumbers[tab.id] = (self.fixtureNumbers.values.max() ?? 0) + 1 }
      let destination = self.controller(for: tab)
      destination.pendingRelatedBrowser = browser
      self.onAdoptMainWebView?(browser)
      self.showSelectedTab(ownerSelection: true)
      #if DEBUG
        destination.loadPromotedFixture(url)
      #endif
      return .adopted
    }
    controller.onOpenCurrentFile = { [weak self] url in self?.addTab(url: url) }
    controller.onTitleChange = { [weak self, weak tab] in
      guard let self, let tab, self.session.tabs.contains(where: { $0 === tab })
      else { return }
      self.session.saveArchive()
      self.strip.render(self.chromeState)
    }
    controller.onResolvedCreation = { [weak self, weak tab] url in
      guard let self, let tab else { return }
      if let retired = self.session.resolveCreation(tab.id, url: url) {
        self.showSelectedTab()
        self.controllers.removeValue(forKey: retired)?.closeTab()
        self.fixtureNumbers.removeValue(forKey: retired)
      }
      self.strip.render(self.chromeState)
    }
    controller.onPhoneState = { [weak self, weak controller] state in
      guard let self, self.active === controller else { return }
      self.showPhonePanel(
        state.panel, tool: state.tool, mode: state.mode, tools: state.visibleTools,
        overlay: state.overlay, panels: (state.panelLeft, state.panelRight))
    }
    controller.onPhoneField = { [weak self, weak controller] state in
      guard let self, self.active === controller,
        !self.sheetHandle.isHidden || controller?.phoneSides == true
      else { return }
      self.showPhoneField(state)
    }
    controller.onPhoneLayoutChange = { [weak self, weak controller] ready in
      guard let self, self.active === controller else { return }
      // Ready again (Figma's URL changes on every selection): ask the page without blanking
      // the pill first; only a real teardown shows "off".
      guard ready else {
        self.phonePanelRequest = UUID()
        self.showPhonePanel("off")
        return
      }
      self.refreshPhonePanel(applyLayout: false)
    }
    controller.onNavigationStateChange = { [weak self] in
      guard let self else { return }
      self.strip.render(self.chromeState)
    }
    controllers[tab.id] = controller
    return controller
  }

  @discardableResult
  func addTab(url: URL, ownerSelection: Bool = true) -> TabSession {
    let tab = session.add(url: url)
    if fixture { fixtureNumbers[tab.id] = (fixtureNumbers.values.max() ?? 0) + 1 }
    showSelectedTab(ownerSelection: ownerSelection)
    return tab
  }

  func openExternalLink(_ url: URL) {
    guard let url = FolioLink.validated(url) else { return }
    if TabNavigationRouter.classify(url) == .dashboard {
      showHome(loading: url)
      controller(for: session.home).recordExternalLinkDelivery(url)
      return
    }
    let count = session.tabs.count
    let tab = session.openFile(url: url)
    if session.tabs.count == count {
      loadViewIfNeeded()
      showSelectedTab(ownerSelection: true)
      controller(for: tab).recordExternalLinkDelivery(url)
      return
    }
    // Seed the runtime request before either host or tab view can start loading.
    controller(for: tab).openExternalLink(url)
    loadViewIfNeeded()
    showSelectedTab(ownerSelection: true)
  }

  func closeSelectedTab() {
    closeTab(session.selectedID)
  }

  func closeTab(_ id: UUID, remember: Bool = true) {
    guard session.close(id, remember: remember) else { return }
    showSelectedTab(ownerSelection: true)
    controllers.removeValue(forKey: id)?.closeTab()
    fixtureNumbers.removeValue(forKey: id)
  }

  private func hidesDashboardHandoffTab(_ id: UUID) -> Bool {
    guard id != session.selectedID, let controller = controllers[id] else { return false }
    return controller.dashboardReload?.hidesTab == true && !controller.hasProtectedTabWork
  }

  var chromeState: B3BrowserChromeState {
    B3BrowserChromeState(
      tabs: session.tabs.filter { !hidesDashboardHandoffTab($0.id) }.map {
        .init(
          id: $0.id, home: $0.kind == .home,
          title: $0.displayTitle,
          pinned: $0.isPinned, discarded: $0.discarded,
          symbol: ChromeFileIcon.symbol(
            for: $0.creatingFile ? TabNavigationRouter.newDesignURL : $0.routingURL))
      }, selectedID: session.selectedID,
      canGoBack: active?.webView?.canGoBack ?? false,
      canGoForward: active?.webView?.canGoForward ?? false,
      loading: active?.webView?.isLoading ?? false,
      canReopenClosedTab: session.canReopenClosedTab)
  }

  /// iPhone (Alpha): the tab list sheet replaces the strip. Same actions as the strip.
  private func showPhoneTabs() {
    guard presentedViewController == nil else { return }
    let list = PhoneTabSwitcherController { [weak self] in
      self?.chromeState
        ?? B3BrowserChromeState(
          tabs: [], selectedID: UUID(), canGoBack: false, canGoForward: false, loading: false)
    }
    list.onSelect = { [weak self] id in
      self?.session.select(id)
      self?.showSelectedTab(ownerSelection: true)
    }
    list.onClose = { [weak self] id in self?.closeTab(id) }
    list.onPin = { [weak self] id in
      self?.session.togglePin(id)
      if let self { self.strip.render(self.chromeState) }
    }
    list.onCopy = strip.onCopy
    list.onReorder = { [weak self] id, before in
      self?.session.reorder(id, before: before)
      if let self { self.strip.render(self.chromeState) }
    }
    list.onNewFile = { [weak self] in self?.addTab(url: TabNavigationRouter.newDesignURL) }
    list.onReopen = { [weak self] in self?.reopenClosedTab() }
    list.onOpenLink = { [weak self] in self?.promptForLink() }
    let navigation = UINavigationController(rootViewController: list)
    navigation.modalPresentationStyle = .pageSheet
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 16
    }
    present(navigation, animated: true)
  }

  /// Opens a pasted figma.com link through the same validation as Share and universal links.
  private func promptForLink() {
    guard presentedViewController == nil else { return }
    let alert = UIAlertController(
      title: "Open link", message: "Paste a figma.com file or prototype link.",
      preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "https://www.figma.com/design/…"
      field.keyboardType = .URL
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Open", style: .default) { [weak self, weak alert] _ in
        guard let raw = alert?.textFields?.first?.text,
          let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        guard FolioLink.validated(url) != nil else {
          self?.showLinkRejected()
          return
        }
        self?.openExternalLink(url)
      })
    present(alert, animated: true)
  }

  private func showLinkRejected() {
    let alert = UIAlertController(
      title: "Not a Figma link", message: "Folio opens figma.com file and prototype links.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  private func confirmReload() {
    guard let owner = active, presentedViewController == nil else { return }
    let alert = UIAlertController(
      title: "Reload page?",
      message: "Unsaved work may be lost. Confirm your work is saved before reloading.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Reload", style: .destructive) { [weak self, weak owner] _ in
        guard let self, let owner, self.active === owner else { return }
        owner.webView.reload()
      })
    present(alert, animated: true)
  }

  private func confirmCloseOthers(_ id: UUID) {
    guard session.tabs.contains(where: { $0.id == id }), presentedViewController == nil else {
      return
    }
    let alert = UIAlertController(
      title: "Close other tabs?",
      message: "Unsaved work in those tabs may be lost. Confirm it is saved before closing.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Close other tabs", style: .destructive) { [weak self] _ in
        guard let self else { return }
        let closed = self.session.closeOthers(keeping: id)
        self.showSelectedTab(ownerSelection: true)
        for id in closed {
          self.controllers.removeValue(forKey: id)?.closeTab()
          self.fixtureNumbers.removeValue(forKey: id)
        }
      })
    present(alert, animated: true)
  }

  // Reserved Folio chords remain available even when WebKit's keyboard sink has a caret.
  // Keep native sheets and auth popups in control of their own responder chains.
  private var allowsFolioKeyCommands: Bool {
    isViewLoaded && view.window != nil && active?.popup == nil
      && presentedViewController == nil && active?.presentedViewController == nil
      && parent?.presentedViewController == nil && !hasMarkedText
  }

  // WEBKIT_INTERNAL: WebKit's focused descendant exposes public UITextInput state.
  // Read only; never acquire focus or inspect composed text. Device acceptance pending.
  private var hasMarkedText: Bool {
    guard let root = view.window,
      let input = BrowserResponderFocus.first(in: root) as? any UITextInput
    else { return false }
    return input.markedTextRange != nil
  }

  private var allowsTabCycling: Bool {
    guard allowsFolioKeyCommands, let root = view.window else { return false }
    if let responder = BrowserResponderFocus.first(in: root),
      responder is UITextField || responder is UITextView
    {
      return false
    }
    // Safe/related children have no DOM observer. Yield Ctrl+Tab conservatively there.
    return active?.visibleTextEditing == false
  }

  override var keyCommands: [UIKeyCommand]? {
    guard allowsFolioKeyCommands else { return [] }
    let flags: UIKeyModifierFlags = [.command, .control]
    var commands = [
      folioCommand(
        "Next tab", UIKeyCommand.inputRightArrow, [.command, .alternate],
        #selector(nextTabWhileEditingCommand)),
      folioCommand(
        "Previous tab", UIKeyCommand.inputLeftArrow, [.command, .alternate],
        #selector(previousTabWhileEditingCommand)),
      folioCommand("Last used tab", "0", flags, #selector(lastUsedTabCommand)),
      folioCommand("Next tab", "\t", .control, #selector(nextTabCommand)),
      folioCommand("Previous tab", "\t", [.control, .shift], #selector(previousTabCommand)),
      folioCommand("Close tab", "w", flags, #selector(closeTabCommand)),
      folioCommand(
        "Reopen closed tab", "t", [.command, .control, .shift], #selector(reopenTabCommand)),
      folioCommand("New window", "n", flags, #selector(newWindowCommand)),
      folioCommand("Home", "h", flags, #selector(homeCommand)),
      folioCommand(
        "Toggle bottom toolbar", "b", [.command, .control, .shift],
        #selector(bottomToolbarCommand)),
      folioCommand(
        "Increase interface zoom", "=", [.command, .alternate], #selector(zoomInCommand)),
      folioCommand(
        "Decrease interface zoom", "-", [.command, .alternate], #selector(zoomOutCommand)),
      folioCommand(
        "Reset interface zoom", "0", [.command, .alternate], #selector(zoomResetCommand)),
      folioCommand("Show downloads", "j", flags, #selector(downloadsCommand)),
      folioCommand("Settings…", ",", .command, #selector(settingsCommand)),
      folioCommand(
        "Developer Tools", "i", [.command, .alternate], #selector(developerToolsCommand)),
    ]
    for number in 1...9 {
      commands.append(
        folioCommand(
          number == 1 ? "Select tab 1 (Home)" : "Select tab \(number)",
          String(number), flags, #selector(selectTabCommand(_:))))
    }
    if !allowsTabCycling {
      commands.removeAll {
        $0.action == #selector(nextTabCommand) || $0.action == #selector(previousTabCommand)
      }
    }
    return commands
  }

  private func folioCommand(
    _ title: String, _ input: String, _ flags: UIKeyModifierFlags, _ action: Selector
  ) -> UIKeyCommand {
    let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
    command.discoverabilityTitle = title
    command.wantsPriorityOverSystemBehavior = true
    return command
  }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    let actions: Set<Selector> = [
      #selector(closeTabCommand), #selector(nextTabCommand), #selector(previousTabCommand),
      #selector(reopenTabCommand), #selector(newWindowCommand), #selector(homeCommand),
      #selector(bottomToolbarCommand), #selector(zoomInCommand),
      #selector(zoomOutCommand),
      #selector(zoomResetCommand), #selector(downloadsCommand), #selector(selectTabCommand(_:)),
      #selector(settingsCommand), #selector(developerToolsCommand),
      #selector(nextTabWhileEditingCommand),
      #selector(previousTabWhileEditingCommand), #selector(lastUsedTabCommand),
    ]
    guard actions.contains(action) else {
      return super.canPerformAction(action, withSender: sender)
    }
    guard allowsFolioKeyCommands else { return false }
    if action == #selector(nextTabCommand) || action == #selector(previousTabCommand) {
      return allowsTabCycling
    }
    if action == #selector(lastUsedTabCommand) { return session.previousSelectedID != nil }
    if action == #selector(closeTabCommand) {
      return session.selected.kind != .home && !session.selected.isPinned
    }
    if action == #selector(reopenTabCommand) { return session.canReopenClosedTab }
    if action == #selector(selectTabCommand(_:)), let command = sender as? UIKeyCommand,
      let number = command.input.flatMap(Int.init)
    {
      return session.tabs.indices.contains(number - 1)
    }
    return true
  }

  /// Shortcut entry point: an open ⋯ menu closes first so the action isn't hidden behind it.
  private var readyForFolioCommand: Bool {
    ChromeMenuPresenter.dismissOpen(in: view.window)
    return allowsFolioKeyCommands
  }
  private var readyForTabCycling: Bool {
    ChromeMenuPresenter.dismissOpen(in: view.window)
    return allowsTabCycling
  }

  @objc private func closeTabCommand() {
    guard readyForFolioCommand else { return }
    closeSelectedTab()
  }
  @objc private func nextTabCommand() { if readyForTabCycling { cycleTab(offset: 1) } }
  @objc private func previousTabCommand() { if readyForTabCycling { cycleTab(offset: -1) } }
  @objc private func nextTabWhileEditingCommand() {
    if readyForFolioCommand { cycleTab(offset: 1) }
  }
  @objc private func previousTabWhileEditingCommand() {
    if readyForFolioCommand { cycleTab(offset: -1) }
  }
  @objc private func lastUsedTabCommand() {
    guard readyForFolioCommand, let id = session.previousSelectedID else { return }
    session.select(id)
    showSelectedTab(ownerSelection: true)
  }
  @objc private func reopenTabCommand() { if readyForFolioCommand { reopenClosedTab() } }
  @objc private func newWindowCommand() {
    guard readyForFolioCommand,
      PhoneExperiencePolicy.supportsMultipleWindows(on: view.window?.windowScene?.screen)
    else { return }
    FolioWindows.newWindow(from: view.window?.windowScene)
  }
  @objc private func homeCommand() { if readyForFolioCommand { selectHome() } }
  @objc private func bottomToolbarCommand() {
    if readyForFolioCommand { toggleBottomToolbar() }
  }
  @objc private func zoomInCommand() { if readyForFolioCommand { onInterfaceZoom?(.increase) } }
  @objc private func zoomOutCommand() { if readyForFolioCommand { onInterfaceZoom?(.decrease) } }
  @objc private func zoomResetCommand() { if readyForFolioCommand { onInterfaceZoom?(.reset) } }
  @objc private func downloadsCommand() {
    if readyForFolioCommand { active?.downloads.showDownloadCenter() }
  }
  @objc private func developerToolsCommand() {
    if readyForFolioCommand { showDeveloperTools() }
  }

  @objc private func settingsCommand() {
    if readyForFolioCommand { showSettings() }
  }

  private func showSettings() {
    configurePreferencesDisplay()
    active?.showPreferences(
      settings: true,
      controls: FolioSettingsDisplay(
        canHideBottomToolbar: { [weak self] in self?.compactLayout == false },
        bottomToolbarVisible: { FolioPreferences().bottomToolbarVisible },
        setBottomToolbarVisible: { [weak self] in self?.setBottomToolbarVisible($0) }))
  }

  /// Opens or closes Developer Tools on the selected tab, with this window's display settings.
  private func showDeveloperTools() {
    configurePreferencesDisplay()
    active?.toggleDeveloperTools()
  }

  private func configurePreferencesDisplay() {
    guard let active else { return }
    let strip = strip
    active.developerDisplay = DeveloperToolsDisplay(
      zoom: { [weak strip] in strip?.interfaceZoom },
      setZoom: { [weak strip] in strip?.onInterfaceZoom?($0) },
      keepTabsLoaded: { [weak self] in self?.keepTabsLoaded ?? 0 },
      setKeepTabsLoaded: { [weak strip] in strip?.onKeepTabsLoaded?($0) })
  }
  @objc private func selectTabCommand(_ command: UIKeyCommand) {
    guard readyForFolioCommand, let number = command.input.flatMap(Int.init),
      session.tabs.indices.contains(number - 1)
    else { return }
    session.select(session.tabs[number - 1].id)
    showSelectedTab(ownerSelection: true)
  }

  private func reopenClosedTab() {
    guard let tab = session.reopenClosedTab() else { return }
    if fixture, fixtureNumbers[tab.id] == nil {
      fixtureNumbers[tab.id] = (fixtureNumbers.values.max() ?? 0) + 1
    }
    showSelectedTab(ownerSelection: true)
  }

  private func cycleTab(offset: Int) {
    guard let index = session.tabs.firstIndex(where: { $0.id == session.selectedID }) else {
      return
    }
    session.select(session.tabs[(index + offset + session.tabs.count) % session.tabs.count].id)
    showSelectedTab(ownerSelection: true)
  }

  private func route(
    _ url: URL,
    configuration: WKWebViewConfiguration? = nil, foreground: Bool = true
  ) -> WKWebView? {
    if TabNavigationRouter.classify(url) == .dashboard {
      showHome(loading: url)
      return nil
    }
    switch TabNavigationRouter.classify(url) {
    case .file, .creation: break
    default: return nil
    }
    let count = session.tabs.count
    let tab = session.openFile(url: url, selecting: foreground)
    if session.tabs.count == count {
      showSelectedTab(ownerSelection: true)
      return nil
    }
    if fixture { fixtureNumbers[tab.id] = (fixtureNumbers.values.max() ?? 0) + 1 }
    let destination = controller(for: tab)
    if !foreground {
      destination.loadViewIfNeeded()
      destination.setTabActive(false)
    }
    if let configuration { destination.relatedConfiguration = configuration }
    showSelectedTab(ownerSelection: true)
    return configuration == nil ? nil : destination.webView
  }
  #if DEBUG
    private func promptForTab() {
      if fixture && !ProcessInfo.processInfo.arguments.contains("--tabs-url-alert") {
        addTab(url: SessionState.startURL)
        return
      }
      let alert = UIAlertController(
        title: "New tab", message: "Enter a Figma file URL.", preferredStyle: .alert)
      alert.addTextField { field in
        field.placeholder = "https://www.figma.com/design/…"
        field.keyboardType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
      }
      active?.invalidateBrowserFocus()
      alert.addAction(
        UIAlertAction(title: "Cancel", style: .cancel) { [weak self, weak alert] _ in
          afterAlertDismissal(alert) { [weak self] in
            self?.active?.restoreBrowserFocus(reason: .nativeAlertDismissed)
          }
        })
      alert.addAction(
        UIAlertAction(title: "Open", style: .default) { [weak self, weak alert] _ in
          guard let raw = alert?.textFields?.first?.text,
            let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            let safe = Privacy.recoveryURL(url), safe != SessionState.startURL
          else {
            afterAlertDismissal(alert) { [weak self] in
              self?.active?.restoreBrowserFocus(reason: .nativeAlertDismissed)
            }
            return
          }
          afterAlertDismissal(alert) { [weak self] in
            self?.addTab(url: safe)
            self?.active?.restoreBrowserFocus(reason: .nativeAlertDismissed)
          }
        })
      present(alert, animated: true)
    }
  #endif
}
