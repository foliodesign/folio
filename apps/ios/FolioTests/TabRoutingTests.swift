import WebKit
import XCTest

@testable import Folio

@MainActor
final class TabRoutingTests: XCTestCase {
  func testClassification() {
    for route in ["design", "file", "board", "proto", "slides", "site", "make"] {
      XCTAssertEqual(
        TabNavigationRouter.classify(
          URL(
            string:
              "https://figma.com/\(route)/Key_123-abc/Title?node-id=1#canvas")!),
        .file("Key_123-abc"))
      XCTAssertEqual(
        TabNavigationRouter.classify(
          URL(
            string:
              "https://www.figma.com/\(route)/")!), .external)
    }
    for route in ["files", "files/project/123", "files/search", "project/123", "settings/account"] {
      XCTAssertEqual(
        TabNavigationRouter.classify(URL(string: "https://www.figma.com/\(route)")!),
        .dashboard)
    }
    for route in ["login", "signup", "sso", "oauth/callback", "auth/callback", "logout"] {
      XCTAssertEqual(
        TabNavigationRouter.classify(URL(string: "https://figma.com/\(route)")!), .auth)
    }
    XCTAssertEqual(
      TabNavigationRouter.classify(
        URL(
          string:
            "https://accounts.google.com/o/oauth2/auth?code=secret")!), .auth)
    for raw in [
      "http://figma.com/design/key", "https://figma.com.evil.example/design/key",
      "https://user:pass@figma.com/design/key", "https://figma.com:444/design/key",
      "https://example.com/design/key", "https://figma.com/design/key%2Fother",
      "https://figma.com/design/%E2%98%83", "about:blank",
    ] {
      XCTAssertEqual(TabNavigationRouter.classify(URL(string: raw)!), .external, raw)
    }
  }

  func testPostDownloadsAndSubframesStayInTheirOriginalView() {
    let file = URL(string: "https://www.figma.com/design/file")!
    for scenario in [(true, "POST", false), (true, "GET", true), (false, "GET", false)] {
      XCTAssertEqual(
        TabNavigationRouter.navigationAction(
          home: true,
          currentURL: SessionState.startURL, destination: file,
          mainFrame: scenario.0, method: scenario.1, download: scenario.2), .allow)
    }
    XCTAssertEqual(
      TabNavigationRouter.navigationAction(
        home: true,
        currentURL: SessionState.startURL, destination: file,
        mainFrame: true, method: "GET", download: false), .openFile)
  }

