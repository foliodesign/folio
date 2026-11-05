import WebKit
import XCTest

@testable import Folio

@MainActor
final class B3BrowserTests: XCTestCase {
  func testPinCloseOthersAndHomeInvariants() {
    let name = "folio.b3.model.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let window = WindowSession(defaults: defaults, migrateLegacy: false)
    let first = window.add(url: URL(string: "https://www.figma.com/design/first")!)
    let second = window.add(url: URL(string: "https://www.figma.com/design/second")!)
    window.togglePin(first.id)
    XCTAssertTrue(first.isPinned)
    window.togglePin(first.id)
    XCTAssertFalse(first.isPinned)
    window.togglePin(window.home.id)
    XCTAssertTrue(window.home.isPinned)
    XCTAssertFalse(window.close(window.home.id))
    XCTAssertEqual(window.closeOthers(keeping: first.id), [second.id])
    XCTAssertEqual(window.selectedID, first.id)
    XCTAssertEqual(window.tabs.map(\.id), [window.home.id, first.id])
    XCTAssertTrue(window.close(first.id))
    XCTAssertEqual(window.selectedID, window.home.id)
  }

  func testHomeInterceptsOrdinaryGETButDocumentsRetainRedirectPostSubframeDownload() {
    let file = URL(string: "https://www.figma.com/design/file")!
    for kind in [WKNavigationType.other, .reload, .backForward] {
      XCTAssertEqual(
        TabNavigationRouter.action(
          home: true, currentURL: SessionState.startURL,
          input: .init(destination: file, kind: kind)), .openFile)
      XCTAssertEqual(
        TabNavigationRouter.action(
          home: false, currentURL: file,
          input: .init(destination: file, kind: kind)), .allow)
    }
    for kind in [WKNavigationType.formSubmitted, .formResubmitted] {
      XCTAssertEqual(
        TabNavigationRouter.action(
          home: true, currentURL: SessionState.startURL,
          input: .init(destination: file, kind: kind)), .allow)
    }
    for input in [
      TabNavigationRouter.Input(destination: file, mainFrame: false),
      .init(destination: file, method: "POST"), .init(destination: file, download: true),
    ] {
      XCTAssertEqual(
        TabNavigationRouter.action(
          home: true, currentURL: SessionState.startURL,
          input: input), .allow)
    }
    for input in [
      TabNavigationRouter.Input(destination: file, modifiers: .command),
      .init(destination: file, button: .init(rawValue: 1 << 2)),
    ] {
      XCTAssertEqual(
        TabNavigationRouter.action(home: false, currentURL: file, input: input), .openFile)
    }
    XCTAssertEqual(
      TabNavigationRouter.action(
        home: true, currentURL: SessionState.startURL,
        input: .init(destination: URL(string: "https://www.figma.com/files/project/test")!)), .allow
    )
  }

