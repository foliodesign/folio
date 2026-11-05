import UIKit
import WebKit
import XCTest

@testable import Folio

@MainActor
final class KeyboardFocusTests: XCTestCase {
  private final class FocusView: UIView {
    var hasResponder = false
    var requests = 0
    override var isFirstResponder: Bool { hasResponder }
    override func becomeFirstResponder() -> Bool {
      requests += 1
      return true
    }
  }

  func testReadinessSeparatesOuterBrowserFromHiddenContentAndNativeText() {
    let browser = FocusView()
    let sink = FocusView()
    sink.isHidden = true
    browser.addSubview(sink)
    XCTAssertEqual(BrowserResponderFocus.ownership(nil, browser: browser), .none)
    XCTAssertEqual(BrowserResponderFocus.ownership(browser, browser: browser), .browser)
    XCTAssertEqual(BrowserResponderFocus.ownership(sink, browser: browser), .content)
    XCTAssertEqual(BrowserResponderFocus.ownership(UITextField(), browser: browser), .nativeText)
    XCTAssertEqual(BrowserResponderFocus.ownership(UIButton(), browser: browser), .other)
    XCTAssertEqual(browser.requests, 0)
    XCTAssertEqual(sink.requests, 0)
  }

  func testNativeHitEvidenceDetectsOverlayAndRejectsDetachedBrowser() {
    let root = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    let browser = UIView(frame: CGRect(x: 0, y: 100, width: 400, height: 500))
    let content = UIView(frame: browser.bounds)
    root.addSubview(browser)
    browser.addSubview(content)
    let point = CGPoint(x: 80, y: 205)
    XCTAssertEqual(
      BrowserResponderFocus.hitOwner(at: point, browser: browser, root: root), "browser")
    let overlay = UIView(frame: CGRect(x: 0, y: 100, width: 400, height: 500))
    root.addSubview(overlay)
    XCTAssertEqual(
      BrowserResponderFocus.hitOwner(at: point, browser: browser, root: root), "native")
    overlay.isUserInteractionEnabled = false
    XCTAssertEqual(
      BrowserResponderFocus.hitOwner(at: point, browser: browser, root: root), "browser")
    browser.removeFromSuperview()
    XCTAssertEqual(
      BrowserResponderFocus.hitOwner(at: point, browser: browser, root: root), "unattached")
  }

  #if DEBUG
    func testReadinessCanBeReadWithoutRequestingFocusOrTappingChrome() {
      let button = BrowserReadinessButton(type: .system)
      let browser = FocusView()
      var connected = false
      button.readiness = {
        "externalKeyboard=\(connected) responder=\(BrowserResponderFocus.ownership(browser, browser: browser).rawValue)"
      }
      XCTAssertEqual(button.accessibilityValue, "externalKeyboard=false responder=browser")
      connected = true
      XCTAssertEqual(button.accessibilityValue, "externalKeyboard=true responder=browser")
      XCTAssertEqual(browser.requests, 0)
    }
  #endif

  func testExistingBrowserSinkIsNotRefocused() {
    let root = UIView()
    let browser = FocusView()
    let sink = FocusView()
    sink.hasResponder = true
    sink.isHidden = true
    root.addSubview(browser)
    browser.addSubview(sink)
    XCTAssertTrue(BrowserResponderFocus.restore(browser, in: root))
    XCTAssertEqual(browser.requests, 0)
    XCTAssertEqual(sink.requests, 0)
  }

  func testOuterBrowserResponderDoesNotProveContentReadiness() {
    let root = UIView()
    let browser = FocusView()
    browser.hasResponder = true
    root.addSubview(browser)
    XCTAssertTrue(BrowserResponderFocus.restore(browser, in: root))
    XCTAssertEqual(browser.requests, 1)
  }

  func testMissingResponderIsRestoredOnce() {
    let root = UIView()
    let browser = FocusView()
    root.addSubview(browser)
    XCTAssertTrue(BrowserResponderFocus.restore(browser, in: root))
    XCTAssertEqual(browser.requests, 1)
  }