  func testDetachedShellYieldsAllFolioCommands() {
    let name = "folio.routing.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let host = BrowserWindowController(
      session: WindowSession(defaults: defaults, migrateLegacy: false))
    let commands = host.keyCommands ?? []
    // fbc8eb6 makes window commands contextual; an unattached host owns none.
    XCTAssertTrue(commands.isEmpty)
  }

  func testNavigationAndIdentity() {
    let first = URL(string: "https://www.figma.com/design/first/Title?node-id=1")!
    let same = URL(string: "https://figma.com/proto/first/Other#node")!
    let second = URL(string: "https://www.figma.com/board/second")!
    XCTAssertEqual(
      TabNavigationRouter.action(
        home: true, currentURL: SessionState.startURL,
        destination: first), .openFile)
    XCTAssertEqual(
      TabNavigationRouter.action(
        home: false, currentURL: first,
        destination: same), .allow)
    XCTAssertEqual(
      TabNavigationRouter.action(
        home: false, currentURL: first,
        destination: second), .openFile)
    XCTAssertEqual(
      TabNavigationRouter.action(
        home: false, currentURL: first,
        destination: SessionState.startURL), .selectHome)
    let name = "folio.routing.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let window = WindowSession(defaults: defaults, migrateLegacy: false)
    let tab = window.openFile(url: first)
    _ = window.openFile(url: second)
    XCTAssertTrue(window.openFile(url: same) === tab)
    XCTAssertEqual(window.tabs.count, 3)
    XCTAssertEqual(window.selectedID, tab.id)
    XCTAssertEqual(tab.routingURL, first)  // Duplicate selection never reloads the existing editor.
  }

  func testTitlesAreTransientAndStripOnlyTrailingProductSuffix() {
    XCTAssertEqual(TabSession.documentTitle("  My Figma file – Figma  "), "My Figma file")
    XCTAssertEqual(TabSession.documentTitle("Figma | Design"), "Figma | Design")
    XCTAssertNil(TabSession.documentTitle("Figma"))
    XCTAssertNil(TabSession.documentTitle("  "))
    let name = "folio.title.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let window = WindowSession(defaults: defaults)
    let tab = window.add(url: URL(string: "https://www.figma.com/design/title")!)
    tab.displayTitle = "Private transient title"
    window.select(window.home.id)
    window.select(tab.id)
    XCTAssertFalse(
      String(describing: defaults.dictionaryRepresentation()).contains(tab.displayTitle!))
    let strip = BrowserChromeView()
    strip.render(
      B3BrowserChromeState(
        tabs: window.tabs.map {
          .init(id: $0.id, home: $0.kind == .home, title: $0.displayTitle, pinned: $0.isPinned)
        }, selectedID: window.selectedID, canGoBack: false, canGoForward: false, loading: false))
    let tabs = allTabViews(strip)
    XCTAssertEqual(
      tabs.first(where: { $0.accessibilityIdentifier == "tab-1" })?.accessibilityLabel,
      tab.displayTitle)
    XCTAssertEqual(
      tabs.first(where: { $0.accessibilityIdentifier == "tab-0" })?.accessibilityLabel, "Home")
  }

  private func allTabViews(_ root: UIView) -> [ChromeTabView] {
    (root as? ChromeTabView).map { [$0] } ?? root.subviews.flatMap(allTabViews)
  }

  func testCurrentViewTitleKVOIncludesInactiveTabAndRejectsReplacedView() {
    let name = "folio.kvo.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: memoryURL)
    }
    let tab = TabSession(
      kind: .document, url: URL(string: "https://www.figma.com/design/local")!, defaults: defaults)
    let controller = FigmaWebViewController(
      tab: tab, websiteDataStore: .nonPersistent(),
      memory: MemoryLabStore(url: memoryURL), fixtureNumber: 1)
    controller.loadViewIfNeeded()
    defer { controller.closeTab() }
    let title = expectation(description: "Initial title observed")
    controller.onTitleChange = {
      if tab.displayTitle == "Local document 1" { title.fulfill() }
    }
    wait(for: [title], timeout: 10)
    controller.setTabActive(false)
    let renamed = expectation(description: "Inactive title observed")
    controller.onTitleChange = {
      if tab.displayTitle == "Inactive rename" { renamed.fulfill() }
    }
    controller.webView.evaluateJavaScript("document.title = 'Inactive rename – Figma'") {
      _, error in
      XCTAssertNil(error)
    }
    wait(for: [renamed], timeout: 5)
    let old = controller.webView!
    controller.onTitleChange = nil
    controller.rebuildWebView()
    let fresh = expectation(description: "New view title")
    controller.onTitleChange = {
      if tab.displayTitle == "Local document 1" { fresh.fulfill() }
    }
    wait(for: [fresh], timeout: 10)
    controller.onTitleChange = nil
    let late = expectation(description: "Old view update returns")
    old.evaluateJavaScript("document.title = 'Stale title – Figma'") { _, _ in late.fulfill() }
    wait(for: [late], timeout: 5)
    XCTAssertEqual(tab.displayTitle, "Local document 1")
  }

  func testPushStateRetainsSourceTokenHistoryAndEditableValue() {
    let name = "folio.spa.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: memoryURL)
    }
    let tab = TabSession(
      kind: .document, url: URL(string: "https://www.figma.com/design/local")!, defaults: defaults)
    let controller = FigmaWebViewController(
      tab: tab, websiteDataStore: .nonPersistent(),
      memory: MemoryLabStore(url: memoryURL), fixtureNumber: 1)
    var routes = 0
    controller.onRoute = { _, _ in
      routes += 1
      return nil
    }
    controller.loadViewIfNeeded()
    defer { controller.closeTab() }
    let loaded = expectation(description: "Fixture loaded")
    controller.onTitleChange = {
      if tab.displayTitle == "Local document 1" { loaded.fulfill() }
    }
    wait(for: [loaded], timeout: 10)
    controller.onTitleChange = nil
    let browser = controller.webView!
    let ready = expectation(description: "Fixture document complete")
    browser.callAsyncJavaScript(
      """
      if (document.readyState !== 'complete') {
        await new Promise(resolve => window.addEventListener('load', resolve, {once: true}));
      }
      return true;
      """, arguments: [:], in: nil, in: .page
    ) { result in
      if case .failure(let error) = result { XCTFail(String(describing: error)) }
      ready.fulfill()
    }
    wait(for: [ready], timeout: 10)
    // Prove the fixture committed a real native history entry before testing pushState.
    // A title/load event from substitute HTML is insufficient.
    XCTAssertEqual(browser.url, tab.routingURL)
    XCTAssertNotNil(browser.backForwardList.currentItem)
    let originalItem = browser.backForwardList.currentItem
    let originalBackCount = browser.backForwardList.backList.count
    let changed = expectation(description: "Stateful SPA mutation")
    browser.evaluateJavaScript(
      """
      globalThis.originalToken = document.getElementById('load').textContent;
      globalThis.originalHistoryLength = window.history.length;
      document.getElementById('increment').click();
      document.querySelector('input').value = 'retained';
      window.history.pushState({}, '', '/design/other');
      """
    ) { _, error in
      XCTAssertNil(error)
      changed.fulfill()
    }
    wait(for: [changed], timeout: 5)
    let observed = expectation(description: "Observed URL")
    let observation = browser.observe(\.url, options: [.initial, .new]) { browser, _ in
      Task { @MainActor in
        if browser.url?.path == "/design/other" { observed.fulfill() }
      }
    }
    wait(for: [observed], timeout: 5)
    observation.invalidate()
    let checked = expectation(description: "Source state checked")
    browser.evaluateJavaScript(
      """
      window.history.length === globalThis.originalHistoryLength + 1 &&
      document.getElementById('load').textContent === globalThis.originalToken &&
      document.getElementById('count').textContent === 'Count 1' &&
      document.getElementById('history').textContent === 'History 0,1' &&
      document.querySelector('input').value === 'retained'
      """
    ) { value, error in
      XCTAssertNil(error)
      XCTAssertEqual(value as? Bool, true)
      if value as? Bool != true {
        browser.evaluateJavaScript(
          "JSON.stringify({actual:window.history.length, before:globalThis.originalHistoryLength, token:document.getElementById('load').textContent===originalToken, count:document.getElementById('count').textContent, history:document.getElementById('history').textContent, value:document.querySelector('input').value})"
        ) { state, _ in
          let evidence = XCTAttachment(string: String(describing: state))
          evidence.name = "Local SPA retained state"
          evidence.lifetime = .keepAlways
          self.add(evidence)
          checked.fulfill()
        }
      } else {
        checked.fulfill()
      }
    }
    wait(for: [checked], timeout: 5)
    XCTAssertTrue(controller.webView === browser)
    XCTAssertEqual(routes, 0)
    XCTAssertEqual(browser.backForwardList.backList.count, originalBackCount + 1)
    XCTAssertEqual(browser.backForwardList.backList.last?.url, originalItem?.url)
    XCTAssertEqual(browser.backForwardList.currentItem?.url.path, "/design/other")
    let destination = URL(string: "https://www.figma.com/design/new")!
    controller.routeStandardFileLink(destination, from: WKWebView(), mainFrame: true)
    controller.routeStandardFileLink(destination, from: browser, mainFrame: false)
    controller.routeStandardFileLink(
      URL(string: "https://evil.test/design/new")!, from: browser, mainFrame: true)
    XCTAssertEqual(routes, 0)
    controller.routeStandardFileLink(destination, from: browser, mainFrame: true)
    XCTAssertEqual(routes, 1)
    XCTAssertTrue(controller.webView === browser)
    controller.setTabActive(false)
    controller.routeStandardFileLink(destination, from: browser, mainFrame: true)
    XCTAssertEqual(routes, 1)
  }

  func testWarmAndColdDashboardDeliveryStaySelectedThroughInitialNavigation() throws {
    for warm in [false, true] {
      let name = "folio.dashboard.delivery.\(UUID())"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
      let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: memoryURL)
      }
      let window = WindowSession(defaults: defaults, migrateLegacy: false)
      let host = BrowserWindowController(
        session: window, websiteDataStore: .nonPersistent(), memory: MemoryLabStore(url: memoryURL),
        useFixture: true)
      if warm { host.loadViewIfNeeded() }
      let source = warm ? host.children.first as? FigmaWebViewController : nil
      let browser = source?.webView
      let url = URL(string: "https://www.figma.com/files?node-id=private#secret")!
      host.openExternalLink(url)
      let destination = try XCTUnwrap(host.children.first as? FigmaWebViewController)
      XCTAssertEqual(window.selectedID, destination.tabSession.id)
      XCTAssertEqual(window.selectedID, window.home.id)
      XCTAssertEqual(
        TabNavigationRouter.action(
          home: false, currentURL: url,
          input: .init(destination: url, kind: .other)), .allow)
      XCTAssertEqual(window.selectedID, destination.tabSession.id)
      XCTAssertTrue(destination.diagnostics.report.contains("External link: www.figma.com/files"))
      XCTAssertFalse(destination.diagnostics.report.contains("private"))
      XCTAssertFalse(destination.diagnostics.report.contains("secret"))
      if let source {
        window.select(window.home.id)
        host.showSelectedTab(ownerSelection: true)
        XCTAssertTrue(host.children.first === source)
        XCTAssertTrue(source.webView === browser)
        XCTAssertTrue(source.isTabActive)
        XCTAssertTrue(destination.isTabActive)
      }
      // Dashboard delivery reuses Home, so these are the same controller.
      destination.closeTab()
    }
  }

  func testInitialReloadAndRedirectCannotRouteButLinkActivationCan() throws {
    let name = "folio.routing.action.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: memoryURL)
    }
    let tab = TabSession(kind: .document, url: SessionState.startURL, defaults: defaults)
    let controller = FigmaWebViewController(
      tab: tab, websiteDataStore: .nonPersistent(), memory: MemoryLabStore(url: memoryURL),
      fixtureNumber: 1)
    var routes = 0
    controller.onRoute = { _, _ in
      routes += 1
      return nil
    }
    controller.loadViewIfNeeded()
    defer { controller.closeTab() }
    for kind in [WKNavigationType.other, .reload, .backForward] {
      XCTAssertEqual(
        TabNavigationRouter.action(
          home: false, currentURL: tab.routingURL,
          input: .init(destination: SessionState.startURL, kind: kind)), .allow)
    }
    XCTAssertEqual(routes, 0)
    XCTAssertTrue(
      controller.routeNavigation(
        .init(destination: SessionState.startURL),
        from: controller.webView))
    XCTAssertEqual(routes, 1)
  }

  func testSelectedRelatedBrowserIsLaidOutBeforeReturningToWebKit() throws {
    let name = "folio.routing.geometry.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: memoryURL)
    }
    let host = BrowserWindowController(
      session: WindowSession(defaults: defaults, migrateLegacy: false),
      websiteDataStore: .nonPersistent(), memory: MemoryLabStore(url: memoryURL), useFixture: true)
    host.loadViewIfNeeded()
    host.view.frame = CGRect(x: 0, y: 0, width: 1032, height: 1376)
    let source = try XCTUnwrap(host.children.first as? FigmaWebViewController)
    defer { source.closeTab() }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let browser = try XCTUnwrap(
      source.onRoute?(
        URL(string: "https://www.figma.com/design/fixture2")!, configuration))
    let destination = try XCTUnwrap(host.children.first as? FigmaWebViewController)
    defer { destination.closeTab() }
    XCTAssertTrue(destination.webView === browser)
    XCTAssertGreaterThan(browser.bounds.width, 0)
    XCTAssertGreaterThan(browser.bounds.height, 0)
    XCTAssertTrue(browser.isDescendant(of: host.view))
    XCTAssertEqual(
      BrowserResponderFocus.visibility(of: browser),
      "hiddenAncestors=0 axHiddenAncestors=0 modalAncestors=0")
    XCTAssertEqual(host.session.tabs.count, 2)
  }

  func testHomeSPAFileObservationOpensTabAndKeepsHome() {
    let name = "folio.routing.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: memoryURL) }
    let window = WindowSession(defaults: defaults, migrateLegacy: false)
    let host = BrowserWindowController(
      session: window, memory: MemoryLabStore(url: memoryURL), useFixture: true)
    host.loadViewIfNeeded()
    let home = host.children.first as! FigmaWebViewController
    let oldView = home.webView
    XCTAssertTrue(home.handoffObservedURL(URL(string: "https://www.figma.com/design/spa")!))
    XCTAssertTrue(home.webView === oldView)
    XCTAssertEqual(window.tabs.count, 2)
    XCTAssertEqual(window.selected.kind, .document)
    XCTAssertEqual(window.selected.fileKey, "spa")
    XCTAssertFalse(
      home.handoffObservedURL(URL(string: "https://www.figma.com/files/project/local")!))
    XCTAssertEqual(window.tabs.count, 2)
    XCTAssertEqual(window.home.routingURL, SessionState.startURL)
    (host.children.first as? FigmaWebViewController)?.closeTab()
    home.closeTab()
  }
}