  func testActualWebKitLinkRoutesOnceAndPreservesSourceView() async throws {
    let name = "folio.b3.actual.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: memoryURL)
    }
    let controller = FigmaWebViewController(
      tab: TabSession(
        kind: .home,
        url: SessionState.startURL, defaults: defaults), websiteDataStore: .nonPersistent(),
      memory: MemoryLabStore(url: memoryURL), fixtureNumber: 0)
    let routed = expectation(description: "Actual local link action")
    var count = 0
    controller.onRoute = { url, configuration in
      count += 1
      XCTAssertEqual(url.path, "/design/fixture1")
      XCTAssertNil(configuration)
      routed.fulfill()
      return nil
    }
    controller.loadViewIfNeeded()
    let browser = controller.webView!
    let navigation = NativeNavigationCompletionProbe(browser)
    defer { controller.closeTab() }
    try await navigation.wait()
    try await NativeStateExpectation.wait("Fixture title") {
      browser.title == "Local document 0 – Figma"
    }
    _ = try await browser.callAsyncJavaScript(
      """
      if (document.readyState !== 'complete') {
        await new Promise(resolve => window.addEventListener('load', resolve, {once:true}));
      }
      document.querySelector('a').click(); return true;
      """, arguments: [:], in: nil, contentWorld: .page)
    await fulfillment(of: [routed], timeout: 5)
    XCTAssertEqual(count, 1)
    XCTAssertTrue(controller.webView === browser)
  }

  #if DEBUG
    func testStopBeforeDeadlineReturnsBoundedWheelAndNumericZoomSamples() async throws {
      let scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let previous = scene.windows.first { $0.isKeyWindow }
      let window = UIWindow(windowScene: scene)
      let root = UIViewController()
      window.rootViewController = root
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
      }
      let browser = WKWebView()
      browser.frame = root.view.bounds
      root.view.addSubview(browser)
      let navigation = NativeNavigationCompletionProbe(browser)
      browser.loadHTMLString(
        "<title>Folio automation (safe to delete)</title><button aria-label='zoom'>100%</button>",
        baseURL: URL(string: "https://www.figma.com/design/b3local")!)
      // Wait for a returned document, not a fabricated framework navigation action.
      try await navigation.wait()
      try await NativeStateExpectation.wait("Fixture title") {
        browser.title == PinchReplayHarness.scratchName
      }
      XCTAssertEqual(browser.title, PinchReplayHarness.scratchName)
      let hidden = try await browser.evaluateJavaScript("document.hidden")
      print("B3 local Stop fixture document.hidden=\(String(describing: hidden))")
      let pinch = TrackpadPinch()
      let transport = PinchTransport { _, done in done() }
      let harness = PinchReplayHarness(
        webView: browser, trackpad: pinch, transport: transport,
        allowed: { true })
      let complete = expectation(description: "Stop snapshot returned")
      var nativeSaved = false
      harness.onSave = { trace in
        if trace.response == nil {
          nativeSaved = true
          return
        }
        XCTAssertTrue(nativeSaved)
        XCTAssertEqual(trace.liftTimes.count, 1)
        XCTAssertEqual(trace.callbacks.last?.state, UIGestureRecognizer.State.cancelled.rawValue)
        let data = Data(trace.response!.utf8)
        struct Response: Decodable {
          struct Event: Decodable { let dy: Double? }
          struct Sample: Decodable { let zoom: Double? }
          let events: [Event]
          let samples: [Sample]
        }
        let response = try? JSONDecoder().decode(Response.self, from: data)
        XCTAssertNotNil(response, "Returned Stop snapshot: \(trace.response!)")
        XCTAssertFalse(
          response?.events.isEmpty ?? true, "Returned Stop snapshot: \(trace.response!)")
        XCTAssertFalse(
          response?.samples.isEmpty ?? true, "Returned Stop snapshot: \(trace.response!)")
        XCTAssertEqual(response?.events.first?.dy, -5)
        XCTAssertEqual(response?.samples.first?.zoom, 100)
        XCTAssertLessThanOrEqual(response?.events.count ?? 5000, 4096)
        XCTAssertLessThanOrEqual(response?.samples.count ?? 5000, 4096)
        complete.fulfill()
      }
      harness.recordCallbacks(replay: false)
      try await NativeStateExpectation.wait("Recorder installed") { pinch.onCallback != nil }
      XCTAssertNotNil(pinch.onCallback)
      _ = try await browser.evaluateJavaScript(
        "window.dispatchEvent(new WheelEvent('wheel', {ctrlKey:true, deltaY:-5})); 'sampled'",
        in: nil, contentWorld: ScriptBridge.world)
      pinch.onCallback?(
        PinchCallbackSample(
          time: 1, state: UIGestureRecognizer.State.cancelled.rawValue,
          scale: 1, velocity: 0, eventType: UIEvent.EventType.transform.rawValue, location: .zero))
      harness.markLift()
      harness.cancel()
      XCTAssertTrue(nativeSaved, "Native partial save must precede the async WebKit reply")
      await fulfillment(of: [complete], timeout: 5)
      harness.uninstall()
      browser.stopLoading()
    }
  #endif
}