  private final class FocusField: UITextField {
    override var isFirstResponder: Bool { true }
  }

  func testNativeTextFieldKeepsResponderAndUndoManager() {
    let root = UIView()
    let browser = FocusView()
    let field = FocusField()
    root.addSubview(browser)
    root.addSubview(field)
    let undo = field.undoManager
    XCTAssertFalse(BrowserResponderFocus.restore(browser, in: root))
    XCTAssertEqual(browser.requests, 0)
    XCTAssertTrue(field.undoManager === undo)
  }

  func testInitialFocusWaitsForNonzeroGeometryAndLayoutRetryConsumesItOnce() {
    var initial = InitialBrowserFocus()
    var state = BrowserFocusGuard(
      active: true, foreground: true, attached: true, popup: false, presentation: false,
      geometryReady: false)
    var requests = 0
    initial.request(guard: state) {
      requests += 1
      return true
    }
    XCTAssertTrue(initial.pending)
    XCTAssertEqual(requests, 0)
    state.geometryReady = true
    initial.request(guard: state) {
      requests += 1
      return true
    }
    initial.request(guard: state) {
      requests += 1
      return true
    }
    XCTAssertEqual(requests, 1)
    XCTAssertFalse(initial.pending)
  }

  func testNativeReadinessIncludesHiddenAndModalAncestorEvidence() {
    let root = UIView()
    let parent = UIView()
    let browser = FocusView()
    root.addSubview(parent)
    parent.addSubview(browser)
    XCTAssertEqual(
      BrowserResponderFocus.visibility(of: browser),
      "hiddenAncestors=0 axHiddenAncestors=0 modalAncestors=0")
    parent.isHidden = true
    parent.accessibilityElementsHidden = true
    root.accessibilityViewIsModal = true
    XCTAssertEqual(
      BrowserResponderFocus.visibility(of: browser),
      "hiddenAncestors=1 axHiddenAncestors=1 modalAncestors=1")
    XCTAssertEqual(browser.requests, 0)
  }

  func testInitialRequestSurvivesInactiveSceneAndFailedFocusUntilSuccess() {
    var initial = InitialBrowserFocus()
    var state = BrowserFocusGuard(
      active: true, foreground: false, attached: false, popup: false, presentation: false)
    var attempts = 0
    initial.request(guard: state) {
      attempts += 1
      return true
    }
    XCTAssertTrue(initial.pending)
    state.foreground = true
    initial.request(guard: state) {
      attempts += 1
      return true
    }
    XCTAssertTrue(initial.pending)
    state.attached = true
    initial.request(guard: state) {
      attempts += 1
      return false
    }
    XCTAssertTrue(initial.pending)
    initial.request(guard: state) {
      attempts += 1
      return true
    }
    XCTAssertFalse(initial.pending)
    initial.request(guard: state) {
      attempts += 1
      return true
    }
    XCTAssertEqual(attempts, 2)
    initial.begin()
    initial.cancel()
    initial.request(guard: state) {
      XCTFail("Switched-away request")
      return true
    }
  }

