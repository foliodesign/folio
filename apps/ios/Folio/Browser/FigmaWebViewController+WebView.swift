import UIKit
import WebKit

@MainActor
extension FigmaWebViewController {
  func rebuildWebView() {
    dashboardReload = nil
    onPhoneLayoutChange?(false)
    downloads.setActive(false)
    keyboardFocus.invalidate()
    webGeneration = UUID()
    bridge.domEditorFocused = true
    initialPageReady = false
    initialBrowserFocus.begin()
    closePopup()
    if session.mode == .safe {
      showingNativeLab = false
      showingAuthLab = false
      showingLab = false
      showingMemoryLab = false
      showingFocusLab = false
      diagnostics.activeLab = nil
      #if DEBUG
        focusGeometry.removeFromSuperview()
      #endif
    }
    interruptMemoryRun()
    diagnostics.labResults = [:]
    reroute.restore()
    pencilInput.detach()
    #if DEBUG
      pinchHarness?.uninstall()
      pinchHarness = nil
    #endif
    trackpadPinch.detach()
    multiFingerTap.detach()
    uiHoldMenu.detach()
    secondaryClick.detach()
    pinchTransport.reset()
    focusScroll.detach()
    inputAssistant.detach()
    urlObservation?.invalidate()
    titleObservation?.invalidate()
    chromeObservations.removeAll()
    if let old = webView {
      old.stopLoading()
      old.configuration.userContentController.removeAllScriptMessageHandlers()
      old.navigationDelegate = nil
      old.uiDelegate = nil
      if let viewport = old.superview as? InterfaceZoomViewport {
        viewport.removeFromSuperview()
      }
      old.removeFromSuperview()
    }
    diagnostics.environment = nil
    diagnostics.isInputLab = showingLab
    let supplied = relatedConfiguration
    relatedConfiguration = nil
    relatedInitialNavigation = supplied != nil
    let normal = WebViewConfiguration.make(
      mode: session.mode, bridge: bridge, memoryBridge: memoryBridge,
      uaButtonColor: diagnostics.strategies.uaButtonColor,
      hideGoogle: diagnostics.strategies.hideGoogle,
      phoneLayout: phoneLayoutActive, phoneMinimize: phoneMinimized,
      phoneWide: phoneWideViewport, phoneNumbers: phoneNumberKeyboard, phoneSides: phoneSides,
      focusRevealGuard: diagnostics.strategies.focusRevealGuard,
      focusViewportLimit: diagnostics.strategies.focusViewportLimit,
      hardwareKeyboardAssistant: diagnostics.strategies.hardwareKeyboardAssistant,
      websiteDataStore: websiteDataStore,
      touchGestures: diagnostics.strategies.touchGestures, home: tabSession.kind == .home,
      fingerCanvasWheel: diagnostics.strategies.fingerCanvasWheel,
      trackpadZoom: diagnostics.strategies.trackpadPinchZoom,
      resizeHelper: diagnostics.strategies.resizeHelper,
      touchMode: diagnostics.strategies.touchMode)
    if session.mode != .safe, onRoute != nil {
      normal.userContentController.add(
        standardLinks, contentWorld: ScriptBridge.world, name: StandardFileLinkHandler.name)
      normal.userContentController.addUserScript(
        WKUserScript(
          source: StandardFileLinkHandler.script, injectionTime: .atDocumentStart,
          forMainFrameOnly: true, in: ScriptBridge.world))
    }
    // Keep WebKit's related configuration/store; replace only its inherited script controller.
    // Auth overlays continue through PopupController with an empty script controller.
    supplied?.userContentController = normal.userContentController
    // Each main browser owns its preferences; a related child must not mutate its opener's.
    supplied?.preferences = normal.preferences
    let adopted = pendingRelatedBrowser
    pendingRelatedBrowser = nil
    scriptFreeRelated = adopted != nil
    let browser = adopted ?? makeWebView(supplied ?? normal)
    #if DEBUG
      browserCreation = adopted != nil ? "adopted" : supplied != nil ? "supplied" : "normal"
    #endif
    #if DEBUG
      browser.isInspectable = true
      if LocalFontService.shared.chromeUserAgentProbe {
        browser.customUserAgent = LocalFontService.chromeProbeUserAgent
      }
    #endif
    browser.accessibilityIdentifier = "browser-\(tabSession.id)"
    browser.navigationDelegate = self
    browser.uiDelegate = self
    let viewport = InterfaceZoomViewport(browser: browser)
    zoomViewport = viewport
    viewport.beginLoading()
    viewport.translatesAutoresizingMaskIntoConstraints = false
    view.insertSubview(viewport, belowSubview: diagnosticsButton)
    NSLayoutConstraint.activate([
      viewport.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      viewport.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      viewport.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      viewport.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    let observer = InputObserver { [weak self] touch, view in
      guard let self else { return }
      if touch.type == .pencil, touch.phase == .began,
        self.diagnostics.strategies.observePencilTouch()
      {
        self.diagnostics.log("First Pencil touch: default touch mode is Pencil & Touch [Tier 1]")
      }
      guard self.diagnostics.inputLogging else { return }
      let type: String
      switch touch.type {
      case .direct: type = "direct"
      case .pencil: type = "pencil"
      case .indirectPointer: type = "indirectPointer"
      default: type = "other"
      }
      let location = touch.location(in: view)
      let pencil =
        touch.type == .pencil
        ? " altitude=\(touch.altitudeAngle) azimuth=\(touch.azimuthAngle(in: view))" : ""
      self.diagnostics.log(
        "Native type=\(type) phase=\(touch.phase.rawValue) force=\(touch.force) xy=\(location.x),\(location.y)\(pencil)"
      )
    }
    observer.isEnabled = true
    browser.addGestureRecognizer(observer)
    inputObserver = observer
    webView = browser
    updateScriptWindowPermission()
    focusScroll.attach(to: browser.scrollView)
    focusScroll.logging = isTabActive && diagnostics.inputLogging
    inputAssistant.attach(to: browser)
    bridge.webView = browser
    memoryBridge.webView = browser
    if session.mode != .safe && !scriptFreeRelated { pencilInput.attach(to: browser) }
    let generation = webGeneration
    titleObservation = browser.observe(\.title, options: [.initial, .new]) {
      [weak self] browser, _ in
      Task { @MainActor [weak self, weak browser] in
        guard let self, let browser, browser === self.webView,
          self.webGeneration == generation
        else { return }
        if let title = TabSession.documentTitle(browser.title) {
          self.tabSession.displayTitle = title
          self.onTitleChange?()
        }
      }
    }
    chromeObservations = [\WKWebView.canGoBack, \WKWebView.canGoForward, \WKWebView.isLoading].map {
      key in
      browser.observe(key, options: [.new]) { [weak self, weak browser] _, _ in
        Task { @MainActor in
          guard let self, let browser, browser === self.webView,
            self.webGeneration == generation
          else { return }
          self.onNavigationStateChange?()
        }
      }
    }
    urlObservation = browser.observe(\.url, options: [.new]) { [weak self] browser, change in
      let observedURL = change.newValue ?? nil
      Task { @MainActor [weak self, weak browser] in
        guard let self, let browser, browser === self.webView,
          browser.url == observedURL
        else { return }
        #if DEBUG
          self.pinchHarness?.cancel(captureBrowser: false)
        #endif
        self.updateScriptWindowPermission()
        if let observedURL, self.observeDashboardReload(observedURL) { return }
        if let observedURL, self.handoffObservedURL(observedURL) { return }
        self.persistNavigation(browser)
        self.applyFocusControls()
        self.applyPhoneLayout()
        #if DEBUG
          self.scheduleDOMProbe()
        #endif
      }
    }
    #if DEBUG
      if enablePinchHarness || ProcessInfo.processInfo.arguments.contains("--pinch-harness") {
        let generation = webGeneration
        let harness = PinchReplayHarness(
          webView: browser, trackpad: trackpadPinch, transport: pinchTransport,
          allowed: { [weak self, weak browser] in
            guard let self, let browser else { return false }
            return self.webGeneration == generation && self.webView === browser
              && self.isTabActive && self.session.mode != .safe && !self.scriptFreeRelated
              && self.popup == nil
              && browser.window?.windowScene?.activationState == .foregroundActive
              && self.presentedViewController == nil
              && self.diagnostics.strategies.trackpadPinchZoom
              && EditorFocusPolicy.allows(browser.url)
          })
        pinchHarness = harness
        harness.install(in: view)
      }
    #endif
    diagnostics.currentURL = session.lastURL
    if supplied == nil && adopted == nil { loadCurrentPage() }
    if isTabActive { applyStrategies() }
    downloads.setActive(isTabActive)
  }

  var visibleTextEditing: Bool {
    session.mode == .safe || scriptFreeRelated || bridge.visibleTextEditing
  }

  @objc func toggleDeveloperTools() { showPreferences(settings: false) }

  func showPreferences(settings: Bool, controls: FolioSettingsDisplay? = nil) {
    if let panel {
      panel.dismiss(animated: true)
      return
    }
    keyboardFocus.invalidate()
    // Preserve the exact content responder across this explicit native command.
    guard let browser = webView else { return }
    weak var previousResponder = view.window.flatMap { BrowserResponderFocus.first(in: $0) }
    let panel = DeveloperToolsController(store: diagnostics, settings: settings)
    panel.settingsDisplay = controls
    panel.display = developerDisplay
    #if DEBUG
      panel.onLoopbackProbe = { [weak browser] in
        // Folio's isolated world shares the page's origin and mixed-content policy; Figma is untouched.
        browser?.callAsyncJavaScript(
          "const out = []; for (const h of hosts) { try { const r = await fetch('http://' + h"
            + " + ':' + port + '/figma/version', { cache: 'no-store' }); out.push(h + ' HTTP '"
            + " + r.status) } catch (e) { out.push(h + ' failed (' + e.name + ')') } }"
            + " return out.join(', ')",
          arguments: [
            "hosts": ["127.0.0.1", "localhost", "[::1]"], "port": Int(LocalFontService.port),
          ], in: nil,
          in: ScriptBridge.world
        ) { result in
          let outcome =
            switch result {
            case .success(let value): value as? String ?? "no result"
            case .failure: "script error"
            }
          let origin = browser?.url?.host ?? "no page"
          LocalFontService.shared.note("Page probe from \(origin): \(outcome)")
        }
      }
    #endif
    panel.labAvailable = { lab in
      switch lab {
      case .input: ScriptBridge.labURL != nil
      case .memory: MemoryLabBridge.url != nil
      case .auth: Self.authLabURL != nil
      case .native: Self.nativeLabURL != nil
      case .focus: ScriptBridge.focusLabURL != nil
      }
    }
    panel.onDismiss = { [weak self, weak panel] in
      guard let self, self.panel === panel else { return }
      self.panel = nil
      if self.webView === browser, self.browserFocusGuard.eligible {
        if let previousResponder, previousResponder.isDescendant(of: browser) {
          if !previousResponder.isFirstResponder { _ = previousResponder.becomeFirstResponder() }
        } else {
          _ = BrowserResponderFocus.restore(browser, in: self.view)
        }
      } else {
        self.restoreBrowserFocus(reason: .diagnosticsDismissed)
      }
    }
    panel.onMode = { [weak self] mode in
      guard let self else { return }
      self.diagnostics.labResults = [:]
      self.interruptMemoryRun()
      self.session.mode = mode
      self.diagnostics.lifecycle("Mode changed to \(mode.rawValue); rebuilding browser")
      self.rebuildWebView()
    }
    panel.onLogging = { [weak self] enabled in
      guard let self else { return }
      self.diagnostics.inputLogging = enabled
      self.applyLogging()
    }
    panel.onUIDragOptions = { [weak self] in self?.applyLogging() }
    panel.onLab = { [weak self, weak panel] lab in
      self?.openLab(lab)
      panel?.dismiss(animated: true)
    }
    panel.onStrategy = { [weak self] in
      self?.diagnostics.labResults = [:]
      self?.applyStrategies()
    }
    #if DEBUG
      panel.onDOMProbe = { [weak self, weak panel] in
        panel?.dismiss(animated: true) { [weak self] in self?.captureDOMProbe() }
      }
    #endif
    panel.onRefresh = { [weak self] in self?.captureEnvironment() }
    panel.modalPresentationStyle = .formSheet
    panel.preferredContentSize = CGSize(width: 880, height: 720)
    self.panel = panel
    panel.presentationController?.delegate = panel
    present(panel, animated: true) { [weak panel] in
      panel?.presentationController?.delegate = panel
    }
    if !settings { captureEnvironment() }
  }

  /// Replaces this tab's page with a bundled lab, or returns to Figma for `nil`.
  func openLab(_ lab: DeveloperLab?) {
    interruptMemoryRun()
    showingNativeLab = lab == .native
    showingAuthLab = lab == .auth
    showingFocusLab = lab == .focus
    showingLab = lab == .input
    showingMemoryLab = lab == .memory
    diagnostics.activeLab = lab
    diagnostics.labResults = [:]
    diagnostics.isInputLab = showingLab
    if lab == .input || lab == nil {
      loadCurrentPage()
    } else {
      rebuildWebView()
    }
  }

  func loadCurrentPage() {
    initialPageReady = false
    initialBrowserFocus.begin()
    keyboardFocus.invalidate()
    closePopup()
    diagnostics.labResults = [:]
    diagnostics.environment = nil
    diagnostics.isMemoryLab = showingMemoryLab
    if showingMemoryLab { memoryOwnership.tabID = tabSession.id }
    diagnostics.isInputLab = showingLab
    #if DEBUG
      if let fixtureNumber, pendingExternalURL == nil {
        TabFixture.load(
          in: webView, number: fixtureNumber,
          url: tabSession.kind == .home
            ? tabSession.lastDashboardURL ?? SessionState.startURL
            : tabSession.routingURL ?? session.lastURL)
        return
      }
    #endif
    if showingNativeLab, let url = Self.nativeLabURL {
      webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else if showingFocusLab, let url = ScriptBridge.focusLabURL {
      webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else if showingAuthLab, let url = Self.authLabURL {
      webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else if showingMemoryLab, let url = MemoryLabBridge.url {
      webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else if showingLab, let url = ScriptBridge.labURL {
      webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else {
      let url =
        pendingExternalURL
        ?? (tabSession.kind == .home
          ? tabSession.lastDashboardURL ?? SessionState.startURL
          : tabSession.routingURL ?? session.lastURL)
      pendingExternalURL = nil
      webView.load(URLRequest(url: url))
    }
  }
  func performPencilAction(squeeze: Bool) {
    guard browserFocusGuard.eligible, session.mode != .safe, !scriptFreeRelated,
      let window = view.window, FolioEscape.action(in: window) == nil,
      tabSession.kind == .document, let url = webView?.url, Self.isFileRoute(url)
    else { return }
    let action = FolioPreferences().pencilBinding(squeeze: squeeze)
    if action == .systemSetting {
      let preferred =
        squeeze
        ? UIPencilInteraction.preferredSqueezeAction : UIPencilInteraction.preferredTapAction
      // Figma exposes no standard shortcut for eraser/previous tool/ink palettes.
      // Ignore and system shortcuts belong to iPadOS; never substitute a custom edit.
      switch preferred {
      case .ignore, .runSystemShortcut, .switchEraser, .switchPrevious,
        .showColorPalette, .showInkAttributes, .showContextualPalette:
        return
      @unknown default: return
      }
    }
    guard action != .none, let onPencilAction else { return }
    if diagnostics.inputLogging {
      diagnostics.log(
        "Pencil \(squeeze ? "squeeze" : "double-tap") action=\(action.rawValue) [Tier 1]")
    }
    onPencilAction(action)
  }

  var multiFingerTapEligible: Bool {
    browserFocusGuard.eligible && session.mode != .safe && !scriptFreeRelated
      && diagnostics.strategies.multiFingerTap && tabSession.kind == .document
      && webView?.url.map(Self.isFileRoute) == true && !visibleTextEditing
  }

  func configureMultiFingerTap() {
    guard session.mode != .safe, !scriptFreeRelated, diagnostics.strategies.multiFingerTap,
      tabSession.kind == .document, let browser = webView
    else {
      multiFingerTap.detach()
      return
    }
    multiFingerTap.log = { [weak self] message in
      guard let self, self.diagnostics.inputLogging else { return }
      self.diagnostics.log("Multi-finger \(message)")
    }
    multiFingerTap.eligible = { [weak self] in
      guard let self else { return false }
      let eligible = self.multiFingerTapEligible
      if !eligible {
        self.multiFingerTap.log?(
          "native-gate focus=\(self.browserFocusGuard.eligible) safe=\(self.session.mode == .safe) child=\(self.scriptFreeRelated) enabled=\(self.diagnostics.strategies.multiFingerTap) document=\(self.tabSession.kind == .document) file=\(self.webView?.url.map(Self.isFileRoute) == true) editor=\(self.visibleTextEditing)"
        )
      }
      return eligible
    }
    multiFingerTap.validate = { [weak self, weak browser] points, ending, done in
      guard let self, let browser, self.multiFingerTapEligible,
        browser.bounds.width > 0, browser.bounds.height > 0
      else {
        self?.multiFingerTap.log?("gate=native-ineligible")
        done(false)
        return
      }
      let generation = self.webGeneration
      let url = browser.url
      let coordinates = points.map { point -> [Double] in
        let local = browser.convert(point, from: self.multiFingerTap.host ?? browser)
        return [Double(local.x / browser.bounds.width), Double(local.y / browser.bounds.height)]
      }
      guard let data = try? JSONEncoder().encode(coordinates),
        let json = String(data: data, encoding: .utf8)
      else {
        done(false)
        return
      }
      // Shared canvas/container hit testing with canvas-wheel.ts. No Figma selectors.
      let script = """
        (() => {
          if (\(ending) && globalThis.__folio?.canvasGestureDidMove?.()) return "pan-pinch";
          const e = document.activeElement;
          if (e instanceof HTMLElement && (e.isContentEditable ||
              e instanceof HTMLInputElement || e instanceof HTMLTextAreaElement)) {
            const r = e.getBoundingClientRect();
            if (r.width > 1 && r.height > 1 && r.right > 0 && r.bottom > 0 &&
                r.left < innerWidth && r.top < innerHeight &&
                e.checkVisibility({opacityProperty:true,visibilityProperty:true})) return "editor";
          }
          return \(json).length > 0 && \(json).every(([x,y]) =>
            globalThis.__folio?.isCanvasPoint?.(x * innerWidth,y * innerHeight) === true)
            ? "canvas" : "off-canvas";
        })()
        """
      browser.evaluateJavaScript(script, in: nil, in: ScriptBridge.world) {
        [weak self, weak browser] result in
        guard let self, let browser, browser === self.webView,
          generation == self.webGeneration, browser.url == url, self.multiFingerTapEligible
        else {
          done(false)
          return
        }
        let gate: String
        if case .success(let value) = result, let reason = value as? String,
          ["canvas", "off-canvas", "editor", "pan-pinch"].contains(reason)
        {
          gate = reason
        } else {
          gate = "script-error"
        }
        self.multiFingerTap.log?("gate=\(gate) points=\(points.count)")
        done(gate == "canvas")
      }
    }
    multiFingerTap.onTap = { [weak self] redo in
      self?.touchShortcutKey(redo ? "redo" : "undo")
    }
    // Outside the web view, so WebKit's touch-deferral recognizers cannot fail the taps.
    multiFingerTap.attach(to: browser.superview ?? browser)
  }

  /// Stationary finger/Pencil release in Figma UI adds a contextmenu (touch-gestures.ts decides).
  func configureUIHoldMenu() {
    guard session.mode != .safe, !scriptFreeRelated, diagnostics.strategies.touchGestures,
      let browser = webView
    else {
      uiHoldMenu.detach()
      return
    }
    uiHoldMenu.log = { [weak self] message in
      guard let self, self.diagnostics.inputLogging else { return }
      self.diagnostics.log("UI hold menu \(message)")
    }
    uiHoldMenu.eligible = { [weak self] in
      guard let self else { return false }
      return self.isTabActive && self.session.mode != .safe && !self.scriptFreeRelated
        && self.diagnostics.strategies.touchGestures && !self.visibleTextEditing
    }
    uiHoldMenu.onPhase = { [weak self, weak browser] phase, point in
      guard let self, let browser, browser === self.webView,
        browser.bounds.width > 0, browser.bounds.height > 0
      else { return }
      let local = browser.convert(point, from: self.uiHoldMenu.host ?? browser)
      let x = Double(local.x / browser.bounds.width)
      let y = Double(local.y / browser.bounds.height)
      guard x.isFinite, y.isFinite else { return }
      let script =
        "globalThis.__folio?.touchUIHold?.('\(phase.rawValue)', \(x) * innerWidth, \(y) * innerHeight) ?? 'no-script'"
      browser.evaluateJavaScript(script, in: nil, in: ScriptBridge.world) { [weak self] result in
        let reason = (try? result.get()) as? String ?? "script-error"
        let safe =
          [
            "menu", "closed", "kept", "ended", "no-menu", "disabled", "home", "no-ui-press",
            "stale", "elsewhere", "detached", "moved", "scroll", "contextmenu", "multi-touch",
            "no-script",
          ].contains(reason) ? reason : "unknown"
        self?.uiHoldMenu.log?("\(phase.rawValue) result=\(safe)")
      }
    }
    uiHoldMenu.attach(to: browser.superview ?? browser)
  }

  /// Trackpad/mouse secondary click opens Figma's context menu (touch-gestures.ts dispatches it).
  func configureSecondaryClick() {
    guard session.mode != .safe, !scriptFreeRelated, let browser = webView else {
      secondaryClick.detach()
      return
    }
    secondaryClick.log = { [weak self] message in
      guard let self, self.diagnostics.inputLogging else { return }
      self.diagnostics.log("Secondary click \(message)")
    }
    secondaryClick.eligible = { [weak self] in
      guard let self else { return false }
      return self.isTabActive && self.session.mode != .safe && !self.scriptFreeRelated
    }
    secondaryClick.onClick = { [weak self, weak browser] point in
      guard let self, let browser else { return }
      let local = browser.convert(point, from: self.secondaryClick.host ?? browser)
      // Give WebKit's own secondary press and any menu Figma opens from it 150 ms to land.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak browser] in
        MainActor.assumeIsolated { self?.sendSecondaryClick(local, to: browser) }
      }
    }
    secondaryClick.attach(to: browser.superview ?? browser)
  }

  private func sendSecondaryClick(_ local: CGPoint, to browser: WKWebView?) {
    guard let browser, browser === webView, secondaryClick.eligible?() == true,
      browser.bounds.width > 0, browser.bounds.height > 0
    else { return }
    let x = Double(local.x / browser.bounds.width)
    let y = Double(local.y / browser.bounds.height)
    guard x.isFinite, y.isFinite else { return }
    let script =
      "globalThis.__folio?.secondaryClick?.(\(x) * innerWidth, \(y) * innerHeight) ?? 'no-script'"
    browser.evaluateJavaScript(script, in: nil, in: ScriptBridge.world) { [weak self] result in
      let reason = (try? result.get()) as? String ?? "script-error"
      let safe =
        [
          "menu", "menu-opened", "menu-opened-after-completion", "no-target", "editable",
          "no-script", "script-error",
        ]
        .contains(reason) ? reason : "unknown"
      self?.secondaryClick.log?(
        safe == "menu" ? "attempt contextmenu" : "attempt rejected reason=page-\(safe)")
    }
  }

  func applyTouchMode() {
    guard session.mode != .safe, !scriptFreeRelated, let browser = webView else { return }
    // Update both the live document and future navigation without rebuilding/reloading WebKit.
    let controller = browser.configuration.userContentController
    let scripts = controller.userScripts.filter {
      !$0.source.hasPrefix(WebViewConfiguration.touchModeMarker)
    }
    controller.removeAllUserScripts()
    for script in scripts { controller.addUserScript(script) }
    let source = WebViewConfiguration.touchModeSource(diagnostics.strategies.touchMode)
    controller.addUserScript(
      WKUserScript(
        source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true,
        in: ScriptBridge.world))
    runScript(source)
  }

  func applyStrategies() {
    guard isTabActive else { return }
    if scriptFreeRelated {
      // A promoted quarantine child keeps the ordinary WebKit baseline until rebuild.
      reroute.restore()
      trackpadPinch.detach()
      multiFingerTap.detach()
      uiHoldMenu.detach()
      secondaryClick.detach()
      focusScroll.setLocked(false)
      inputAssistant.setEnabled(false)
      return
    }
    applyTouchMode()
    configureMultiFingerTap()
    configureUIHoldMenu()
    configureSecondaryClick()
    applyFocusControls()
    let settings = diagnostics.strategies
    reroute.apply(
      scrollView: webView.scrollView,
      pencil: session.mode != .safe && settings.pencil == .gestureReroute,
      finger: session.mode == .safe ? .baseline : settings.finger)
    diagnostics.recognizersChanged = reroute.changedCount
    if session.mode != .safe && settings.trackpadPinchZoom {
      trackpadPinch.attach(to: webView)
      trackpadPinch.onUpdate = { [weak self] update in
        guard let self, self.webView.bounds.width > 0, self.webView.bounds.height > 0 else {
          return
        }
        let bounds = self.webView.bounds
        self.pinchTransport.handle(update) { PinchTransport.cssPoint($0, bounds: bounds) }
      }
    } else {
      #if DEBUG
        pinchHarness?.cancel(captureBrowser: false)
      #endif
      trackpadPinch.detach()
      pinchTransport.reset()
      runScript("globalThis.__folio?.resetTrackpadPinch?.(); void 0")
    }
    diagnostics.pinchReport = { [weak self] in
      guard let self else { return "unavailable" }
      let transport = self.pinchTransport
      return
        "route=\(self.diagnostics.strategies.trackpadPinchRoute.rawValue) sent=\(transport.sent) coalesced=\(transport.coalesced) maxRoundTrip=\(Int(transport.maxRoundTrip * 1000)) ms"
    }
    runScript(
      "globalThis.__folio?.setTrackpadPinchRoute?.('\(settings.trackpadPinchRoute.rawValue)'); void 0"
    )
    runScript(
      "globalThis.__folio?.setCanvasWheel?.(\(settings.fingerCanvasWheel)); void 0")
    runScript(
      "globalThis.__folio?.setTrackpadZoom?.(\(session.mode != .safe && settings.trackpadPinchZoom)); void 0"
    )
    runScript(
      "globalThis.__folio?.setTouchGestures?.(\(settings.touchGestures), \(tabSession.kind == .home)); void 0"
    )
    runScript("globalThis.__folio?.setResizeEdges?.(\(settings.resizeHelper)); void 0")
    runScript("globalThis.__folio?.setUAButtonColor?.(\(settings.uaButtonColor)); void 0")
    runScript("globalThis.__folio?.setHideGoogle?.(\(settings.hideGoogle)); void 0")
    applyPhoneLayout()
    let strategy = settings.pencil.rawValue
    let unusable = settings.penDragUnusable ? "true" : "false"
    runScript("globalThis.__folio?.setPencilStrategy?.('\(strategy)', \(unusable)); void 0")
    // JSON serialization keeps the fixed native label safe as a JS string.
    if let data = try? JSONEncoder().encode(settings.label),
      let label = String(data: data, encoding: .utf8)
    {
      runScript("globalThis.__folio?.setLabStrategy?.(\(label)); void 0")
    }
  }

  func releaseTouchShortcuts() {
    onShortcutState?(0)
    guard isViewLoaded else { return }
    runScript(
      "globalThis.__folio?.resetTouchShortcuts?.(); globalThis.__folio?.resetTouchGestures?.(); globalThis.__folio?.cancelCanvasContact?.(); void 0"
    )
  }

  func setTouchShortcutModifiers(_ mask: Int) {
    guard isTabActive else { return }
    runScript("globalThis.__folio?.setTouchShortcutModifiers?.(\(mask)); void 0")
  }

  func touchShortcutEdit(_ action: ShortcutEditAction, sender: UIView) {
    guard browserFocusGuard.eligible, let browser = webView,
      let responder = BrowserResponderFocus.editingResponder(in: browser)
    else { return }
    // Explicit target keeps the action in this tab/window, even without a native text selection.
    // WebKit owns clipboard formats and paste permission; Folio never reads UIPasteboard.
    UIApplication.shared.sendAction(action.selector, to: responder, from: sender, for: nil)
  }

  func touchShortcutKey(_ key: String, down: Bool? = nil) {
    guard isTabActive, popup == nil,
      let data = try? JSONEncoder().encode(key), let literal = String(data: data, encoding: .utf8)
    else { return }
    runScript(
      "globalThis.__folio?.touchShortcutKey?.(\(literal), \(down.map { $0 ? "true" : "false" } ?? "undefined")); void 0"
    )
  }

  /// Phone panel layout: on in compact-layout file tabs (iPhone phone-size scenes and narrow
  /// iPad windows), where Folio's bottom toolbar is always shown. Never in Safe mode or auth
  /// children.
  var phoneLayoutActive: Bool {
    compactLayout && session.mode != .safe
      && !scriptFreeRelated && tabSession.kind != .home
      && diagnostics.strategies.phoneLayout
  }

  /// "Canvas beside panels": the page reports Figma's reservation while a sheet is open.
  var phoneWideViewport: Bool {
    phoneLayoutActive && diagnostics.strategies.phoneWideViewport
  }

  /// Landscape side panels: Layers and Properties at Figma's own places, opened independently;
  /// built on the wide viewport, so "Canvas beside panels" off keeps the sheet in landscape too.
  var phoneSides: Bool { phoneWideViewport && phoneLandscape }

  /// "Number keyboard for numeric fields": decimal keypad plus Folio's key row in sheet fields.
  var phoneNumberKeyboard: Bool {
    phoneLayoutActive && diagnostics.strategies.phoneNumberKeyboard
  }

  /// Types one fixed key (PhoneKeyRow) into the focused numeric sheet field.
  func phoneFieldKey(_ key: String) {
    guard isTabActive, phoneNumberKeyboard,
      let data = try? JSONEncoder().encode(key), let literal = String(data: data, encoding: .utf8)
    else { return }
    runScript("globalThis.__folio?.phoneFieldKey?.(\(literal)); void 0")
  }

  /// The keyboard is about to move under an open sheet: its final overlap in CSS px and the
  /// minimum sheet fraction while it is up. The page places the sheet at once.
  func phoneKeyboard(overlap: Double, floor: Double) {
    guard isTabActive, phoneLayoutActive else { return }
    let values = [overlap, floor].map { $0.isFinite ? max(0, $0) : 0 }
    runScript("globalThis.__folio?.phoneKeyboard?.(\(values[0]), \(values[1])); void 0")
  }

  func applyPhoneLayout() {
    zoomViewport?.preservesPhoneGeometry = phoneLayoutActive
    if !phoneWideViewport { zoomViewport?.setOverscan(left: 0, right: 0) }
    runScript(
      "globalThis.__folio?.setPhoneLayout?.(\(phoneLayoutActive), \(phoneMinimized), \(phoneWideViewport), \(phoneNumberKeyboard), \(phoneSides)); void 0"
    )
    onPhoneLayoutChange?(true)
  }

  /// Keep the phone viewport widened across sheet toggles; reset when the layout is off.
  func applyPhoneOverscan(_ state: PhoneLayoutState) {
    // Each tab's viewport follows its own page, so a background tab keeps a consistent frame.
    let wide =
      phoneWideViewport && initialPageReady && !phoneNavigationLoading && state.panel != "off"
    // Side panel toggles move the visible region; cross-fade them in the selected tab.
    zoomViewport?.setOverscan(
      left: wide ? CGFloat(state.left) : 0, right: wide ? CGFloat(state.right) : 0,
      animated: phoneSides && isTabActive && view.window != nil)
  }

  /// Presentation-only sheet transport, without panel lookup or toggling.
  func phoneSheetDrag(
    _ phase: PhoneSheetHandle.DragPhase, fraction: Double,
    completion: @escaping (Bool) -> Void
  ) {
    guard phoneLayoutActive, isViewLoaded, let webView else { return completion(false) }
    let generation = webGeneration
    let url = webView.url
    webView.callAsyncJavaScript(
      "return globalThis.__folio?.phoneSheetDrag?.(phase, fraction) ?? false",
      arguments: ["phase": phase.rawValue, "fraction": fraction], in: nil, in: ScriptBridge.world
    ) { [weak self, weak webView] result in
      guard let self, let webView, webView === self.webView,
        generation == self.webGeneration, webView.url == url
      else { return completion(false) }
      completion((try? result.get()) as? Bool == true)
    }
  }

  /// Lookup failure and the actual open sheet are independent. The page expands or minimizes
  /// Figma's UI itself (phone-layout.ts) and posts later changes as `.phoneState`.
  func phonePanel(
    _ side: String?, fraction: Double,
    completion:
      @escaping (_ state: String, _ missing: Bool, _ tool: PhoneTool, _ mode: PhoneMode) -> Void
  ) {
    guard phoneLayoutActive, isViewLoaded, let webView
    else { return completion("off", false, .none, .unknown) }
    let generation = webGeneration
    let url = webView.url
    let script =
      "return globalThis.__folio?.phonePanel?.(side, fraction) ?? {state: 'off', missing: false, tool: 'none', mode: 'unknown'}"
    let arguments: [String: Any] = ["side": side ?? NSNull(), "fraction": fraction]
    webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: ScriptBridge.world) {
      [weak self, weak webView] result in
      guard let self, let webView, webView === self.webView,
        generation == self.webGeneration, webView.url == url
      else { return }
      let response = (try? result.get()) as? [String: Any]
      let state = response?["state"] as? String ?? "off"
      completion(
        PhoneLayoutState.panels.contains(state) ? state : "off",
        response?["missing"] as? Bool ?? false,
        (response?["tool"] as? String).flatMap(PhoneTool.init(rawValue:)) ?? .none,
        (response?["mode"] as? String).flatMap(PhoneMode.init(rawValue:)) ?? .unknown)
    }
  }

  func runScript(_ script: String) {
    guard session.mode != .safe, !scriptFreeRelated, let webView else { return }
    webView.evaluateJavaScript(script, in: nil, in: ScriptBridge.world) { _ in }
  }
  func runScriptWithCompletion(_ script: String, _ done: @escaping () -> Void) {
    guard session.mode != .safe, !scriptFreeRelated, let webView else {
      done()
      return
    }
    webView.evaluateJavaScript(script, in: nil, in: ScriptBridge.world) { _ in done() }
  }
  func applyLogging() {
    runScript(
      "globalThis.__folio?.setUIDragOptions?.(\(isTabActive && diagnostics.uiDragLogging)); void 0"
    )
    focusScroll.logging = isTabActive && diagnostics.inputLogging
    inputObserver?.isEnabled = true
    runScript(
      "globalThis.__folio?.setInputLogging?.(\(isTabActive && diagnostics.inputLogging ? "true" : "false")); void 0"
    )
    runScript(
      "globalThis.__folio?.setFocusLogging?.(\(isTabActive && diagnostics.inputLogging)); globalThis.__folio?.setFocusRevealLogging?.(\(isTabActive && diagnostics.inputLogging)); void 0"
    )
  }
  func applyFocusControls() {
    let editor = isTabActive && EditorFocusPolicy.allows(webView.url) && session.mode != .safe
    let settings = diagnostics.strategies
    focusScroll.setLocked(editor && (settings.editorScrollLock || phoneSheetOpen))
    inputAssistant.setEnabled(editor && settings.hardwareKeyboardAssistant)
    diagnostics.focusState =
      "editor=\(editor); lock=\(focusScroll.locked); zoomScale=\(webView.scrollView.zoomScale); offset=\(webView.scrollView.contentOffset)"
    runScript(
      "globalThis.__folio?.setFocusEnvironment?.(\(settings.focusViewportLimit), \(settings.hardwareKeyboardAssistant)); void 0"
    )
    runScript(
      "globalThis.__folio?.setFocusRevealGuard?.(\(editor && settings.focusRevealGuard)); void 0")
    updateFocusGeometry()
  }
  func updateFocusGeometry() {
    guard let webView else { return }
    #if DEBUG
      if showingFocusLab {
        focusGeometry.text =
          "lock=\(focusScroll.locked) zoom=\(webView.scrollView.zoomScale) offset=\(webView.scrollView.contentOffset.x),\(webView.scrollView.contentOffset.y) keyboardFrames=\(focusScroll.keyboardFrames)"
        view.bringSubviewToFront(focusGeometry)
      } else {
        focusGeometry.removeFromSuperview()
      }
    #endif
  }
  func captureEnvironment() {
    recordKeyboardProbe(phase: "capture", actions: true)
    runScript("globalThis.__folio?.captureKeyboardFocus?.(); void 0")
    focusScroll.sample("capture")
    diagnostics.focusState =
      "editor=\(session.mode != .safe && EditorFocusPolicy.allows(webView.url)); lock=\(focusScroll.locked); zoomScale=\(webView.scrollView.zoomScale); offset=\(webView.scrollView.contentOffset)"
    runScript("globalThis.__folio?.capture?.(); void 0")
  }
}
