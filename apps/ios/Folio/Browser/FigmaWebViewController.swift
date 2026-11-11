import GameController
import UIKit
import WebKit

@MainActor
final class FigmaWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
  var onOpenLink: ((URL, Bool) -> Void)?
  var onAdoptRelatedBrowser: ((URL, WKWebView) -> PopupController.Promotion)?
  var pendingRelatedBrowser: WKWebView?
  private(set) var routeEvidence: [String] = []
  var onRouteEvidenceRecorded: ((String) -> Void)?
  func recordWindowEvidence(_ detail: String) {
    guard diagnostics.inputLogging else { return }
    let line = "Tab window \(detail) sourceTab=\(tabSession.id)"
    diagnostics.log(line)
    onRouteEvidenceRecorded?(line)
  }
  func recordRouteEvidence(
    _ event: TabNavigationRouter.Event, url: URL?, input: TabNavigationRouter.Input? = nil
  ) {
    guard diagnostics.inputLogging else { return }
    var line =
      TabNavigationRouter.evidence(event, url: url, input: input)
      + " sourceHome=\(tabSession.kind == .home) sourceTab=\(tabSession.id)"
    if let url, case .file(let key) = TabNavigationRouter.classify(url),
      let current = tabSession.routingURL,
      case .file(let currentKey) = TabNavigationRouter.classify(current)
    {
      line += " sameFile=\(key == currentKey)"
    }
    if let url, TabNavigationRouter.classify(url) == .dashboard {
      line += " " + TabNavigationRouter.dashboardEvidence(url)
    }
    routeEvidence.append(line)
    if routeEvidence.count > 128 { routeEvidence.removeFirst(routeEvidence.count - 128) }
    diagnostics.log(line)
    onRouteEvidenceRecorded?(line)
  }
  var scriptFreeRelated = false
  var onRoute: ((URL, WKWebViewConfiguration?) -> WKWebView?)?
  var onOpenCurrentFile: ((URL) -> Void)?
  var onResolvedCreation: ((URL) -> Void)?
  var onHomeFileObserved: ((URL) -> Void)?
  var onDocumentDashboardObserved: ((URL) -> Void)?
  var onDashboardReloadRejected: (() -> Void)?
  var onDashboardReloadVisibilityChanged: (() -> Void)?
  var hasProtectedTabWork: Bool {
    popup != nil || downloads.pendingCount > 0 || presentedViewController != nil
  }
  struct DashboardReload {
    let id = UUID()
    let navigation: WKNavigation
    let key: String
    let generation: UUID
    let deadline: Date
    var started = false
    var committed = false
    var responseStatus: Int?
    var availabilityScheduled = false
    var unavailableMatches = 0
    var hidesTab = true
    var healthyCanvasChecks = 0
    var healthyCanvasCheckInFlight = false
  }
  var dashboardReload: DashboardReload? {
    didSet {
      if oldValue?.hidesTab != dashboardReload?.hidesTab {
        onDashboardReloadVisibilityChanged?()
      }
    }
  }
  var pendingHandoffURL: URL?
  var lastBackgroundRestore: Date?
  var onTitleChange: (() -> Void)?
  var relatedConfiguration: WKWebViewConfiguration?
  var relatedInitialNavigation = false
  /// The owning scene uses the compact layout (iPhone phone-size or narrow iPad window). Set by
  /// the window controller; the sidebar sheet layout runs only then.
  var compactLayout = PhoneExperiencePolicy.isPhone
  /// iPhone phone-size layout in compact height (landscape): side panels instead of the sheet.
  var phoneLandscape = false
  let tabSession: TabSession
  let websiteDataStore: WKWebsiteDataStore
  let makeWebView: (WKWebViewConfiguration) -> WKWebView
  let fixtureNumber: Int?
  let enablePinchHarness: Bool
  let memoryOwnership: MemoryLabOwnership
  private(set) var isTabActive = true
  var session: SessionState { tabSession.session }
  let diagnostics: DiagnosticsStore
  let bridge: ScriptBridge
  lazy var standardLinks = StandardFileLinkHandler(owner: self)

  init(
    tab: TabSession? = nil,
    websiteDataStore: WKWebsiteDataStore = .default(),
    memory: MemoryLabStore = MemoryLabStore(), fixtureNumber: Int? = nil,
    enablePinchHarness: Bool = false,
    bridge: ScriptBridge = ScriptBridge(),
    memoryOwnership: MemoryLabOwnership = MemoryLabOwnership(), windowID: UUID? = nil,
    makeWebView: @escaping (WKWebViewConfiguration) -> WKWebView = {
      WKWebView(frame: .zero, configuration: $0)
    }
  ) {
    let tab =
      tab
      ?? TabSession(
        kind: .home, url: SessionState.startURL, defaults: DebugLabConfiguration.defaults)
    self.tabSession = tab
    self.websiteDataStore = websiteDataStore
    self.makeWebView = makeWebView
    self.fixtureNumber = fixtureNumber
    self.enablePinchHarness = enablePinchHarness
    self.bridge = bridge
    self.memoryOwnership = memoryOwnership
    diagnostics = DiagnosticsStore(session: tab.session, strategies: tab.strategies, memory: memory)
    diagnostics.tabID = tab.id
    diagnostics.windowID = windowID
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("Use injected tab dependencies") }
  private(set) lazy var downloads = DownloadHandler(presenter: self)
  var pendingExternalURL: URL?
  var showingNativeLab = false
  var inputObserver: InputObserver?
  let reroute = WebKitGestureReroute()
  let trackpadPinch = TrackpadPinch()
  let multiFingerTap = MultiFingerTap()
  let uiHoldMenu = UIHoldMenu()
  let secondaryClick = SecondaryClick()

  override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
    multiFingerTapEligible && !visibleTextEditing ? .none : .default
  }
  lazy var pinchTransport = PinchTransport { [weak self] script, done in
    guard let self else {
      done()
      return
    }
    self.runScriptWithCompletion(script, done)
  }
  let focusScroll = WebKitFocusScroll()
  #if DEBUG
    var browserCreation = "normal"
    let domProbeStatusID = UUID()
    var domProbeTask: Task<Void, Never>?
    var domProbeAutoCaptured = false
    var domProbeRunning = false
    var domProbeCaptureCount = 0
  #endif
  let inputAssistant = WebKitInputAssistant()
  var showingFocusLab = false
  #if DEBUG
    let focusGeometry = UILabel()
    var pinchHarness: PinchReplayHarness?
  #endif
  var onPencilAction: ((PencilAction) -> Void)?
  let pencilInput = PencilInput()
  var onPhoneLayoutChange: ((Bool) -> Void)?
  /// iPhone layout state posted by the page (sheet and Figma's active tool).
  var onPhoneState: ((PhoneLayoutState) -> Void)?
  /// iPhone: the focused sheet field changed (numeric key row, temporary sheet raise).
  var onPhoneField: ((PhoneFieldState) -> Void)?
  /// iPhone: a panel sheet is open. The web view then keeps its full height under the keyboard,
  /// so WebKit's own focus reveal would pan the whole page; the root scroll view is held still.
  var phoneSheetOpen = false {
    didSet { if oldValue != phoneSheetOpen { applyFocusControls() } }
  }
  /// iPhone: Folio keeps Figma's UI minimized in this tab unless the user expanded it through
  /// Figma. Memory only; seeds each new page of the tab.
  var phoneMinimized = true
  var onNavigationStateChange: (() -> Void)?
  var chromeObservations: [NSKeyValueObservation] = []
  var popup: PopupController?
  var closingPopupForLifecycle = false
  var showingAuthLab = false
  var showingLab = false
  var showingMemoryLab = false
  let memoryBridge = MemoryLabBridge()
  var onShortcutState: ((Int) -> Void)?
  var keyboardObservers: [NSObjectProtocol] = []
  var onSnapshotReady: (() -> Void)?
  var onBackgroundTermination: ((String) -> Void)?
  private(set) var snapshotPending = false
  private(set) var snapshotAttempted = false
  var snapshotView: UIImageView?
  var recoveryBanner: UIStackView?
  var loadFailureView: LoadFailureView?
  var recoveringHome = false

  isolated deinit {
    focusScroll.detach()
    inputAssistant.detach()
    for observer in keyboardObservers { NotificationCenter.default.removeObserver(observer) }
  }
  var webView: WKWebView!
  weak var zoomViewport: InterfaceZoomViewport?
  var urlObservation: NSKeyValueObservation?
  var titleObservation: NSKeyValueObservation?
  var focusOnAppearance = true
  let keyboardFocus = KeyboardFocusRestoration()
  var initialBrowserFocus = InitialBrowserFocus()
  var phoneNavigationLoading = false
  var latestPhoneLayoutState: PhoneLayoutState?
  var initialPageReady = false
  var requestingBrowserFocus = false
  var webGeneration = UUID()
  weak var panel: DeveloperToolsController?
  /// Window settings shown in Developer Tools; set by the browser window.
  var developerDisplay: DeveloperToolsDisplay?
  #if DEBUG
    let diagnosticsButton = BrowserReadinessButton(type: .system)
  #else
    let diagnosticsButton = UIButton(type: .system)
  #endif

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    SignInRules.prepare()
    // Esc on a bundled lab page returns this tab to Figma.
    FolioEscape.register(
      self, when: { [weak self] in self?.diagnostics.activeLab != nil },
      action: { [weak self] in self?.openLab(nil) })
    keyboardObservers.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.releaseTouchShortcuts()
          self?.keyboardFocus.invalidate()
          #if DEBUG
            self?.pinchHarness?.cancel(captureBrowser: false)
          #endif
        }
      })
    keyboardObservers.append(
      NotificationCenter.default.addObserver(
        forName: UIScene.didActivateNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let scene = notification.object as? UIWindowScene else { return }
        MainActor.assumeIsolated {
          guard let self, scene === self.viewIfLoaded?.window?.windowScene
          else { return }
          self.restoreBrowserFocus(reason: .sceneActivated)
        }
      })
    keyboardObservers.append(
      NotificationCenter.default.addObserver(
        forName: InputStrategies.touchModeChanged, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.applyTouchMode() }
      })
    bridge.resizeEdges = { [weak self] body in
      guard let self, self.isTabActive, body == "grab" else { return }
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    bridge.shortcutState = { [weak self] mask in
      guard let self, self.isTabActive else { return }
      self.onShortcutState?(mask)
    }
    downloads.onLog = { [weak self] in self?.diagnostics.lifecycle($0) }
    diagnostics.lifecycle("External keyboard connected=\(GCKeyboard.coalesced != nil)")
    for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
      keyboardObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated {
            self?.diagnostics.lifecycle(
              "External keyboard connected=\(GCKeyboard.coalesced != nil)")
          }
        })
    }
    #if DEBUG
      memoryBridge.persist = { [weak self] progress in
        guard let self, self.isTabActive, self.showingMemoryLab,
          self.memoryOwnership.tabID == self.tabSession.id
        else { throw CocoaError(.fileWriteUnknown) }
        try self.diagnostics.memory.append(
          event: "Memory lab", availableBytes: self.diagnostics.availableMemory, progress: progress)
        self.diagnostics.writeSmokeReportIfRequested()
        self.panel?.refresh()
      }
    #endif
    bridge.receive = { [weak self] message in
      guard let self else { return }
      switch message {
      case .keyboard(let capture): if self.isTabActive { self.diagnostics.record(capture) }
      case .diagnostics(let capture):
        self.diagnostics.environment = capture
        self.diagnostics.writeSmokeReportIfRequested()
        self.panel?.refresh()
      case .input(let input): if self.isTabActive { self.diagnostics.record(input) }
      case .uiDrag(let drag): if self.isTabActive { self.diagnostics.record(drag) }
      case .focus(let focus): if self.isTabActive { self.diagnostics.record(focus) }
      case .focusAssistant:
        guard self.isTabActive, self.session.mode != .safe,
          self.diagnostics.strategies.hardwareKeyboardAssistant,
          EditorFocusPolicy.allows(self.webView.url)
        else { return }
        self.inputAssistant.refresh()
      case .phoneState(let state):
        self.latestPhoneLayoutState = state
        self.phoneMinimized = state.minimize
        self.applyPhoneOverscan(state)
        if self.isTabActive, self.phoneLayoutActive { self.onPhoneState?(state) }
      case .phoneField(let state):
        if self.isTabActive, self.phoneLayoutActive { self.onPhoneField?(state) }
      case .labResults(let results):
        guard self.showingLab else { return }
        self.diagnostics.labResults = results
        self.diagnostics.writeSmokeReportIfRequested()
        self.panel?.refresh()
      }
    }
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--keyboard-logging")
        || ProcessInfo.processInfo.arguments.contains("--browser-readiness")
      {
        diagnosticsButton.readiness = { [weak self] in
          guard let self, let browser = self.webView else { return "browser=unattached" }
          let state = self.browserFocusGuard
          let responder = self.view.window.flatMap { BrowserResponderFocus.first(in: $0) }
          let owner = BrowserResponderFocus.ownership(responder, browser: browser)
          // Public hitTest distinguishes native interception from DOM/AX readiness.
          // Sample browser points only, without reading a network document.
          let hits = [
            CGPoint(x: 80, y: 205), CGPoint(x: browser.bounds.midX, y: browser.bounds.midY),
          ]
          .map { point -> String in
            guard let window = browser.window else { return "unattached" }
            return BrowserResponderFocus.hitOwner(at: point, browser: browser, root: window)
          }.joined(separator: ",")
          let sceneWindows = browser.window?.windowScene?.windows ?? []
          let visibleWindows = sceneWindows.filter { !$0.isHidden && $0.alpha >= 0.01 }
          let enabled = (browser.gestureRecognizers ?? []).filter(\.isEnabled)
          let scrollEnabled = (browser.scrollView.gestureRecognizers ?? []).filter(\.isEnabled)
          let frame = browser.convert(browser.bounds, to: browser.window)
          return
            "creation=\(self.browserCreation) hostSelected=\(self.tabSession.id == (self.parent as? BrowserWindowController)?.session.selectedID) childAttached=\(self.parent != nil) keyWindow=\(browser.window?.isKeyWindow == true) sceneVisibleWindows=\(visibleWindows.count) nativeFrame=\(frame) browserGestures=\(enabled.count) scrollGestures=\(scrollEnabled.count) externalKeyboard=\(GCKeyboard.coalesced != nil) sceneActive=\(state.foreground) attached=\(state.attached) pageReady=\(self.initialPageReady) initialPending=\(self.initialBrowserFocus.pending) responder=\(owner.rawValue) nativeSampleHits=\(hits) \(BrowserResponderFocus.visibility(of: browser)) geometryReady=\(state.geometryReady) rootOffset=\(browser.scrollView.contentOffset) rootZoom=\(browser.scrollView.zoomScale) downloadOwnership=[\(self.downloads.presentationState)] routeEvidence=\(self.routeEvidence.suffix(8).joined(separator: ";"))"
        }
      }
    #endif
    // Developer Tools open from the ⋯ menu (⌥⌘I). The button stays as an invisible layer
    // anchor, and as the readiness probe for DEBUG UI test runs.
    diagnosticsButton.isHidden = true
    #if DEBUG
      diagnosticsButton.isHidden =
        !ProcessInfo.processInfo.arguments.contains("--keyboard-logging")
        && !ProcessInfo.processInfo.arguments.contains("--browser-readiness")
    #endif
    diagnosticsButton.setTitle("D", for: .normal)
    diagnosticsButton.accessibilityLabel = "Open developer tools"
    diagnosticsButton.backgroundColor = .secondarySystemBackground
    diagnosticsButton.layer.cornerRadius = 16
    diagnosticsButton.translatesAutoresizingMaskIntoConstraints = false
    diagnosticsButton.addAction(
      UIAction { [weak self] _ in self?.toggleDeveloperTools() }, for: .touchUpInside)
    view.addSubview(diagnosticsButton)
    NSLayoutConstraint.activate([
      diagnosticsButton.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      diagnosticsButton.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      diagnosticsButton.widthAnchor.constraint(equalToConstant: 32),
      diagnosticsButton.heightAnchor.constraint(equalToConstant: 32),
    ])
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--keyboard-logging") {
        diagnostics.inputLogging = true
      }
      if ProcessInfo.processInfo.arguments.contains("--keyboard-all-off") {
        session.mode = .normal
        diagnostics.strategies.resetFocusSwitches()
        diagnostics.strategies.pencil = .none
        diagnostics.strategies.finger = .baseline
        diagnostics.strategies.trackpadPinchZoom = false
        diagnostics.strategies.fingerCanvasWheel = false
        diagnostics.strategies.uaButtonColor = false
      }
      if ProcessInfo.processInfo.arguments.contains("--tab-route-evidence") {
        diagnostics.inputLogging = true
      }
      showingNativeLab = ProcessInfo.processInfo.arguments.contains("--native-lab")
      if showingNativeLab { session.mode = .normal }
      showingAuthLab = ProcessInfo.processInfo.arguments.contains("--auth-lab")
      showingLab = ProcessInfo.processInfo.arguments.contains("--input-lab")
      showingFocusLab = ProcessInfo.processInfo.arguments.contains("--focus-lab")
      if showingFocusLab {
        session.mode = .normal
        diagnostics.strategies.editorScrollLock = ProcessInfo.processInfo.arguments.contains(
          "--focus-lock")
        diagnostics.strategies.focusViewportLimit = ProcessInfo.processInfo.arguments.contains(
          "--focus-viewport")
        diagnostics.inputLogging = ProcessInfo.processInfo.arguments.contains("--focus-logging")
      }
      showingMemoryLab = ProcessInfo.processInfo.arguments.contains("--memory-lab")
      if showingMemoryLab {
        session.mode = .normal
        showingLab = false
      }
    #endif
    pencilInput.onLog = { [weak self] message in
      guard let self, self.diagnostics.inputLogging else { return }
      self.diagnostics.log(message)
    }
    pencilInput.onAction = { [weak self] squeeze in self?.performPencilAction(squeeze: squeeze) }
    focusScroll.onLog = { [weak self] message in
      guard let self, self.diagnostics.inputLogging else { return }
      self.diagnostics.log(message)
    }
    focusScroll.onKeyboard = { [weak self] in self?.inputAssistant.refresh() }
    focusScroll.onGeometry = { [weak self] in self?.updateFocusGeometry() }
    #if DEBUG
      if showingFocusLab {
        focusGeometry.accessibilityIdentifier = "focusGeometry"
        focusGeometry.numberOfLines = 0
        focusGeometry.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        focusGeometry.frame = CGRect(x: 20, y: 170, width: 650, height: 80)
        view.addSubview(focusGeometry)
      }
    #endif
    if pendingExternalURL != nil {
      showingNativeLab = false
      showingAuthLab = false
      showingLab = false
      showingMemoryLab = false
      showingFocusLab = false
    }
    tabSession.discarded = false
    rebuildWebView()
    // A discarded controller already loads a fresh WebView above.
    tabSession.stoppedInBackground = false
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--diagnostics") {
        DispatchQueue.main.async { [weak self] in self?.toggleDeveloperTools() }
      }
    #endif
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    diagnostics.screen = view.window?.windowScene?.screen
    #if DEBUG
      scheduleDOMProbe()
    #endif
    downloads.setActive(isTabActive)
    if initialBrowserFocus.pending || focusOnAppearance {
      restoreBrowserFocus(reason: .viewAppeared)
    }
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    zoomViewport?.setNeedsLayout()
    // Attachment/appearance can precede nonzero WebKit geometry. Retain H1's
    // initial request until layout, without requesting optional chrome focus.
    if !requestingBrowserFocus && initialBrowserFocus.pending && initialPageReady {
      restoreBrowserFocus(reason: .layoutReady)
    }
  }

  func setTabActive(_ active: Bool, restoreFocus: Bool = true) {
    if active, dashboardReload != nil {
      recordWindowEvidence("reloadAfterHandoff=cancelled reason=tabSelected")
      dashboardReload = nil
    }
    focusOnAppearance = restoreFocus
    keyboardFocus.invalidate()
    if active && !isTabActive { initialBrowserFocus.begin() }
    if !active {
      releaseTouchShortcuts()
      initialBrowserFocus.cancel()
    }
    isTabActive = active
    updateScriptWindowPermission()
    #if DEBUG
      if !active {
        domProbeTask?.cancel()
        domProbeTask = nil
      } else {
        scheduleDOMProbe()
      }
    #endif
    downloads.setActive(active)
    guard isViewLoaded, webView != nil else { return }
    if active {
      if tabSession.stoppedInBackground {
        tabSession.stoppedInBackground = false
        if tabSession.kind == .home && !tabSession.backgroundRecoveryAllowed {
          showRecoveryBanner(reloaded: false)
        } else {
          recoveryBanner?.removeFromSuperview()
          recoveringHome = tabSession.kind == .home
          diagnostics.lifecycle("Background tab selected; silent reload requested")
          loadCurrentPage()
        }
      }
      if session.mode != .safe && !scriptFreeRelated { pencilInput.attach(to: webView) }
      applyStrategies()
      applyLogging()
      if restoreFocus { restoreBrowserFocus(reason: .tabSelected) }
    } else {
      panel?.dismiss(animated: false)
      view.endEditing(true)
      runScript(
        "globalThis.__folio?.setCanvasWheel?.(false); globalThis.__folio?.setPencilStrategy?.('none', false); void 0"
      )
      reroute.restore()
      pencilInput.detach()
      #if DEBUG
        pinchHarness?.cancel(captureBrowser: false)
      #endif
      trackpadPinch.detach()
      multiFingerTap.detach()
      uiHoldMenu.detach()
      secondaryClick.detach()
      pinchTransport.reset()
      runScript("globalThis.__folio?.resetTrackpadPinch?.(); void 0")
      runScript("globalThis.__folio?.setFocusRevealGuard?.(false); void 0")
      focusScroll.setLocked(false)
      inputAssistant.setEnabled(false)
      applyLogging()
      diagnostics.labResults = [:]
      interruptMemoryRun()
      if memoryOwnership.tabID == tabSession.id { memoryOwnership.tabID = nil }
      runScript("globalThis.__folio?.disposeMemoryLab?.(); void 0")
    }
  }

  override func present(
    _ viewControllerToPresent: UIViewController, animated flag: Bool,
    completion: (() -> Void)? = nil
  ) {
    keyboardFocus.invalidate()
    #if DEBUG
      pinchHarness?.cancel(captureBrowser: false)
    #endif
    super.present(viewControllerToPresent, animated: flag, completion: completion)
    recordKeyboardProbe(phase: "native-presentation-opened")
  }

  func invalidateBrowserFocus() { keyboardFocus.invalidate() }

  var browserFocusGuard: BrowserFocusGuard {
    let attachedWindow = viewIfLoaded?.window
    let window = attachedWindow ?? parent?.viewIfLoaded?.window
    let selected =
      (parent as? BrowserWindowController).map { $0.session.selectedID == tabSession.id } ?? true
    let presentation =
      presentedViewController != nil || parent?.presentedViewController != nil
      || isBeingDismissed || parent?.isBeingDismissed == true || panel != nil
    return BrowserFocusGuard(
      active: isTabActive && selected,
      foreground: window?.windowScene?.activationState == .foregroundActive,
      attached: attachedWindow != nil && webView?.window === attachedWindow
        && webView?.isDescendant(of: view) == true,
      popup: popup != nil, presentation: presentation,
      geometryReady: webView?.bounds.isEmpty == false)
  }

  func restoreBrowserFocus(reason: BrowserFocusReason) {
    guard !requestingBrowserFocus, isViewLoaded, let browser = webView else { return }
    requestingBrowserFocus = true
    defer { requestingBrowserFocus = false }
    recordKeyboardProbe(phase: "restore-request-\(reason.rawValue)")
    if initialBrowserFocus.pending {
      guard initialPageReady else { return }
      let state = browserFocusGuard
      initialBrowserFocus.request(guard: state) { [weak self] in
        self?.focusBrowserIfNeeded(browser, reason: reason) ?? false
      }
      return
    }
    // Scene/page callbacks retry initial focus only, never the optional chrome candidate.
    guard reason != .sceneActivated, reason != .pageReady, reason != .navigationFinished,
      reason != .layoutReady
    else {
      return
    }
    let generation = webGeneration
    let tabID = tabSession.id
    let window = view.window ?? parent?.viewIfLoaded?.window
    keyboardFocus.request(
      enabled: session.mode != .safe && diagnostics.strategies.browserFocusRestoration,
      guard: browserFocusGuard,
      focus: { [weak self] in
        _ = self?.focusBrowserIfNeeded(browser, reason: reason)
      }, enqueue: { work in DispatchQueue.main.async { work() } },
      retry: { [weak self, weak window] in
        guard let self, let window, self.tabSession.id == tabID,
          self.webGeneration == generation, self.webView === browser,
          self.view.window === window, self.browserFocusGuard.eligible,
          self.session.mode != .safe, self.diagnostics.strategies.browserFocusRestoration
        else { return }
        _ = self.focusBrowserIfNeeded(browser, reason: reason)
      })
  }

  func focusBrowserIfNeeded(_ browser: WKWebView, reason: BrowserFocusReason) -> Bool {
    // WEBKIT_INTERNAL: observe public containment, preserving WebKit's focused content view.
    // Never replace a content responder or alter the page's DOM focus/keyboard sink.
    let responder = view.window.flatMap { WebKitResponderObservation.first(in: $0) }
    if let responder, responder !== browser, responder.isDescendant(of: browser) {
      recordKeyboardProbe(phase: "preserved-\(reason.rawValue)")
      return true
    }
    if responder is UITextField || responder is UITextView { return false }
    let result = browser.becomeFirstResponder()
    recordKeyboardProbe(phase: reason.rawValue, focusResult: result, actions: true)
    runScript("globalThis.__folio?.captureKeyboardFocus?.(); void 0")
    return result
  }

  func recordKeyboardProbe(phase: String, focusResult: Bool? = nil, actions: Bool = false) {
    guard isTabActive, diagnostics.inputLogging, browserFocusGuard.active else { return }
    let responder = view.window.flatMap { WebKitResponderObservation.first(in: $0) }
    let owner = WebKitResponderObservation.category(responder, main: webView, popup: popup?.browser)
    let state = browserFocusGuard
    diagnostics.log(
      "Native keyboard \(phase) tab=\(tabSession.id) window=\(diagnostics.windowID?.uuidString ?? "standalone") generation=\(webGeneration) sceneActive=\(state.foreground) attached=\(state.attached) modal=\(state.presentation) popup=\(state.popup) owner=\(owner.rawValue) contentResponder=\(BrowserResponderFocus.ownership(responder, browser: webView).rawValue) externalKeyboard=\(GCKeyboard.coalesced != nil) keyboardFrames=\(focusScroll.keyboardFrames) browserSize=\(webView.bounds.size) rootOffset=\(webView.scrollView.contentOffset) rootZoom=\(webView.scrollView.zoomScale) focusResult=\(focusResult.map(String.init) ?? "not-requested")"
    )
    if actions {
      for action in ["undo:", "redo:"] {
        let target =
          responder?.target(forAction: NSSelectorFromString(action), withSender: nil)
          as? UIResponder
        let category = WebKitResponderObservation.category(
          target, main: webView, popup: popup?.browser)
        diagnostics.log(
          "Native action probe \(action) target=\(category.rawValue) canUndo=\(responder?.undoManager.map { String($0.canUndo) } ?? "unknown") canRedo=\(responder?.undoManager.map { String($0.canRedo) } ?? "unknown"); queried, not executed"
        )
      }
    }
  }

  func observeKeyboard(_ presses: Set<UIPress>, phase: String) {
    guard isTabActive, diagnostics.inputLogging else { return }
    for press in presses {
      guard let key = press.key, key.modifierFlags.contains(.command),
        !key.modifierFlags.contains(.alternate), !key.modifierFlags.contains(.control)
      else { continue }
      let shift = key.modifierFlags.contains(.shift)
      let chord: String
      switch key.charactersIgnoringModifiers.lowercased() {
      case "z": chord = shift ? "Cmd+Shift+Z" : "Cmd+Z"
      case "y" where !shift: chord = "Cmd+Y"
      default: continue
      }
      recordKeyboardProbe(phase: "\(phase) \(chord) meta=true shift=\(shift) alt=false ctrl=false")
    }
  }
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    observeKeyboard(presses, phase: "down")
    super.pressesBegan(presses, with: event)
  }
  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    observeKeyboard(presses, phase: "up")
    super.pressesEnded(presses, with: event)
  }

  func captureTabSnapshot() {
    snapshotAttempted = true
    // WebKit can retain a detached view indefinitely waiting for snapshot display.
    // Departure capture runs before removal; unattached/evicted views need no image.
    guard tabSession.kind == .document, let browser = webView,
      browser.window != nil, !browser.bounds.isEmpty, popup == nil,
      let url = browser.url, Self.isFileRoute(url)
    else { return }
    snapshotPending = true
    let configuration = WKSnapshotConfiguration()
    configuration.snapshotWidth = 512
    let generation = webGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, self.webGeneration == generation, self.snapshotPending else { return }
      self.snapshotPending = false
      self.onSnapshotReady?()
    }
    browser.takeSnapshot(with: configuration) { [weak self] image, _ in
      guard let self, self.webGeneration == generation else { return }
      self.snapshotPending = false
      if let image { self.tabSession.snapshot = image }
      self.onSnapshotReady?()
    }
  }

  func closeTab() {
    downloads.close()
    closePopup()
    setTabActive(false)
    guard isViewLoaded, webView != nil else { return }
    #if DEBUG
      pinchHarness?.uninstall()
      pinchHarness = nil
    #endif
    runScript("globalThis.__folio?.dispose?.(); void 0")
    focusScroll.detach()
    inputAssistant.detach()
    urlObservation?.invalidate()
    titleObservation?.invalidate()
    chromeObservations.removeAll()
    webGeneration = UUID()
    tabSession.displayTitle = nil
    webView.stopLoading()
    webView.configuration.userContentController.removeAllScriptMessageHandlers()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    bridge.visibleTextEditing = false
    bridge.domEditorFocused = true
    bridge.webView = nil
    memoryBridge.webView = nil
    pencilInput.detach()
    trackpadPinch.detach()
    multiFingerTap.detach()
    uiHoldMenu.detach()
    secondaryClick.detach()
    pinchTransport.reset()
    inputObserver = nil
    if let viewport = webView.superview as? InterfaceZoomViewport { viewport.removeFromSuperview() }
    webView.removeFromSuperview()
    webView = nil
  }

  override var keyCommands: [UIKeyCommand]? {
    let safe = UIKeyCommand(
      title: "Folio Safe mode", action: #selector(requestSafeMode), input: "s",
      modifierFlags: [.command, .alternate, .shift])
    for command in [safe] {
      command.wantsPriorityOverSystemBehavior = false
      command.discoverabilityTitle = command.title
    }
    return [safe]
  }

  @objc func requestSafeMode() {
    guard presentedViewController == nil else { return }
    let alert = UIAlertController(
      title: "Reload in Safe mode?", message: "Unsynced edits may be lost when the page reloads.",
      preferredStyle: .alert)
    alert.addAction(
      UIAlertAction(title: "Cancel", style: .cancel) { [weak self, weak alert] _ in
        afterAlertDismissal(alert) { [weak self] in
          self?.restoreBrowserFocus(reason: .nativeAlertDismissed)
        }
      })
    alert.addAction(
      UIAlertAction(title: "Reload", style: .default) { [weak self] _ in
        guard let self else { return }
        self.interruptMemoryRun()
        self.session.mode = .safe
        self.rebuildWebView()
      })
    present(alert, animated: true)
  }
}