  func testSafeModeRebuildHasNoUserScriptsIncludingStandardLinkRouting() throws {
    let name = "folio.safe.focus.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: memoryURL)
    }
    let tab = TabSession(kind: .document, url: SessionState.startURL, defaults: defaults)
    tab.session.mode = .safe
    let controller = FigmaWebViewController(
      tab: tab, websiteDataStore: .nonPersistent(), memory: MemoryLabStore(url: memoryURL),
      fixtureNumber: 1)
    controller.onRoute = { _, _ in
      XCTFail("Safe script handoff")
      return nil
    }
    controller.loadViewIfNeeded()
    defer { controller.closeTab() }
    XCTAssertTrue(controller.webView.configuration.userContentController.userScripts.isEmpty)
    controller.routeStandardFileLink(
      URL(string: "https://www.figma.com/design/safe")!, from: controller.webView, mainFrame: true)
  }

  #if DEBUG
    func testPinchRebuildReplacesControlsExactlyOnceAndUninstallBlocksEvaluation() throws {
      let name = "folio.pinch.lifecycle.\(UUID())"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
      let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: memoryURL)
      }
      let tab = TabSession(kind: .document, url: SessionState.startURL, defaults: defaults)
      let controller = FigmaWebViewController(
        tab: tab, websiteDataStore: .nonPersistent(), memory: MemoryLabStore(url: memoryURL),
        fixtureNumber: 1, enablePinchHarness: true)
      controller.loadViewIfNeeded()
      defer { controller.closeTab() }
      func buttons(_ root: UIView) -> [UIButton] {
        (root as? UIButton).map { [$0] } ?? root.subviews.flatMap(buttons)
      }
      let old = try XCTUnwrap(
        buttons(controller.view).first { $0.accessibilityIdentifier == "pinch-record-real" })
      let oldBrowser = controller.webView
      let oldHarness = try XCTUnwrap(controller.pinchHarness)
      XCTAssertTrue(oldHarness.isBound(to: controller.webView))
      for mode in [BrowserMode.safe, .normal, .compatibility, .normal] {
        tab.session.mode = mode
        controller.rebuildWebView()
        XCTAssertEqual(
          buttons(controller.view).filter { $0.accessibilityIdentifier == "pinch-record-real" }
            .count,
          1)
        XCTAssertNil(old.window)
        XCTAssertNil(old.superview?.superview)
        XCTAssertFalse(controller.webView === oldBrowser)
        XCTAssertTrue(controller.pinchHarness?.isBound(to: controller.webView) == true)
        XCTAssertFalse(oldHarness.isBound(to: controller.webView))
        assertRecorderEvaluationBlocked(oldHarness)

      }
      // An obsolete binding cannot run cleanup/evaluation even if its allowed closure says yes.
      let harness = PinchReplayHarness(
        webView: controller.webView, trackpad: TrackpadPinch(),
        transport: PinchTransport { _, done in done() }, allowed: { true })
      harness.install(in: controller.view)
      harness.uninstall()
      assertRecorderEvaluationBlocked(harness)
    }
    private func assertRecorderEvaluationBlocked(_ harness: PinchReplayHarness) {
      let blocked = expectation(description: "Obsolete recorder rejects script evaluation")
      Task { @MainActor in
        do {
          _ = try await harness.evaluate("'stale cleanup must not run'")
          XCTFail("Replaced/uninstalled recorder evaluated a script")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.userCancelled.rawValue) }
        blocked.fulfill()
      }
      wait(for: [blocked], timeout: 5)
    }
  #endif

  func testForegroundRequestRetriesSuppressedColdLaunchWithoutDuplicateFocus() {
    let restoration = KeyboardFocusRestoration()
    var state = BrowserFocusGuard(
      active: true, foreground: false, attached: true,
      popup: false, presentation: false)
    var calls = 0
    restoration.request(
      enabled: true, guard: state, focus: { calls += 1 }, enqueue: { _ in }, retry: {})
    XCTAssertEqual(calls, 0)
    // UIScene.didActivateNotification reissues the selected controller's request.
    state.foreground = true
    restoration.request(
      enabled: true, guard: state, focus: { calls += 1 }, enqueue: { _ in }, retry: {})
    XCTAssertEqual(calls, 1)
  }

  func testEveryGuardCombinationAndBoundedRetry() {
    for bits in 0..<32 {
      let state = BrowserFocusGuard(
        active: bits & 1 != 0, foreground: bits & 2 != 0,
        attached: bits & 4 != 0, popup: bits & 8 != 0, presentation: bits & 16 != 0)
      let restoration = KeyboardFocusRestoration()
      var focused = 0
      var queue: [@MainActor () -> Void] = []
      var retries = 0
      for _ in 0..<2 {
        restoration.request(
          enabled: true, guard: state, focus: { focused += 1 },
          enqueue: { queue.append($0) }, retry: { retries += 1 })
      }
      XCTAssertEqual(focused, state.eligible ? 2 : 0)
      XCTAssertEqual(queue.count, state.mayRetryContainment ? 1 : 0)
      for work in queue { work() }
      XCTAssertEqual(retries, state.mayRetryContainment ? 1 : 0)
    }
  }
  func testLifecycleInvalidationCancelsQueuedRestoration() {
    let restoration = KeyboardFocusRestoration()
    let state = BrowserFocusGuard(
      active: true, foreground: true, attached: false,
      popup: false, presentation: false)
    for _ in ["rebuild", "switch", "background", "sheet", "popup", "navigation"] {
      var queue: [@MainActor () -> Void] = []
      var requests = 0
      restoration.request(
        enabled: true, guard: state, focus: { requests += 1 }, enqueue: { queue.append($0) },
        retry: { requests += 1 })
      restoration.invalidate()
      for work in queue { work() }
      XCTAssertEqual(requests, 0)
    }
  }
  func testB2InputOldRetryCannotConsumeNewEpochRetry() {
    let restoration = KeyboardFocusRestoration()
    let detached = BrowserFocusGuard(
      active: true, foreground: true, attached: false, popup: false, presentation: false)
    var queue: [@MainActor () -> Void] = []
    var retries: [Int] = []
    restoration.request(
      enabled: true, guard: detached, focus: { XCTFail("Detached focus") },
      enqueue: { queue.append($0) },
      retry: { retries.append(1) })
    restoration.invalidate()
    restoration.request(
      enabled: true, guard: detached, focus: { XCTFail("Detached focus") },
      enqueue: { queue.append($0) },
      retry: { retries.append(2) })
    XCTAssertEqual(queue.count, 2)
    queue[0]()
    XCTAssertTrue(retries.isEmpty)
    // Old work must not clear the new request's pending flag.
    restoration.request(
      enabled: true, guard: detached, focus: { XCTFail("Detached focus") },
      enqueue: { queue.append($0) },
      retry: { retries.append(3) })
    XCTAssertEqual(queue.count, 2)
    queue[1]()
    XCTAssertEqual(retries, [2])
  }

  func testB2InputAttachedFocusSupersedesPendingRetry() {
    let restoration = KeyboardFocusRestoration()
    var state = BrowserFocusGuard(
      active: true, foreground: true, attached: false, popup: false, presentation: false)
    var queue: [@MainActor () -> Void] = []
    var focused = 0
    restoration.request(
      enabled: true, guard: state, focus: { XCTFail("Detached focus") },
      enqueue: { queue.append($0) },
      retry: { XCTFail("Superseded retry") })
    state.attached = true
    restoration.request(
      enabled: true, guard: state, focus: { focused += 1 }, enqueue: { queue.append($0) },
      retry: { XCTFail("Unexpected retry") })
    queue[0]()
    XCTAssertEqual(focused, 1)
  }

  func testB2InputReleasedHelperRejectsLateRetry() {
    var restoration: KeyboardFocusRestoration? = KeyboardFocusRestoration()
    weak var released = restoration
    var queue: [@MainActor () -> Void] = []
    restoration?.request(
      enabled: true,
      guard: BrowserFocusGuard(
        active: true, foreground: true, attached: false, popup: false, presentation: false),
      focus: { XCTFail("Detached focus") }, enqueue: { queue.append($0) },
      retry: { XCTFail("Released helper retried") })
    restoration = nil
    XCTAssertNil(released)
    XCTAssertEqual(queue.count, 1)
    queue[0]()
  }

  func testDisabledRestorationNeverStartsInputSessionAndCancelsPendingRetry() {
    let restoration = KeyboardFocusRestoration()
    var queue: [@MainActor () -> Void] = []
    var mutations = 0
    restoration.request(
      enabled: true,
      guard: BrowserFocusGuard(
        active: true, foreground: true, attached: false,
        popup: false, presentation: false),
      focus: { mutations += 1 }, enqueue: { queue.append($0) }, retry: { mutations += 1 })
    restoration.request(
      enabled: false,
      guard: BrowserFocusGuard(
        active: true, foreground: true, attached: true,
        popup: false, presentation: false),
      focus: { mutations += 1 }, enqueue: { queue.append($0) }, retry: { mutations += 1 })
    for work in queue { work() }
    XCTAssertEqual(mutations, 0)
  }

  func testColdFocusWaitsForSceneAndAttachmentThenRunsOnce() {
    var initial = InitialBrowserFocus()
    var starts = 0
    let focus = {
      starts += 1
      return true
    }
    initial.request(
      guard: BrowserFocusGuard(
        active: true, foreground: false, attached: true,
        popup: false, presentation: false), focus: focus)
    XCTAssertTrue(initial.pending)
    XCTAssertEqual(starts, 0)
    initial.request(
      guard: BrowserFocusGuard(
        active: true, foreground: true, attached: false,
        popup: false, presentation: false), focus: focus)
    XCTAssertTrue(initial.pending)
    let ready = BrowserFocusGuard(
      active: true, foreground: true, attached: true,
      popup: false, presentation: false)
    initial.request(
      guard: ready,
      focus: {
        starts += 1
        return false
      })
    XCTAssertTrue(initial.pending)
    initial.request(guard: ready, focus: focus)
    initial.request(guard: ready, focus: focus)
    XCTAssertEqual(starts, 2)
    XCTAssertFalse(initial.pending)
    initial.begin()
    initial.cancel()
    initial.request(guard: ready, focus: focus)
    XCTAssertEqual(starts, 2)
  }

  func testDismissalCompletionIsDeduplicated() {
    let panel = DeveloperToolsController(store: DiagnosticsStore(session: SessionState()))
    var completions = 0
    panel.onDismiss = { completions += 1 }
    panel.completeDismissal()
    panel.completeDismissal()
    XCTAssertEqual(completions, 1)
    XCTAssertNil(panel.onDismiss)
  }
  private final class FocusedView: UIView {
    override var isFirstResponder: Bool { true }
  }
  func testOwnershipIsContainmentBasedAndUnknownForNonView() {
    let root = UIView()
    let main = WKWebView()
    let popup = WKWebView()
    let focused = FocusedView()
    root.addSubview(main)
    root.addSubview(popup)
    main.addSubview(focused)
    XCTAssertTrue(WebKitResponderObservation.first(in: root) === focused)
    XCTAssertEqual(
      WebKitResponderObservation.category(focused, main: main, popup: popup), .mainWebContent)
    popup.addSubview(focused)
    XCTAssertEqual(
      WebKitResponderObservation.category(focused, main: main, popup: popup), .popupWebContent)
    XCTAssertEqual(
      WebKitResponderObservation.category(main, main: main, popup: popup), .mainWebContent)
    XCTAssertEqual(
      WebKitResponderObservation.category(UITextField(), main: main, popup: popup), .folioTextInput)
    XCTAssertEqual(
      WebKitResponderObservation.category(UIButton(), main: main, popup: popup), .folioControl)
    XCTAssertEqual(
      WebKitResponderObservation.category(UIResponder(), main: main, popup: popup), .unknown)
    XCTAssertEqual(WebKitResponderObservation.category(nil, main: main, popup: popup), .unknown)
  }
  func testSameTabOwnerSelectionRequestsFocusWithoutRebuilding() throws {
    let name = "folio.keyboard.tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: memoryURL)
    }
    let window = BrowserWindowController(
      session: WindowSession(defaults: defaults, migrateLegacy: false),
      websiteDataStore: .nonPersistent(), memory: MemoryLabStore(url: memoryURL), useFixture: true)
    window.loadViewIfNeeded()
    let controller = try XCTUnwrap(window.children.first as? FigmaWebViewController)
    let browser = controller.webView
    controller.diagnostics.inputLogging = true
    let start = controller.diagnostics.events.count
    window.showSelectedTab()
    XCTAssertEqual(controller.diagnostics.events.count, start)
    window.showSelectedTab(ownerSelection: true)
    XCTAssertTrue(
      controller.diagnostics.events.last?.contains("restore-request-sameTabSelected") == true)
    XCTAssertTrue(controller.webView === browser)
    controller.setTabActive(false)
    let inactiveCount = controller.diagnostics.events.count
    controller.restoreBrowserFocus(reason: .diagnosticsDismissed)
    XCTAssertEqual(controller.diagnostics.events.count, inactiveCount)
  }

  func testBridgeRejectsWrongViewAndFrame() {
    let current = WKWebView()
    let other = WKWebView()
    XCTAssertTrue(ScriptBridge.acceptsSender(isMainFrame: true, sender: current, current: current))
    XCTAssertFalse(
      ScriptBridge.acceptsSender(isMainFrame: false, sender: current, current: current))
    XCTAssertFalse(ScriptBridge.acceptsSender(isMainFrame: true, sender: other, current: current))
    XCTAssertFalse(ScriptBridge.acceptsSender(isMainFrame: true, sender: nil, current: nil))
  }

  func testPopupNativeWebFailureAndTerminationCloseAreDeduplicated() throws {
    for route in ["native", "web", "failure", "termination"] {
      let popup = PopupController(
        configuration: WKWebViewConfiguration(), url: URL(string: "about:blank"))
      let child = try XCTUnwrap(popup.browser)
      var closed = 0
      var messages = 0
      popup.onClose = { closed += 1 }
      popup.onOwnershipTransition = { messages += 1 }
      if route == "web" { popup.webViewDidClose(child) }
      if route == "failure" {
        popup.webView(child, didFail: nil, withError: URLError(.networkConnectionLost))
        XCTAssertEqual(messages, 1)
      }
      if route == "termination" {
        popup.webViewWebContentProcessDidTerminate(child)
        XCTAssertEqual(messages, 1)
      }
      popup.close()
      popup.close()
      XCTAssertEqual(closed, 1)
      XCTAssertNil(popup.browser)
    }
  }

  func testStrictKeyboardSchemaAndOptInRecording() throws {
    var payload: [String: Any] = [
      "chord": "Cmd+Y", "event": "keydown", "phase": "capture",
      "history": "none", "sequence": 1, "time": 42, "alt": false, "ctrl": false, "meta": true,
      "shift": false, "repeat": false, "isComposing": false, "isTrusted": true,
      "defaultPrevented": false, "documentFocus": true, "tag": "TEXTAREA", "inputType": "",
      "editable": true, "iframe": false,
    ]
    func validate() -> BridgeMessage? {
      BridgeMessage.validate(["name": "folioKeyboardRouting", "payload": payload])
    }
    guard case .keyboard(let capture) = validate() else { return XCTFail("Valid capture rejected") }
    let store = DiagnosticsStore(session: SessionState())
    store.record(capture)
    XCTAssertTrue(store.events.isEmpty)
    store.inputLogging = true
    store.record(capture)
    XCTAssertTrue(store.events[0].contains("Cmd+Y"))
    let original = payload
    for (key, value) in [
      ("data", "private" as Any), ("chord", "private"), ("tag", "private"),
      ("time", Double.infinity), ("time", -1), ("sequence", 0), ("sequence", 9_007_199_254_740_992),
      ("iframe", true), ("inputType", "private"), ("phase", "handled"), ("history", "insertText"),
    ] {
      payload = original
      payload[key] = value
      XCTAssertNil(validate(), key)
    }
  }
}
