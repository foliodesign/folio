import UIKit
import WebKit

@MainActor
extension FigmaWebViewController {
  func updateScriptWindowPermission() {
    guard let browser = webView else { return }
    let url = browser.url ?? tabSession.routingURL
    let enabled =
      session.mode != .safe && isTabActive
      && url.map(Self.isStandardLinkSource) == true
    let preferences = browser.configuration.preferences
    guard preferences.javaScriptCanOpenWindowsAutomatically != enabled else { return }
    preferences.javaScriptCanOpenWindowsAutomatically = enabled
    recordWindowEvidence("automaticPermission=\(enabled)")
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard webView === self.webView else { return }
    if let attempt = dashboardReload {
      if navigation === attempt.navigation {
        dashboardReload?.started = true
      } else {
        recordWindowEvidence("reloadAfterHandoff=cancelled reason=otherNavigation")
        dashboardReload = nil
      }
    }
    phoneNavigationLoading = true
    // Reset before provisional loading, while the old document can still report geometry.
    zoomViewport?.setOverscan(left: 0, right: 0)
    onPhoneLayoutChange?(false)
    zoomViewport?.beginLoading()
    bridge.visibleTextEditing = false
    bridge.domEditorFocused = true
    releaseTouchShortcuts()
    #if DEBUG
      domProbeTask?.cancel()
      domProbeTask = nil
      domProbeAutoCaptured = false
      // Includes same-URL reloads, which need not produce a URL KVO change.
      pinchHarness?.cancel(captureBrowser: false)
    #endif
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    guard webView === self.webView else { return }
    hideLoadFailure()
    if let attempt = dashboardReload, navigation === attempt.navigation {
      dashboardReload?.committed = true
      observeHealthyReloadCanvas()
    }
    updateScriptWindowPermission()
    latestPhoneLayoutState = nil
    initialPageReady = false
    // A new document starts at the normal width; its page reports a reservation again.
    zoomViewport?.setOverscan(left: 0, right: 0)
    if isTabActive { initialBrowserFocus.begin() }
    keyboardFocus.invalidate()
    closePopup()
    pinchTransport.reset()
    diagnostics.labResults = [:]
    showingMemoryLab = webView.url == MemoryLabBridge.url
    diagnostics.isMemoryLab = showingMemoryLab
    showingLab = webView.url == ScriptBridge.labURL
    diagnostics.isInputLab = showingLab
    persistNavigation(webView)
    if !isTabActive {
      runScript(
        "globalThis.__folio?.setCanvasWheel?.(false); globalThis.__folio?.setPencilStrategy?.('none', false); void 0"
      )
    }
    applyLogging()
    applyStrategies()
    zoomViewport?.refreshAfterLoad()
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === self.webView else { return }
    if let attempt = dashboardReload, navigation === attempt.navigation, let url = webView.url {
      if observeDashboardReload(url, finished: true) { return }
    }
    zoomViewport?.finishLoading()
    initialPageReady = true
    phoneNavigationLoading = false
    if let state = latestPhoneLayoutState { applyPhoneOverscan(state) }
    recoveringHome = false
    snapshotView?.removeFromSuperview()
    snapshotView = nil
    if isTabActive { tabSession.snapshot = nil }
    persistNavigation(webView)
    zoomViewport?.refreshAfterLoad()
    restoreBrowserFocus(reason: .pageReady)
    if !isTabActive {
      runScript(
        "globalThis.__folio?.setCanvasWheel?.(false); globalThis.__folio?.setPencilStrategy?.('none', false); void 0"
      )
    }
    applyLogging()
    applyStrategies()
    captureEnvironment()
    #if DEBUG
      scheduleDOMProbe()
      if showingFocusLab, webView.url == ScriptBridge.focusLabURL {
        // Exact offline fixture only. Observe native DOM touch delivery with page zoom locked.
        runScript(
          """
          (() => {
            const canvas = document.querySelector('canvas');
            const output = document.getElementById('contacts');
            const contacts = new Set(); let peak = 0;
            canvas.addEventListener('pointerdown', e => {
              if (e.pointerType !== 'touch') return;
              contacts.add(e.pointerId); peak = Math.max(peak, contacts.size);
              output.textContent = 'contactsPeak=' + peak;
            });
            for (const name of ['pointerup', 'pointercancel']) {
              window.addEventListener(name, e => contacts.delete(e.pointerId));
            }
          })(); void 0
          """)
      }
      if isTabActive && showingMemoryLab
        && ProcessInfo.processInfo.arguments.contains("--memory-smoke")
      {
        let wasm = ProcessInfo.processInfo.arguments.contains("--wasm-smoke")
        runScript(
          "document.getElementById('kind').value = '\(wasm ? "wasm" : "typed-array")'; globalThis.__folioMemorySmoke?.(); void 0"
        )
      }
    #endif
    diagnostics.lifecycle("Navigation finished: \(Privacy.redactedURL(webView.url))")
  }
  func persistNavigation(_ browser: WKWebView) {
    guard browser === webView, let url = browser.url else { return }
    if url == Self.nativeLabURL || url == ScriptBridge.labURL || url == ScriptBridge.focusLabURL
      || url == MemoryLabBridge.url
      || url == Self.authLabURL
    {
      diagnostics.currentURL = nil
      return
    }
    switch (tabSession.kind, TabNavigationRouter.classify(url)) {
    case (.home, .dashboard):
      tabSession.routingURL = url
      tabSession.lastDashboardURL = url
    case (.document, .file):
      let symbol = ChromeFileIcon.symbol(for: tabSession.routingURL)
      tabSession.routingURL = url
      session.lastURL = url
      // Entering or leaving Dev Mode changes only the query; repaint the tab icon.
      if ChromeFileIcon.symbol(for: url) != symbol { onNavigationStateChange?() }
    default: break
    }
    if tabSession.creatingFile, case .file = TabNavigationRouter.classify(url) {
      onResolvedCreation?(url)
    }
    diagnostics.currentURL = url
  }
  /// Public URL observation catches in-page routing that has no navigation action.
  @discardableResult
  func handoffObservedURL(_ url: URL) -> Bool {
    recordRouteEvidence(.observedURL, url: url)
    guard onRoute != nil else { return false }
    switch (tabSession.kind, TabNavigationRouter.classify(url)) {
    case (.home, .file):
      if popup != nil {
        pendingHandoffURL = url
        return true
      }
      if isTabActive {
        recordRouteEvidence(.homeHandoff, url: url)
        onHomeFileObserved?(url)
        restoreHome()
      } else if lastBackgroundRestore.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
        lastBackgroundRestore = Date()
        restoreHome()
      } else {
        recordRouteEvidence(.handoffSuppressed, url: url)
      }
      return true
    case (.home, .creation):
      return true  // Wait for the created file key without replaying creation.
    case (.document, .dashboard):
      guard isTabActive, popup == nil else { return true }
      recordRouteEvidence(.documentDashboard, url: url)
      onDocumentDashboardObserved?(url)
      return true
    default:
      return false
    }
  }

  func restoreHome() {
    guard tabSession.kind == .home, let webView else { return }
    let target = tabSession.lastDashboardURL ?? SessionState.startURL
    recordRouteEvidence(.homeRestore, url: target)
    webView.stopLoading()
    #if DEBUG
      if let fixtureNumber {
        TabFixture.load(in: webView, number: fixtureNumber, url: target)
        return
      }
    #endif
    webView.load(URLRequest(url: target))
  }

  func loadDashboard(_ url: URL) {
    guard tabSession.kind == .home else { return }
    tabSession.lastDashboardURL = url
    guard isViewLoaded, let webView, webView.url != url else { return }
    #if DEBUG
      if let fixtureNumber {
        TabFixture.load(in: webView, number: fixtureNumber, url: url)
        return
      }
    #endif
    webView.load(URLRequest(url: url))
  }

  func reloadFile() {
    guard tabSession.kind == .document, let url = tabSession.routingURL,
      case .file = TabNavigationRouter.classify(url), let webView
    else { return }
    #if DEBUG
      if let fixtureNumber {
        TabFixture.load(in: webView, number: fixtureNumber, url: url)
        return
      }
    #endif
    webView.load(URLRequest(url: url))
  }

  /// Probe only the retained file's own reload. Never infer deletion from the first dashboard jump.
  func reloadFileAfterDashboardHandoff() {
    #if DEBUG
      if fixtureNumber != nil {
        reloadFile()
        return
      }
    #endif
    guard tabSession.kind == .document, let url = tabSession.routingURL,
      case .file(let key) = TabNavigationRouter.classify(url), let browser = webView
    else { return }
    dashboardReload = nil
    guard let navigation = browser.load(URLRequest(url: url)) else {
      recordWindowEvidence("reloadAfterHandoff=notStarted")
      return
    }
    let attempt = DashboardReload(
      navigation: navigation, key: key, generation: webGeneration,
      deadline: Date().addingTimeInterval(30))
    dashboardReload = attempt
    recordWindowEvidence("reloadAfterHandoff=started windowSeconds=30")
    let attemptID = attempt.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
      guard let self, self.dashboardReload?.id == attemptID else { return }
      self.recordWindowEvidence("reloadAfterHandoff=expired tabKept=true")
      self.dashboardReload = nil
      self.onSnapshotReady?()
    }
  }

  @discardableResult
  func observeDashboardReload(_ url: URL, finished: Bool = false) -> Bool {
    guard let attempt = dashboardReload else { return false }
    guard attempt.generation == webGeneration, Date() <= attempt.deadline, !isTabActive else {
      dashboardReload = nil
      return false
    }
    // KVO can report the old dashboard while load() is starting. Require the exact
    // reload's committed document and a settled load before acting on its URL.
    guard attempt.committed, finished || webView?.isLoading == false else { return false }
    switch TabNavigationRouter.classify(url) {
    case .file(let key):
      if finished {
        observeHealthyReloadCanvas()
        recordWindowEvidence("reloadAfterHandoff=file sameFile=\(key == attempt.key) tabKept=true")
        if key == attempt.key, attempt.responseStatus == 200 {
          scheduleUnavailableFileCheck()
        } else {
          dashboardReload?.hidesTab = false
        }
      }
      if key != attempt.key { dashboardReload = nil }
      return false
    case .creation:
      dashboardReload = nil
      recordWindowEvidence("reloadAfterHandoff=creation tabKept=true")
      return false
    default:
      guard onDashboardReloadRejected != nil else { return false }
      let result = TabNavigationRouter.classify(url) == .dashboard ? "dashboard" : "nonFile"
      recordRouteEvidence(.dashboardReloadRejected, url: url)
      recordWindowEvidence("reloadAfterHandoff=\(result) rejected=true")
      dashboardReload = nil
      onDashboardReloadRejected?()
      return true
    }
  }

  /// Restore chrome on positive editor evidence as soon as the new document mounts.
  /// Two bounded, read-only observations cover commit and a later load completion.
  func observeHealthyReloadCanvas() {
    guard let attempt = dashboardReload, attempt.committed, attempt.hidesTab,
      !attempt.healthyCanvasCheckInFlight, attempt.healthyCanvasChecks < 2,
      let status = attempt.responseStatus, (200..<300).contains(status),
      attempt.generation == webGeneration, Date() <= attempt.deadline, !isTabActive,
      session.mode != .safe, !scriptFreeRelated, let browser = webView,
      let url = browser.url, TabNavigationRouter.classify(url) == .file(attempt.key),
      let resource = Bundle.main.url(
        forResource: "file-availability", withExtension: "js", subdirectory: "Compat"),
      let script = try? String(contentsOf: resource, encoding: .utf8)
    else { return }
    dashboardReload?.healthyCanvasChecks += 1
    dashboardReload?.healthyCanvasCheckInFlight = true
    let id = attempt.id
    let started = Date()
    browser.callAsyncJavaScript(
      script + "\nreturn await globalThis.__folioWaitForFileCanvas();",
      arguments: [:], in: nil, in: ScriptBridge.world
    ) { [weak self, weak browser] result in
      guard let self, let browser, self.webView === browser,
        let current = self.dashboardReload, current.id == id,
        current.generation == self.webGeneration, Date() <= current.deadline,
        !self.isTabActive, self.session.mode != .safe, !self.scriptFreeRelated,
        let url = browser.url, TabNavigationRouter.classify(url) == .file(current.key)
      else { return }
      self.dashboardReload?.healthyCanvasCheckInFlight = false
      guard case .success(let value) = result, let healthy = value as? Bool else { return }
      if healthy {
        self.dashboardReload?.hidesTab = false
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        self.recordWindowEvidence(
          "reloadAfterHandoff=healthyCanvas restored=true observationMilliseconds=\(elapsed)")
      } else if !browser.isLoading {
        self.observeHealthyReloadCanvas()
      }
    }
  }

  func scheduleUnavailableFileCheck() {
    guard let attempt = dashboardReload, !attempt.availabilityScheduled,
      session.mode != .safe, !scriptFreeRelated, let browser = webView,
      let resource = Bundle.main.url(
        forResource: "file-availability", withExtension: "js", subdirectory: "Compat"),
      let script = try? String(contentsOf: resource, encoding: .utf8)
    else {
      dashboardReload?.hidesTab = false
      return
    }
    dashboardReload?.availabilityScheduled = true
    let id = attempt.id
    recordWindowEvidence("reloadAfterHandoff=unavailableCheckScheduled")
    for delay in [3.0, 6.0, 10.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak browser] in
        guard let self, let browser, self.webView === browser,
          let current = self.dashboardReload, current.id == id,
          current.generation == self.webGeneration, Date() <= current.deadline,
          current.committed, !self.isTabActive, !browser.isLoading,
          self.session.mode != .safe, !self.scriptFreeRelated,
          let url = browser.url, TabNavigationRouter.classify(url) == .file(current.key)
        else { return }
        browser.callAsyncJavaScript(
          script + "\nreturn globalThis.__folioUnavailableFile();",
          arguments: [:], in: nil, in: ScriptBridge.world
        ) { [weak self, weak browser] result in
          guard let self, let browser, self.webView === browser,
            let current = self.dashboardReload, current.id == id,
            current.generation == self.webGeneration, Date() <= current.deadline,
            !self.isTabActive, !browser.isLoading,
            self.session.mode != .safe, !self.scriptFreeRelated,
            let url = browser.url, TabNavigationRouter.classify(url) == .file(current.key)
          else { return }
          guard case .success(let value) = result, let unavailable = value as? Bool else {
            self.dashboardReload?.unavailableMatches = 0
            self.dashboardReload?.hidesTab = false
            self.recordWindowEvidence("reloadAfterHandoff=unavailableCheckFailed tabKept=true")
            return
          }
          if !unavailable { self.dashboardReload?.hidesTab = false }
          self.recordWindowEvidence("reloadAfterHandoff=unavailableCard matched=\(unavailable)")
          self.dashboardReload?.unavailableMatches =
            unavailable ? current.unavailableMatches + 1 : 0
          guard (self.dashboardReload?.unavailableMatches ?? 0) >= 2,
            self.onDashboardReloadRejected != nil
          else { return }
          self.dashboardReload = nil
          self.recordWindowEvidence("reloadAfterHandoff=unavailableCard rejected=true")
          self.onDashboardReloadRejected?()
        }
      }
    }
  }

  /// Only an isolated, trusted standard-link click can request pre-navigation handoff.
  static func isStandardLinkSource(_ url: URL) -> Bool {
    switch TabNavigationRouter.classify(url) {
    case .file, .dashboard: return true
    default: return false
    }
  }

  func routeStandardFileLink(_ url: URL, from browser: WKWebView, mainFrame: Bool) {
    if browser === webView, mainFrame { recordRouteEvidence(.trustedAnchor, url: url) }
    guard browser === webView, mainFrame, isTabActive, session.mode != .safe,
      popup == nil, let current = browser.url,
      Self.isStandardLinkSource(current),
      TabNavigationRouter.navigationAction(
        home: tabSession.kind == .home, currentURL: current, destination: url,
        mainFrame: true, method: "GET", download: false) == .openFile,
      Self.isFileRoute(url) || TabNavigationRouter.classify(url) == .creation
    else { return }
    _ = onRoute?(url, nil)
  }

  func openCurrentFileInNewTab() {
    guard let url = webView?.url, case .file = TabNavigationRouter.classify(url) else { return }
    onOpenCurrentFile?(url)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard webView === self.webView else { return }
    dashboardReload = nil
    zoomViewport?.finishLoading()
    zoomViewport?.setOverscan(left: 0, right: 0)
    closePopup()
    #if DEBUG
      pinchHarness?.cancel(captureBrowser: false)
    #endif
    trackpadPinch.detach()
    pinchTransport.reset()
    session.recordCrash()
    diagnostics.lifecycle(
      "WebContent terminated; count=\(session.crashCount) URL=\(Privacy.redactedURL(webView.url))")
    diagnostics.environment = nil
    diagnostics.labResults = [:]
    panel?.refresh()
    diagnostics.memoryEvent("WebContent terminated (reason unavailable)")
    if showingMemoryLab && memoryOwnership.tabID == tabSession.id {
      do {
        try diagnostics.memory.interrupt(
          status: "webcontent-terminated", availableBytes: diagnostics.availableMemory)
      } catch { diagnostics.lifecycle("Memory termination persistence failed") }
    }
    pendingExternalURL = nil
    tabSession.routingURL = session.lastURL
    tabSession.backgroundRecoveryAllowed = tabSession.recovery.shouldReload(
      limit: tabSession.kind == .home ? 2 : 3)
    tabSession.stoppedInBackground = !isTabActive
    if !isTabActive {
      recoveryBanner?.removeFromSuperview()
      let event = "Background WebContent terminated; tab=\(tabSession.id) needs reload on selection"
      diagnostics.lifecycle(event)
      onBackgroundTermination?(event)
    } else {
      let reload = tabSession.backgroundRecoveryAllowed
      if tabSession.kind != .home || !reload { showRecoveryBanner(reloaded: reload) }
      if reload {
        recoveringHome = tabSession.kind == .home
        loadCurrentPage()
      } else {
        diagnostics.lifecycle("Automatic recovery paused after repeated terminations")
      }
    }
    diagnostics.writeSmokeReportIfRequested()
    panel?.refresh()
  }

  func interruptMemoryRun() {
    guard memoryOwnership.tabID == tabSession.id else { return }
    do {
      try diagnostics.memory.interrupt(
        status: "navigation-interrupted", availableBytes: diagnostics.availableMemory)
    } catch { diagnostics.lifecycle("Memory interruption persistence failed") }
  }

  /// Network failures otherwise leave a blank or stale page with no explanation.
  func showLoadFailure(_ message: LoadFailureView.Message) {
    hideLoadFailure()
    let card = LoadFailureView(message: message) { [weak self] in
      guard let self else { return }
      self.hideLoadFailure()
      self.loadCurrentPage()
    }
    card.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(card)
    let guide = view.safeAreaLayoutGuide
    let preferredWidth = card.widthAnchor.constraint(equalToConstant: 380)
    preferredWidth.priority = .defaultHigh
    NSLayoutConstraint.activate([
      card.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: guide.centerYAnchor, constant: -40),
      card.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 24),
      card.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -24),
      preferredWidth,
    ])
    loadFailureView = card
    diagnostics.lifecycle("Load failure shown")
  }

  func hideLoadFailure() {
    loadFailureView?.removeFromSuperview()
    loadFailureView = nil
  }

  func showRecoveryBanner(reloaded: Bool, background: Bool = false) {
    recoveryBanner?.removeFromSuperview()
    let label = UILabel()
    label.text =
      background
      ? "The background page stopped. Reload to continue; the cause is unavailable."
      : reloaded
        ? "The page stopped. Reload requested; the cause is unavailable."
        : "The page stopped repeatedly. Automatic reload paused."
    label.numberOfLines = 0
    label.font = .preferredFont(forTextStyle: .body)
    let reload = UIButton(type: .system)
    reload.setTitle("Reload", for: .normal)
    reload.addAction(
      UIAction { [weak self] _ in
        self?.recoveryBanner?.removeFromSuperview()
        self?.loadCurrentPage()
      }, for: .touchUpInside)
    let safe = UIButton(type: .system)
    safe.setTitle("Safe mode", for: .normal)
    safe.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.session.mode = .safe
        self.recoveryBanner?.removeFromSuperview()
        self.rebuildWebView()
        self.panel?.refresh()
      }, for: .touchUpInside)
    let banner = UIStackView(arrangedSubviews: [label, reload, safe])
    banner.axis = .vertical
    banner.backgroundColor = .secondarySystemBackground
    banner.isLayoutMarginsRelativeArrangement = true
    banner.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    banner.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(banner)
    NSLayoutConstraint.activate([
      banner.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      banner.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -56),
      banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
    ])
    recoveryBanner = banner
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    guard webView === self.webView else { return }
    if let attempt = dashboardReload, navigation === attempt.navigation {
      recordWindowEvidence("reloadAfterHandoff=failed tabKept=true")
      dashboardReload = nil
    }
    snapshotView?.removeFromSuperview()
    snapshotView = nil
    zoomViewport?.finishLoading()
    phoneNavigationLoading = false
    // Error descriptions can contain URLs and tokens; record only the numeric code.
    diagnostics.lifecycle("Navigation failed; NSError \((error as NSError).code)")
    if (error as NSError).code != NSURLErrorCancelled {
      if recoveringHome {
        recoveringHome = false
        tabSession.backgroundRecoveryAllowed = false
        if isTabActive { showRecoveryBanner(reloaded: false) }
      } else if let message = LoadFailureView.message(for: error as NSError) {
        showLoadFailure(message)
      }
      initialPageReady = true
      restoreBrowserFocus(reason: .pageReady)
    }
    if let state = latestPhoneLayoutState { applyPhoneOverscan(state) }
  }
  @discardableResult
  func routeNavigation(
    _ input: TabNavigationRouter.Input, from browser: WKWebView,
    cancel: () -> Void = {}
  ) -> Bool {
    if tabSession.creatingFile, input.kind != .linkActivated { return false }
    guard browser === webView, isTabActive, popup == nil, let onRoute,
      TabNavigationRouter.action(
        home: tabSession.kind == .home,
        currentURL: tabSession.routingURL, input: input) != .allow
    else { return false }
    if TabNavigationRouter.classify(input.destination) == .dashboard,
      let onDocumentDashboardObserved
    {
      cancel()
      recordRouteEvidence(.documentDashboard, url: input.destination, input: input)
      onDocumentDashboardObserved(input.destination)
      return true
    }
    if input.modifiers.contains(.command) || input.button.contains(.init(rawValue: 1 << 2)) {
      guard let onOpenLink else { return false }
      cancel()
      onOpenLink(input.destination, false)
    } else {
      cancel()
      _ = onRoute(input.destination, nil)
    }
    return true
  }

  func webView(
    _ browser: WKWebView,
    contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
    completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void
  ) {
    guard browser === webView, isTabActive, popup == nil, let url = elementInfo.linkURL,
      case .file = TabNavigationRouter.classify(url)
    else {
      completionHandler(
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { suggested in
          UIMenu(children: suggested)
        })
      return
    }
    completionHandler(
      UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
        [weak self, weak browser] suggested in
        let open = UIAction(title: "Open in new tab") { _ in
          guard let self, let browser, self.webView === browser, self.isTabActive,
            self.popup == nil
          else { return }
          _ = self.onRoute?(url, nil)
        }
        return UIMenu(children: suggested + [open])
      })
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    if webView === self.webView, let url = navigationAction.request.url, onRoute != nil {
      let input = TabNavigationRouter.Input(
        destination: url, mainFrame: navigationAction.targetFrame?.isMainFrame == true,
        targetFrame: navigationAction.targetFrame.map { $0.isMainFrame ? .main : .subframe }
          ?? .absent,
        sourceMainFrame: navigationAction.sourceFrame.isMainFrame,
        method: navigationAction.request.httpMethod ?? "GET",
        download: navigationAction.shouldPerformDownload, kind: navigationAction.navigationType,
        modifiers: navigationAction.modifierFlags, button: navigationAction.buttonNumber)
      recordRouteEvidence(.navigationAction, url: url, input: input)
      if routeNavigation(input, from: webView, cancel: { decisionHandler(.cancel) }) {
        return
      }
      #if DEBUG
        if let fixtureNumber, input.mainFrame, !input.download, input.method == "GET",
          input.kind == .linkActivated
        {
          relatedInitialNavigation = false
          decisionHandler(.cancel)
          tabSession.routingURL = url
          TabFixture.load(in: webView, number: fixtureNumber, url: url)
          return
        }
      #endif
    }
    #if DEBUG
      if webView === self.webView, relatedInitialNavigation,
        navigationAction.targetFrame?.isMainFrame == true, let fixtureNumber,
        let url = navigationAction.request.url
      {
        relatedInitialNavigation = false
        decisionHandler(.cancel)
        // Finish the original child's decision before submitting the offline response.
        // Keep the exact related browser/configuration and its opener relationship.
        DispatchQueue.main.async { [weak self, weak webView] in
          guard let self, let webView, self.webView === webView else { return }
          TabFixture.load(in: webView, number: fixtureNumber, url: url)
        }
        return
      }
    #endif
    if navigationAction.targetFrame != nil,
      PopupPolicy.isGoogleOAuth(navigationAction.request.url)
    {
      decisionHandler(.cancel)
      if let popup {
        popup.showMessage(PopupPolicy.googleMessage)
      } else if presentedViewController == nil {
        let alert = UIAlertController(
          title: "Google sign-in unavailable", message: PopupPolicy.googleMessage,
          preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(alert, animated: true)
      }
      return
    }
    guard let url = navigationAction.request.url,
      ["https", "about"].contains(url.scheme)
        || (navigationAction.shouldPerformDownload && ["blob", "data"].contains(url.scheme))
        || (showingNativeLab && url == Self.nativeLabURL)
        || ((showingLab && url == ScriptBridge.labURL)
          || (showingMemoryLab && url == MemoryLabBridge.url)
          || (showingAuthLab && url == Self.authLabURL)
          || (showingFocusLab && url == ScriptBridge.focusLabURL)
          || (navigationAction.targetFrame == nil && authLocalURLs.contains(url)))
    else {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    if webView === self.webView, navigationResponse.isForMainFrame,
      let attempt = dashboardReload, attempt.started,
      attempt.generation == webGeneration, Date() <= attempt.deadline, !isTabActive,
      let response = navigationResponse.response as? HTTPURLResponse,
      let url = response.url, TabNavigationRouter.classify(url) == .file(attempt.key)
    {
      dashboardReload?.responseStatus = response.statusCode
      recordWindowEvidence(
        "reloadAfterHandoff=response status=\(response.statusCode) sameFile=true")
      if [403, 404, 410].contains(response.statusCode), onDashboardReloadRejected != nil {
        decisionHandler(.cancel)
        dashboardReload = nil
        recordWindowEvidence("reloadAfterHandoff=unavailableHTTP rejected=true")
        onDashboardReloadRejected?()
        return
      }
    }
    decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
  }
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    guard webView === self.webView, isTabActive, popup == nil,
      navigationAction.targetFrame == nil, !navigationAction.shouldPerformDownload
    else {
      recordWindowEvidence("decision=reject reason=ownership")
      return nil
    }
    let sourceURL = navigationAction.sourceFrame.request.url
    let localAuthSource =
      showingAuthLab && sourceURL.map(authLocalURLs.contains) == true
      && webView.url.map(authLocalURLs.contains) == true
    guard navigationAction.sourceFrame.isMainFrame,
      (PopupPolicy.isFigmaPage(sourceURL) && PopupPolicy.isFigmaPage(webView.url))
        || localAuthSource
    else {
      recordWindowEvidence("decision=reject reason=source")
      return nil
    }
    // Public WKNavigationAction has no user-activation flag. Home must support both
    // delayed document creation and Figma's Add account child. Admit only a direct
    // same-site auth destination here; blank document children stay document-only.
    let homeAuth =
      tabSession.kind == .home && (navigationAction.request.httpMethod ?? "GET") == "GET"
      && ((sourceURL.map(TabNavigationRouter.classify) == .dashboard
        && webView.url.map(TabNavigationRouter.classify) == .dashboard
        && PopupPolicy.allowsHomeAuthWindow(navigationAction.request.url))
        || (localAuthSource && navigationAction.request.url.map(authLocalURLs.contains) == true))
    let automatic = webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically
    let documentOnly = automatic && !homeAuth
    if documentOnly,
      (navigationAction.request.httpMethod ?? "GET") != "GET"
        || !PopupPolicy.allowsDocumentWindow(navigationAction.request.url)
    {
      recordWindowEvidence("decision=reject reason=automaticDestination")
      return nil
    }
    recordRouteEvidence(
      .nilTargetChild, url: navigationAction.request.url,
      input: .init(
        destination: navigationAction.request.url ?? SessionState.startURL,
        mainFrame: false, targetFrame: .absent,
        sourceMainFrame: navigationAction.sourceFrame.isMainFrame,
        method: navigationAction.request.httpMethod ?? "GET",
        download: navigationAction.shouldPerformDownload, kind: navigationAction.navigationType))
    if (navigationAction.request.httpMethod ?? "GET") == "GET",
      !navigationAction.shouldPerformDownload, let url = navigationAction.request.url,
      TabNavigationRouter.classify(url) == .creation || Self.isFileRoute(url), let onRoute
    {
      recordWindowEvidence("decision=route documentOnly=\(documentOnly)")
      return onRoute(url, configuration)
    }
    recordWindowEvidence("decision=popup documentOnly=\(documentOnly)")
    return openPopup(
      configuration: configuration, url: navigationAction.request.url,
      documentOnly: documentOnly)
  }

  static func isFileRoute(_ url: URL) -> Bool {
    if case .file = TabNavigationRouter.classify(url) { return true }
    return false
  }

  func webView(
    _ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
  ) {
    guard webView === self.webView else { return }
    recordRouteEvidence(.redirect, url: webView.url)
  }

  #if DEBUG
    func loadPromotedFixture(_ url: URL) {
      guard let fixtureNumber, let browser = webView else { return }
      let generation = webGeneration
      DispatchQueue.main.async { [weak self, weak browser] in
        guard let self, let browser, self.webView === browser,
          self.webGeneration == generation
        else { return }
        TabFixture.load(in: browser, number: fixtureNumber, url: url)
      }
    }
  #endif
}