extension B3BrowserTests {
  func testRelatedAdoptionRetainsIdentityAndStaysScriptFreeUntilRebuild() throws {
    let name = "folio.b3.adoption.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: memoryURL)
    }
    let session = WindowSession(defaults: defaults, migrateLegacy: false)
    var factoryCalls = 0
    let host = BrowserWindowController(
      session: session, memory: MemoryLabStore(url: memoryURL),
      useFixture: true,
      makeWebView: {
        factoryCalls += 1
        return WKWebView(frame: .zero, configuration: $0)
      })
    host.loadViewIfNeeded()
    let source = try XCTUnwrap(host.children.first as? FigmaWebViewController)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let child = WKWebView(frame: .zero, configuration: configuration)
    let result = source.onAdoptRelatedBrowser?(
      URL(string: "https://www.figma.com/design/adopted")!, child)
    if case .adopted = result {} else { XCTFail("Related view must be adopted") }
    let destination = try XCTUnwrap(host.children.first as? FigmaWebViewController)
    XCTAssertTrue(destination.webView === child)
    XCTAssertEqual(factoryCalls, 1, "Adoption cannot create/replay an unrelated destination")
    XCTAssertTrue(child.configuration.userContentController.userScripts.isEmpty)
    XCTAssertEqual(session.tabs.count, 2)
    XCTAssertEqual(session.selectedID, destination.tabSession.id)
    destination.rebuildWebView()
    XCTAssertEqual(factoryCalls, 2, "All rebuilt main views retain the injected factory")
    XCTAssertFalse(destination.webView === child)
    destination.closeTab()
    source.closeTab()
  }

  func testActualBlankChildNavigationSelectsExistingWithoutReplay() async throws {
    let popup = PopupController(
      configuration: WKWebViewConfiguration(), url: URL(string: "about:blank"))
    let browser = try XCTUnwrap(popup.browser)
    let promotion = expectation(description: "Actual main-frame child link")
    var deliveries = 0
    popup.onPromote = { url, child in
      deliveries += 1
      XCTAssertTrue(child === browser)
      XCTAssertEqual(url.path, "/design/existing")
      promotion.fulfill()
      return .selectedExisting
    }
    let navigation = NativeNavigationCompletionProbe(browser)
    browser.loadHTMLString(
      "<title>Local blank child</title><a href='https://www.figma.com/design/existing'>Local link</a>",
      baseURL: URL(string: "https://www.figma.com/files")!)
    try await navigation.wait()
    try await NativeStateExpectation.wait("Fixture title") { browser.title == "Local blank child" }
    _ = try await browser.callAsyncJavaScript(
      """
      if (document.readyState !== 'complete') {
        await new Promise(resolve => window.addEventListener('load', resolve, {once:true}));
      }
      document.querySelector('a').click(); return true;
      """, arguments: [:], in: nil, contentWorld: .page)
    await fulfillment(of: [promotion], timeout: 5)
    XCTAssertEqual(deliveries, 1)
    XCTAssertNil(popup.browser)
    XCTAssertNil(browser.navigationDelegate)
    popup.close()
  }
}

