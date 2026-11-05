import UIKit
import WebKit
import XCTest

@testable import Folio

final class FocusTests: XCTestCase {
  @MainActor
  private final class FocusedView: UIView {
    override var isFirstResponder: Bool { true }
  }
  @MainActor
  func testAssistantUsesFocusedResponderAndRestoresOnDisconnectAndDetach() {
    let host = UIView()
    let focused = FocusedView()
    host.addSubview(focused)
    let group = UIBarButtonItemGroup(
      barButtonItems: [
        UIBarButtonItem(title: "Local test", style: .plain, target: nil, action: nil)
      ], representativeItem: nil)
    focused.inputAssistantItem.leadingBarButtonGroups = [group]
    focused.inputAssistantItem.trailingBarButtonGroups = [group]
    let assistant = WebKitInputAssistant()
    assistant.attach(to: host)
    assistant.setEnabled(true)
    assistant.refresh(hardwareKeyboardAttached: true)
    XCTAssertTrue(focused.inputAssistantItem.leadingBarButtonGroups.isEmpty)
    XCTAssertTrue(focused.inputAssistantItem.trailingBarButtonGroups.isEmpty)
    assistant.refresh(hardwareKeyboardAttached: false)
    XCTAssertTrue(focused.inputAssistantItem.leadingBarButtonGroups.first === group)
    assistant.refresh(hardwareKeyboardAttached: true)
    assistant.detach()
    XCTAssertTrue(focused.inputAssistantItem.trailingBarButtonGroups.first === group)
  }
  @MainActor
  func testScrollLockRestoresSettingsAndObservesOnlyWhenLogging() {
    let browser = WKWebView()
    let scroll = browser.scrollView
    scroll.minimumZoomScale = 0.5
    scroll.maximumZoomScale = 3
    scroll.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 8, right: 0)
    let originalPinch = scroll.pinchGestureRecognizer?.isEnabled
    let input = WebKitFocusScroll()
    var logs: [String] = []
    input.onLog = { logs.append($0) }
    input.attach(to: scroll)
    input.setLocked(true)
    scroll.contentOffset = CGPoint(x: 90, y: 110)
    scroll.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 300, right: 0)
    scroll.maximumZoomScale = 4
    XCTAssertEqual(scroll.contentOffset, .zero)
    XCTAssertEqual(scroll.contentInset, .zero)
    XCTAssertEqual(scroll.zoomScale, 1)
    XCTAssertEqual(scroll.maximumZoomScale, 1)
    XCTAssertEqual(scroll.minimumZoomScale, 1)
    XCTAssertEqual(scroll.contentInsetAdjustmentBehavior, .never)
    // WebKit can omit the recognizer entirely when page zoom is unavailable.
    XCTAssertNotEqual(scroll.pinchGestureRecognizer?.isEnabled, true)
    XCTAssertTrue(logs.isEmpty)
    input.logging = true
    let initialLogCount = logs.count
    input.sample("zoomScale")
    input.sample("contentInset")
    XCTAssertEqual(logs.count, initialLogCount)
    scroll.contentOffset = CGPoint(x: 40, y: 20)
    XCTAssertTrue(logs.contains { $0.contains("contentOffset") && $0.contains("zoomScale=") })
    let changedLogCount = logs.count
    input.sample("capture")
    XCTAssertEqual(logs.count, changedLogCount + 1)
    input.logging = false
    let count = logs.count
    input.setLocked(false)
    XCTAssertEqual(scroll.minimumZoomScale, 0.5)
    XCTAssertEqual(scroll.maximumZoomScale, 3)
    XCTAssertEqual(scroll.contentInset.top, 12)
    XCTAssertEqual(scroll.pinchGestureRecognizer?.isEnabled, originalPinch)
    input.detach()
    scroll.contentOffset = CGPoint(x: 30, y: 15)
    XCTAssertEqual(logs.count, count)
    XCTAssertEqual(scroll.contentOffset.x, 30)
  }

  @MainActor
  func testFocusScopeSafeAndSwitchPersistence() throws {
    let name = "folio.focus.tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = InputStrategies(defaults: defaults)
    XCTAssertFalse(settings.focusRevealGuard)
    XCTAssertFalse(settings.editorScrollLock)
    XCTAssertFalse(settings.focusViewportLimit)
    XCTAssertFalse(settings.hardwareKeyboardAssistant)
    settings.editorScrollLock = true
    settings.focusViewportLimit = true
    settings.hardwareKeyboardAssistant = true
    let next = InputStrategies(defaults: defaults)
    XCTAssertTrue(
      next.editorScrollLock && next.focusViewportLimit && next.hardwareKeyboardAssistant)
    XCTAssertTrue(EditorFocusPolicy.allows(URL(string: "https://www.figma.com/design/test")))
    XCTAssertTrue(EditorFocusPolicy.allows(ScriptBridge.focusLabURL))
    for url in [
      "https://www.figma.com/files", "https://www.figma.com/login",
      "https://example.com/design/test", "https://www.figma.com/board/test",
    ] {
      XCTAssertFalse(EditorFocusPolicy.allows(URL(string: url)))
    }
    let safe = WebViewConfiguration.make(
      mode: .safe, bridge: ScriptBridge(), focusRevealGuard: true, focusViewportLimit: true,
      hardwareKeyboardAssistant: true
    )
    XCTAssertTrue(safe.userContentController.userScripts.isEmpty)
  }

  @MainActor
  func testKeyboardHotfixMigratesFocusSwitchesOnceBeforeTabSnapshots() throws {
    let name = "folio.h1.tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let keys = [
      "folio.hardwareKeyboardAssistant", "folio.editorScrollLock",
      "folio.focusViewportLimit", "folio.focusRevealGuard",
    ]
    for key in keys { defaults.set(true, forKey: key) }
    defaults.set(false, forKey: "folio.trackpadPinchZoom")
    let first = InputStrategies(defaults: defaults, isolated: true)
    XCTAssertFalse(first.hardwareKeyboardAssistant)
    XCTAssertFalse(first.editorScrollLock)
    XCTAssertFalse(first.focusViewportLimit)
    XCTAssertFalse(first.focusRevealGuard)
    XCTAssertFalse(first.trackpadPinchZoom)
    first.editorScrollLock = true
    XCTAssertTrue(InputStrategies(defaults: defaults, isolated: true).editorScrollLock)
    XCTAssertTrue(defaults.bool(forKey: "folio.h1KeyboardFocusMigration"))
  }

  @MainActor
  func testTabFocusSwitchesPersistWithoutChangingExistingSibling() throws {
    let name = "folio.focus.tabs.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    _ = InputStrategies(defaults: defaults)
    defaults.set(true, forKey: "folio.editorScrollLock")
    let active = InputStrategies(defaults: defaults, isolated: true)
    let sibling = InputStrategies(defaults: defaults, isolated: true)
    active.editorScrollLock = false
    XCTAssertFalse(InputStrategies(defaults: defaults, isolated: true).editorScrollLock)
    XCTAssertTrue(sibling.editorScrollLock)
    XCTAssertNotEqual(sibling.focusLabel, sibling.savedFocusLabel)
    let store = DiagnosticsStore(session: SessionState(), strategies: sibling)
    XCTAssertTrue(
      store.report.contains(
        "Focus controls (app default): focus-reveal-guard=false [Tier 1 candidate]; editor-scroll-lock=false"
      ))
    XCTAssertTrue(
      store.report.contains(
        "Focus controls (configured): focus-reveal-guard=false [Tier 1 candidate]; editor-scroll-lock=true"
      ))
    active.focusRevealGuard = true
    XCTAssertTrue(InputStrategies(defaults: defaults, isolated: true).focusRevealGuard)
    active.focusViewportLimit = true
    active.hardwareKeyboardAssistant = true
    active.resetFocusSwitches()
    let restarted = InputStrategies(defaults: defaults, isolated: true)
    XCTAssertFalse(restarted.focusRevealGuard)
    XCTAssertFalse(restarted.editorScrollLock)
    XCTAssertFalse(restarted.focusViewportLimit)
    XCTAssertFalse(restarted.hardwareKeyboardAssistant)
  }

  @MainActor
  func testRevealGuardRunsInIsolatedWorldAndRestoresOnlyHiddenFixtureScroll() async throws {
    let bridge = ScriptBridge()
    let browser = WKWebView(
      frame: CGRect(x: 0, y: 0, width: 800, height: 600),
      configuration: WebViewConfiguration.make(
        mode: .normal, bridge: bridge, focusRevealGuard: true))
    bridge.webView = browser
    defer {
      browser.stopLoading()
      browser.configuration.userContentController.removeAllScriptMessageHandlers()
    }
    let url = try XCTUnwrap(ScriptBridge.focusLabURL)
    let navigationCompletion1 = NativeNavigationCompletionProbe(browser)
    browser.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    try await navigationCompletion1.wait()
    var ready = false
    for _ in 0..<100 {
      if (try? await browser.evaluateJavaScript(
        "!!document.body && typeof globalThis.__folio?.setFocusRevealGuard === 'function'", in: nil,
        contentWorld: ScriptBridge.world)) as? Bool == true
      {
        ready = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(ready)
    let restored = try await browser.evaluateJavaScript(
      """
      (() => {
        const box = document.createElement('div');
        box.style.cssText = 'overflow:hidden;width:300px;height:100px';
        const editor = document.createElement('div');
        editor.contentEditable = 'true'; editor.style.height = '600px';
        box.append(editor); document.body.append(box); editor.focus({preventScroll:true});
        globalThis.__folio.setFocusRevealGuard(false);
        globalThis.__folio.setFocusRevealGuard(true);
        box.scrollTop = 120; box.dispatchEvent(new Event('scroll'));
        const hidden = box.scrollTop;
        box.style.overflow = 'auto'; box.scrollTop = 120; box.dispatchEvent(new Event('scroll'));
        const auto = box.scrollTop;
        const count = globalThis.__folio.focusRevealGuardStats().restored;
        box.remove(); return [hidden, auto, count];
      })()
      """, in: nil, contentWorld: ScriptBridge.world)
    XCTAssertEqual(restored as? [Int], [0, 120, 1])
    let pageWorld = try await browser.evaluateJavaScript("typeof globalThis.__folio")
    XCTAssertEqual(pageWorld as? String, "undefined")
  }

  @MainActor
  func testFocusBridgeRejectsTextExtraFieldsAndInvalidNumbers() throws {
    var payload: [String: Any] = [
      "event": "focusin", "tag": "TEXTAREA", "inputType": "", "innerWidth": 1024,
      "innerHeight": 768, "width": 1024, "height": 450, "offsetLeft": 0, "offsetTop": 0, "scale": 1,
      "scrollX": 0, "scrollY": 0, "time": 42,
    ]
    func validate() -> BridgeMessage? {
      BridgeMessage.validate(["name": "folioFocusLog", "payload": payload])
    }
    guard case .focus(let focus) = validate() else {
      return XCTFail("Valid focus capture rejected")
    }
    let store = DiagnosticsStore(session: SessionState())
    store.record(focus)
    XCTAssertTrue(store.events.isEmpty)
    store.inputLogging = true
    store.record(focus)
    XCTAssertTrue(store.events.first?.contains("tag=TEXTAREA") == true)
    payload["event"] = "revealguard"
    XCTAssertNotNil(validate())
    payload["text"] = "private text"
    XCTAssertNil(validate())
    payload.removeValue(forKey: "text")
    payload["tag"] = "private text"
    XCTAssertNil(validate())
    payload["tag"] = "INPUT"
    payload["scale"] = -1
    XCTAssertNil(validate())
    XCTAssertEqual(
      BridgeMessage.validate(["name": "folioFocusAssist", "payload": [:]]), .focusAssistant)
    XCTAssertNil(
      BridgeMessage.validate(["name": "folioFocusAssist", "payload": ["text": "private"]]))
  }
}
