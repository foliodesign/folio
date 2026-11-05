import UIKit
import WebKit
import XCTest

@testable import Folio

@MainActor
final class InterfaceZoomTests: XCTestCase {
  private func withDefaults(_ test: (UserDefaults, URL) throws -> Void) rethrows {
    let name = "folio.interfaceZoom.tests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    let memory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "InterfaceZoom-\(UUID())")
    defer {
      defaults.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: memory)
    }
    try test(defaults, memory)
  }

  func testPreferenceValidationAndRelaunch() {
    withDefaults { defaults, _ in
      XCTAssertEqual(InterfaceZoomStore(defaults: defaults).state.scale, 1)
      for (saved, expected) in [
        (0.1, 0.5), (3.0, 2.0), (1.25, 1.25), (.infinity, 1.0), (.nan, 1.0),
      ] {
        defaults.set(saved, forKey: InterfaceZoomStore.preferenceKey)
        let store = InterfaceZoomStore(defaults: defaults)
        XCTAssertEqual(store.state.scale, expected)
        XCTAssertEqual(defaults.double(forKey: InterfaceZoomStore.preferenceKey), expected)
      }
      defaults.set("1.5", forKey: InterfaceZoomStore.preferenceKey)
      XCTAssertEqual(InterfaceZoomStore(defaults: defaults).state.scale, 1)
      defaults.set(true, forKey: InterfaceZoomStore.preferenceKey)
      XCTAssertEqual(InterfaceZoomStore(defaults: defaults).state.scale, 1)
      let store = InterfaceZoomStore(defaults: defaults)
      store.setScale(1.5)
      store.setScale(.nan)
      store.setScale(-.infinity)
      XCTAssertEqual(store.state.scale, 1.5)
      XCTAssertEqual(InterfaceZoomStore(defaults: defaults).state.scale, 1.5)
      store.setScale(0)
      XCTAssertEqual(store.state.scale, 0.5)
      store.setScale(3)
      XCTAssertEqual(store.state.scale, 2)
    }
  }

  func testDiscreteActionsAndControlState() {
    withDefaults { defaults, _ in
      let store = InterfaceZoomStore(defaults: defaults)
      for preset in InterfaceZoomPreset.allCases {
        store.send(.preset(preset))
        XCTAssertEqual(store.state.percent, preset.title)
      }
      store.send(.decrease)
      XCTAssertEqual(store.state.scale, 1.5)
      store.send(.reset)
      XCTAssertEqual(store.state.scale, 1)
      store.send(.decrease)
      XCTAssertEqual(store.state.scale, 0.8)
      store.send(.decrease)
      store.send(.decrease)
      XCTAssertFalse(store.state.canDecrease)
      store.send(.increase)
      XCTAssertEqual(store.state.scale, 0.75)
      store.setScale(1.1)
      store.send(.increase)
      XCTAssertEqual(store.state.scale, 1.25)
    }
  }

  func testAllMainViewsRelatedConfigurationAndAuthExclusion() {
    withDefaults { defaults, _ in
      let store = InterfaceZoomStore(defaults: defaults)
      let supplied = WKWebViewConfiguration()
      supplied.websiteDataStore = .nonPersistent()
      let first = store.makeMainWebView(configuration: supplied)
      let second = store.makeMainWebView(configuration: WKWebViewConfiguration())
      store.registerMainWebView(first)
      XCTAssertEqual(store.liveMainViewCount, 2)
      XCTAssertTrue(first.configuration.websiteDataStore === supplied.websiteDataStore)
      XCTAssertTrue(first.configuration.userContentController === supplied.userContentController)
      let popup = PopupController(configuration: WKWebViewConfiguration(), url: nil)
      for scale in [0.5, 0.75, 1, 1.25, 1.5, 2] {
        store.setScale(scale)
        XCTAssertEqual(first.transform.a, scale)
        XCTAssertEqual(second.transform.a, scale)
        XCTAssertEqual(popup.browser?.pageZoom, 1)
      }
      let new = store.makeMainWebView(configuration: WKWebViewConfiguration())
      XCTAssertEqual(new.transform.a, 2)
      popup.close()
    }
  }

  func testRegistryReleasesViewsWithoutRetainingStaleEntries() {
    withDefaults { defaults, _ in
      let store = InterfaceZoomStore(defaults: defaults)
      weak var released: WKWebView?
      autoreleasepool {
        let view = store.makeMainWebView(configuration: WKWebViewConfiguration())
        released = view
        XCTAssertEqual(store.liveMainViewCount, 1)
      }
      waitUntil { released == nil }
      XCTAssertNil(released)
      XCTAssertEqual(store.liveMainViewCount, 0)
      store.send(.increase)
    }
  }

  func testPromotedRelatedViewJoinsZoomRegistryWithoutInstrumentingAuth() throws {
    try withDefaults { defaults, memory in
      let store = InterfaceZoomStore(defaults: defaults)
      store.setScale(2)
      let container = InterfaceZoomContainerController(store: store) { factory in
        BrowserWindowController(
          session: WindowSession(defaults: defaults, migrateLegacy: false),
          memory: MemoryLabStore(url: memory), useFixture: true, makeWebView: factory)
      }
      container.loadViewIfNeeded()
      let source = try XCTUnwrap(container.browser.children.first as? FigmaWebViewController)
      let popup = PopupController(
        configuration: WKWebViewConfiguration(), url: URL(string: "about:blank"))
      let child = try XCTUnwrap(popup.browser)
      XCTAssertEqual(child.pageZoom, 1)
      let result = source.onAdoptRelatedBrowser?(
        URL(string: "https://www.figma.com/design/promoted")!, child)
      if case .adopted = result {} else { XCTFail("Related view must be adopted") }
      XCTAssertTrue(
        (container.browser.children.first as? FigmaWebViewController)?.webView === child)
      XCTAssertEqual(child.transform.a, 2)
      XCTAssertEqual(child.configuration.userContentController.userScripts.count, 0)
      store.setScale(0.5)
      XCTAssertEqual(child.transform.a, 0.5)
      popup.close()
    }
  }

  func testZoomDoesNotRequestFirstResponder() {
    withDefaults { defaults, _ in
      let store = InterfaceZoomStore(defaults: defaults)
      let view = InterfaceZoomRecordingWebView(
        frame: .zero, configuration: WKWebViewConfiguration())
      store.registerMainWebView(view)
      for scale in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
        store.setScale(scale)
        store.send(.decrease)
      }
      XCTAssertEqual(view.responderRequests, 0)
    }
  }

  func testHostSelectionRebuildCloseAndSafeKeepZoom() throws {
    try withDefaults { defaults, memory in
      let store = InterfaceZoomStore(defaults: defaults)
      let session = WindowSession(defaults: defaults, migrateLegacy: false)
      let container = InterfaceZoomContainerController(store: store) { factory in
        BrowserWindowController(
          session: session, websiteDataStore: .nonPersistent(),
          memory: MemoryLabStore(url: memory), useFixture: true, makeWebView: factory)
      }
      container.loadViewIfNeeded()
      let host = container.browser
      weak var replaced: WKWebView?
      let controller = try autoreleasepool {
        let first = host.addTab(url: URL(string: "https://www.figma.com/design/zoom1")!)
        let controller = try XCTUnwrap(host.children.first as? FigmaWebViewController)
        var original: WKWebView? = try XCTUnwrap(controller.webView)
        host.addTab(url: URL(string: "https://www.figma.com/design/zoom2")!)
        store.setScale(0.5)
        XCTAssertEqual(original?.transform.a, 0.5)
        XCTAssertEqual((host.children.first as? FigmaWebViewController)?.webView.transform.a, 0.5)
        session.select(first.id)
        host.showSelectedTab()
        XCTAssertTrue((host.children.first as? FigmaWebViewController)?.webView === original)
        store.setScale(2)
        first.session.mode = .safe
        controller.rebuildWebView()
        XCTAssertFalse(controller.webView === original)
        replaced = original
        original = nil
        return controller
      }
      waitUntil { replaced == nil }
      XCTAssertNil(replaced)
      XCTAssertEqual(controller.webView.transform.a, 2)
      XCTAssertEqual(controller.webView.configuration.userContentController.userScripts.count, 0)
      // Test known Safe bridge names in the isolated world, not page contents or credentials.
      let noHandlers: Bool? = evaluate(
        controller.webView,
        "['folio','memoryProgress','folioStandardFileLink'].every(n => !globalThis.webkit?.messageHandlers?.[n])",
        world: ScriptBridge.world)
      XCTAssertEqual(noHandlers, true)
      weak var closed: WKWebView?
      autoreleasepool {
        host.addTab(url: URL(string: "https://www.figma.com/design/zoom3")!)
        closed = (host.children.first as? FigmaWebViewController)?.webView
        XCTAssertEqual(closed?.transform.a, 2)
        host.closeSelectedTab()
      }
      waitUntil { closed == nil }
      XCTAssertNil(closed)
      XCTAssertTrue(container.children.first === host)
      XCTAssertTrue(container.keyCommands?.isEmpty ?? true)
    }
  }

  func testContainerColdWarmDeliveryUsesFullLinkOnce() throws {
    for warm in [false, true] {
      try withDefaults { defaults, memory in
        let store = InterfaceZoomStore(defaults: defaults)
        store.setScale(1.5)
        let session = WindowSession(defaults: defaults, migrateLegacy: false)
        let container = InterfaceZoomContainerController(store: store) { _ in
          BrowserWindowController(
            session: session, websiteDataStore: .nonPersistent(),
            memory: MemoryLabStore(url: memory),
            makeWebView: { configuration in
              let view = InterfaceZoomRecordingWebView(frame: .zero, configuration: configuration)
              store.registerMainWebView(view)
              return view
            })
        }
        if warm { container.loadViewIfNeeded() }
        let url = URL(string: "https://figma.com/design/zoomLink/Transient?node-id=1%3A2#target")!
        let delivery = UUID()
        container.deliver(url, id: delivery)
        container.loadViewIfNeeded()
        container.deliver(url, id: delivery)
        let view = try XCTUnwrap(
          (container.browser.children.first as? FigmaWebViewController)?.webView
            as? InterfaceZoomRecordingWebView)
        XCTAssertEqual(view.requests.map(\.url), [url])
        XCTAssertEqual(session.tabs.count, 2)
        XCTAssertEqual(view.transform.a, 1.5)
        XCTAssertEqual(
          session.selectedID,
          (container.browser.children.first as? FigmaWebViewController)?.tabSession.id)
        // A new OS delivery selects the existing tab without replaying its initial request.
        container.deliver(url, id: UUID())
        XCTAssertEqual(view.requests.map(\.url), [url])
      }
    }
  }

  func testLocalViewportHitCanvasScrollFocusGeometryAtExtremes() throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
    let root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    try withDefaults { defaults, _ in
      let store = InterfaceZoomStore(defaults: defaults)
      let view = store.makeMainWebView(configuration: WKWebViewConfiguration())
      view.frame = root.view.bounds
      view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      root.view.addSubview(view)
      let navigation = NativeNavigationCompletionProbe(view)
      view.loadHTMLString(InterfaceZoomFixture.html, baseURL: nil)
      try navigation.waitSynchronously()
      waitUntil {
        let ready: Bool? = self.evaluate(
          view, "document.readyState === 'complete' && !!document.getElementById('hit')")
        return ready == true
      }
      let seeded: Bool? = evaluate(
        view,
        """
        (() => {
          const note=document.getElementById('note');note.value='local';
          note.focus({preventScroll:true});note.setSelectionRange(1,3);return true;
        })()
        """)
      XCTAssertEqual(seeded, true)
      for scale in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
        store.setScale(scale)
        XCTAssertEqual(view.transform.a, scale)
        settleLayout(view)
        let retained: Bool? = evaluate(
          view,
          """
          (() => {
            const note=document.getElementById('note');
            return document.activeElement===note && note.value==='local' && note.selectionStart===1 && note.selectionEnd===3;
          })()
          """)
        XCTAssertEqual(retained, true)
        let token: String? = evaluate(view, "document.getElementById('token').textContent")
        for id in ["hit", "canvas"] {
          let nativePoint: [String: Double]? = evaluate(
            view,
            """
            (() => {
              const r=document.getElementById('\(id)').getBoundingClientRect(),v=visualViewport;
              return {x:(r.x+r.width/2-(v?.offsetLeft??0))*\(view.bounds.width)/(v?.width??innerWidth),
                y:(r.y+r.height/2-(v?.offsetTop??0))*\(view.bounds.height)/(v?.height??innerHeight)};
            })()
            """)
          let point = try XCTUnwrap(nativePoint)
          let x = try XCTUnwrap(point["x"])
          let y = try XCTUnwrap(point["y"])
          let converted = PinchTransport.cssPoint(CGPoint(x: x, y: y), bounds: view.bounds)
          let hit: Bool? = evaluate(view, "document.elementFromPoint(\(converted))?.id === '\(id)'")
          XCTAssertEqual(hit, true, "Existing viewport conversion at \(scale), \(id)")
        }
        let scrollGeometry: [String: Double]? = evaluate(view, "folioZoomGeometry()")
        let metrics = try XCTUnwrap(scrollGeometry)
        let cssHeight = try XCTUnwrap(metrics["height"])
        let viewportHeight = try XCTUnwrap(metrics["viewportHeight"])
        XCTAssertGreaterThan(viewportHeight, 0)
        let nativeHeight = cssHeight * view.bounds.height / viewportHeight
        XCTAssertGreaterThanOrEqual(nativeHeight, 100, "Native scroll target at \(scale)")
        XCTAssertGreaterThan(
          try XCTUnwrap(metrics["scrollHeight"]), try XCTUnwrap(metrics["clientHeight"]),
          "Fixture must overflow at \(scale)")
        XCTAssertEqual(metrics["starts"], 0, "Programmatic geometry is not native input evidence")
        let attachment = XCTAttachment(
          string:
            "scale=\(scale), bounds=\(view.bounds), rootOffset=\(view.scrollView.contentOffset), rootSize=\(view.scrollView.contentSize), rootZoom=\(view.scrollView.zoomScale), DOM=\(metrics)"
        )
        attachment.name = "Zoom native and DOM scroll geometry"
        attachment.lifetime = .keepAlways
        add(attachment)
        let geometry: Bool? = evaluate(
          view,
          """
          (() => {
            const panel=document.getElementById('scroll');panel.scrollTop=100;
            const r=panel.getBoundingClientRect();
            document.getElementById('note').focus({preventScroll:true});
            return panel.scrollTop===100 && r.height>0 && document.activeElement.id==='note';
          })()
          """)
        XCTAssertEqual(geometry, true, "Local scroll/focus geometry at \(scale)")
        waitUntil {
          let count: String? = self.evaluate(
            view, "document.getElementById('scrolled').textContent")
          return count == "Scroll 100"
        }
        // Reproduce the post-edit preset round trip and End editing boundary.
        // This is DOM/viewport evidence only; the UI cases still require native dragging.
        store.setScale(1)
        store.setScale(scale)
        settleLayout(view)
        let ended: Bool? = evaluate(
          view,
          """
          document.getElementById('blur').click();
          document.activeElement !== document.getElementById('note')
          """)
        XCTAssertEqual(ended, true)
        settleLayout(view)
        let postEdit: [String: Double]? = evaluate(view, "folioZoomGeometry()")
        let postMetrics = try XCTUnwrap(postEdit)
        XCTAssertEqual(postMetrics["activeNote"], 0)
        XCTAssertEqual(postMetrics["centerInPanel"], 1, "Post-edit panel hit at \(scale)")
        XCTAssertEqual(postMetrics["scrollTop"], 100, "Editing must preserve panel offset")
        let evidence = XCTAttachment(
          string:
            "post-edit scale=\(scale), bounds=\(view.bounds), rootOffset=\(view.scrollView.contentOffset), rootSize=\(view.scrollView.contentSize), rootZoom=\(view.scrollView.zoomScale), DOM=\(postMetrics)\n\(gestureAttachments(view))"
        )
        evidence.name = "Zoom post-edit viewport and native gesture attachments"
        evidence.lifetime = .keepAlways
        add(evidence)
        let retainedNote: String? = evaluate(view, "document.getElementById('note').value")
        XCTAssertEqual(retainedNote, "local")
        let refocused: Bool? = evaluate(
          view,
          "document.getElementById('note').focus({preventScroll:true}); document.activeElement.id==='note'"
        )
        XCTAssertEqual(refocused, true)
        let after: String? = evaluate(view, "document.getElementById('token').textContent")
        XCTAssertEqual(token, after)
      }
    }
  }

  // Observe public recognizer properties without changing native delivery policy.
  private func gestureAttachments(_ view: UIView, depth: Int = 0) -> String {
    let attached = (view.gestureRecognizers ?? []).map { gesture in
      var details =
        "\(type(of: gesture)) enabled=\(gesture.isEnabled) state=\(gesture.state.rawValue) touches=\(gesture.allowedTouchTypes) cancels=\(gesture.cancelsTouchesInView)"
      if let pan = gesture as? UIPanGestureRecognizer {
        details += " min=\(pan.minimumNumberOfTouches) max=\(pan.maximumNumberOfTouches)"
      }
      return details
    }.joined(separator: "; ")
    let line =
      "\(String(repeating: " ", count: depth))\(type(of: view)) frame=\(view.frame) gestures=[\(attached)]"
    return ([line] + view.subviews.map { gestureAttachments($0, depth: depth + 1) })
      .joined(separator: "\n")
  }

  private func settleLayout(_ view: WKWebView) {
    var done = false
    view.callAsyncJavaScript(
      "await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame); return true",
      arguments: [:], in: nil, in: .page
    ) { result in
      if case .failure(let error) = result { XCTFail("Local layout wait failed: \(error)") }
      done = true
    }
    waitUntil { done }
  }

  private func evaluate<T>(_ view: WKWebView, _ script: String, world: WKContentWorld = .page) -> T?
  {
    var value: T?
    var done = false
    view.evaluateJavaScript(script, in: nil, in: world) { result in
      switch result {
      case .success(let returned): value = returned as? T
      case .failure(let error): XCTFail("Local fixture JS failed: \(error)")
      }
      done = true
    }
    waitUntil { done }
    return value
  }

  private func waitUntil(_ predicate: () -> Bool) {
    let end = Date().addingTimeInterval(5)
    while !predicate() && Date() < end {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(predicate(), "Bounded native fixture wait")
  }
}

@MainActor
private final class InterfaceZoomRecordingWebView: WKWebView {
  private(set) var requests: [URLRequest] = []
  private(set) var responderRequests = 0
  override func becomeFirstResponder() -> Bool {
    responderRequests += 1
    return false
  }
  override func load(_ request: URLRequest) -> WKNavigation? {
    requests.append(request)
    return nil
  }
}