#if DEBUG
  extension B3BrowserTests {
    func testRecorderRejectsRevokedSourceAndRebuildWithoutBrowserSnapshot() async throws {
      for reason in ["Safe", "background", "tab", "navigation", "rebuild"] {
        let browser = WKWebView()
        let navigation = NativeNavigationCompletionProbe(browser)
        browser.loadHTMLString(
          "<title>Folio automation (safe to delete)</title>",
          baseURL: URL(string: "https://www.figma.com/design/b3local")!)
        try await navigation.wait()
        try await NativeStateExpectation.wait("Fixture title") {
          browser.title == PinchReplayHarness.scratchName
        }
        var authorized = true
        let pinch = TrackpadPinch()
        let harness = PinchReplayHarness(
          webView: browser, trackpad: pinch,
          transport: PinchTransport { _, done in done() }, allowed: { authorized })
        var saves = 0
        harness.onSave = { trace in
          saves += 1
          XCTAssertNil(trace.response, reason)
        }
        harness.recordCallbacks(replay: false)
        try await NativeStateExpectation.wait("Recorder installed") { pinch.onCallback != nil }
        XCTAssertNotNil(pinch.onCallback, reason)
        authorized = false
        if reason == "rebuild" { harness.uninstall() } else { harness.cancel() }
        XCTAssertEqual(saves, 1, "Synchronous native partial save: \(reason)")
        XCTAssertNil(pinch.onCallback)
        do {
          _ = try await harness.evaluate("'must-not-evaluate'")
          XCTFail("Revoked source accepted evaluation: \(reason)")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.userCancelled.rawValue) }
        // A WebKit reply is a queue barrier for the cancelled observer evaluation.
        _ = try await browser.evaluateJavaScript("true", in: nil, contentWorld: ScriptBridge.world)
        XCTAssertEqual(saves, 1, "No late browser enrichment after revocation: \(reason)")
        harness.uninstall()
        browser.stopLoading()
      }
    }
  }
#endif

extension B3BrowserTests {
  func testActualWindowOpenPreservesOpenerMessagingAndNoopenerIsolation() async throws {
    for noopener in [false, true] {
      let name = "folio.b3.opener.\(UUID())"
      let defaults = UserDefaults(suiteName: name)!
      let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: memoryURL)
      }
      let source = FigmaWebViewController(
        tab: TabSession(
          kind: .home,
          url: SessionState.startURL, defaults: defaults), websiteDataStore: .nonPersistent(),
        memory: MemoryLabStore(url: memoryURL), fixtureNumber: 0)
      source.loadViewIfNeeded()
      defer { source.closeTab() }
      let browser = source.webView!
      let navigation = NativeNavigationCompletionProbe(browser)
      browser.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
      try await navigation.wait()
      try await NativeStateExpectation.wait("Fixture title") {
        browser.title == "Local document 0 – Figma"
      }
      _ = try await browser.callAsyncJavaScript(
        """
        if (document.readyState !== 'complete') {
          await new Promise(resolve => window.addEventListener('load', resolve, {once:true}));
        }
        globalThis.b3Message = new Promise(resolve => {
          window.addEventListener('message', e => { if (e.data === 'b3-local') resolve(true); }, {once:true});
        });
        window.open('about:blank', '_blank', '\(noopener ? "noopener" : "")'); return true;
        """, arguments: [:], in: nil, contentWorld: .page)
      try await NativeStateExpectation.wait("Popup browser created") {
        source.popup?.browser != nil
      }
      let popup = try XCTUnwrap(source.popup)
      let child = try XCTUnwrap(popup.browser)
      XCTAssertTrue(child.configuration.userContentController.userScripts.isEmpty)
      let hasOpener = try await child.evaluateJavaScript("window.opener !== null") as? Bool
      XCTAssertEqual(hasOpener, !noopener)
      if !noopener {
        _ = try await child.evaluateJavaScript("window.opener.postMessage('b3-local','*'); true")
        let received =
          try await browser.callAsyncJavaScript(
            """
            return await Promise.race([
              globalThis.b3Message,
              new Promise(resolve => setTimeout(() => resolve(false), 1000))
            ]);
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(received, true)
      }
      _ = try? await child.evaluateJavaScript("window.close(); true")
      try await NativeStateExpectation.wait("Popup closed") { source.popup == nil }
      XCTAssertNil(source.popup)
      XCTAssertTrue(source.webView === browser)
    }
  }
}
