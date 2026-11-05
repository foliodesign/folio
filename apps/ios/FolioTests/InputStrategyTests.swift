import UIKit
import WebKit
import XCTest

@testable import Folio

final class InputStrategyTests: XCTestCase {
  @MainActor
  func testStrategyPersistenceAndInvalidFallback() throws {
    let name = "folio.input.tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let strategies = InputStrategies(defaults: defaults)
    let snapshot = InputStrategies(defaults: defaults, isolated: true)
    XCTAssertEqual(
      strategies.touchMode,
      UIPencilInteraction.prefersPencilOnlyDrawing ? .pencilAndTouch : .touchOnly)
    XCTAssertTrue(strategies.observePencilTouch())
    XCTAssertFalse(snapshot.observePencilTouch())
    XCTAssertEqual(snapshot.touchMode, .pencilAndTouch)
    strategies.touchMode = .touchOnly
    XCTAssertEqual(snapshot.touchMode, .touchOnly)
    XCTAssertFalse(snapshot.observePencilTouch())
    XCTAssertEqual(InputStrategies(defaults: defaults).touchMode, .touchOnly)
    strategies.resetTouchMode()
    XCTAssertEqual(snapshot.touchMode, .pencilAndTouch)
    XCTAssertEqual(strategies.tapAction, .undo)
    XCTAssertEqual(strategies.squeezeAction, .redo)
    XCTAssertEqual(strategies.pencil, .none)
    XCTAssertEqual(strategies.finger, .baseline)
    XCTAssertEqual(strategies.trackpadPinchRoute, InputStrategies.defaultPinchRoute)
    strategies.trackpadPinchRoute = .gesture
    XCTAssertTrue(strategies.trackpadPinchZoom)
    XCTAssertTrue(strategies.fingerCanvasWheel)
    XCTAssertTrue(strategies.uaButtonColor)
    strategies.uaButtonColor = false
    strategies.trackpadPinchZoom = false
    strategies.fingerCanvasWheel = false
    XCTAssertFalse(strategies.penDragUnusable)
    strategies.pencil = .mouseJS
    strategies.finger = .canvas
    strategies.tapAction = .toggleDevMode
    strategies.squeezeAction = .rectangle
    strategies.penDragUnusable = true
    let restored = InputStrategies(defaults: defaults)
    XCTAssertEqual(restored.trackpadPinchRoute, .gesture)
    defaults.set("invalid", forKey: "folio.trackpadPinchRoute")
    XCTAssertEqual(restored.trackpadPinchRoute, InputStrategies.defaultPinchRoute)
    XCTAssertFalse(restored.uaButtonColor)
    XCTAssertFalse(restored.trackpadPinchZoom)
    XCTAssertFalse(restored.fingerCanvasWheel)
    XCTAssertEqual(restored.pencil, .mouseJS)
    XCTAssertEqual(restored.finger, .canvas)
    XCTAssertEqual(restored.tapAction, .toggleDevMode)
    XCTAssertEqual(restored.squeezeAction, .rectangle)
    XCTAssertFalse(restored.penDragUnusable)
    defaults.set("bad", forKey: "folio.pencil")
    defaults.set("bad", forKey: "folio.finger")
    defaults.set("bad", forKey: "pencil.doubleTap")
    XCTAssertEqual(restored.pencil, .none)
    XCTAssertEqual(restored.finger, .baseline)
    XCTAssertEqual(restored.tapAction, .undo)
    defaults.set("invalid", forKey: "folio.trackpadPinchZoom")
    defaults.set("invalid", forKey: "folio.fingerCanvasWheel")
    XCTAssertTrue(restored.trackpadPinchZoom)
    XCTAssertTrue(restored.fingerCanvasWheel)
  }

  @MainActor
  func testIsolatedCanvasWheelDispatchAndDisposal() async throws {
    let browser = WKWebView(
      frame: CGRect(x: 0, y: 0, width: 500, height: 500),
      configuration: WebViewConfiguration.make(mode: .normal, bridge: ScriptBridge()))
    let focus = WebKitFocusScroll()
    focus.attach(to: browser.scrollView)
    focus.setLocked(true)
    defer {
      focus.detach()
      browser.stopLoading()
      browser.configuration.userContentController.removeAllScriptMessageHandlers()
    }
    let navigationCompletion1 = NativeNavigationCompletionProbe(browser)
    browser.loadHTMLString("<canvas style='width:400px;height:400px'></canvas>", baseURL: nil)
    try await navigationCompletion1.wait()
    var ready = false
    for _ in 0..<100 {
      let value = try? await browser.evaluateJavaScript(
        "typeof globalThis.__folio?.trackpadPinch === 'function' && !!document.querySelector('canvas')",
        in: nil, contentWorld: ScriptBridge.world)
      if value as? Bool == true {
        ready = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(ready)
    let result = try await browser.evaluateJavaScript(
      """
      let received;
      document.querySelector('canvas').addEventListener('wheel', e => {
        received = !e.isTrusted && e.ctrlKey && e.deltaMode === 0 && e.deltaY < 0 && e.clientX === 20;
      });
      globalThis.__folio.trackpadPinch("began", 1, 20, 20);
      globalThis.__folio.trackpadPinch("changed", 1.1, 20, 20);
      received === true
      """, in: nil, contentWorld: ScriptBridge.world)
    XCTAssertEqual(result as? Bool, true)
    let gesture = try await browser.evaluateJavaScript(
      """
      received = false;
      document.querySelector('canvas').addEventListener('gesturechange', e => {
        received = !e.isTrusted && e.scale === 1.1 && e.clientX === 20;
      });
      globalThis.__folio.trackpadPinch("ended", 1.1, 20, 20);
      globalThis.__folio.setTrackpadPinchRoute("gesture");
      globalThis.__folio.trackpadPinch("began", 1, 20, 20);
      globalThis.__folio.trackpadPinch("changed", 1.1, 20, 20);
      received && (globalThis.__folio.trackpadPinchStats().gestureSupported
        ? globalThis.__folio.trackpadPinchStats().route === 'gesture'
        : globalThis.__folio.trackpadPinchStats().route === 'wheel')
      """, in: nil, contentWorld: ScriptBridge.world)
    XCTAssertEqual(gesture as? Bool, true)
    let disposed = try await browser.evaluateJavaScript(
      "globalThis.__folio.disposeCanvasWheel(); typeof globalThis.__folio.trackpadPinch",
      in: nil, contentWorld: ScriptBridge.world)
    XCTAssertEqual(disposed as? String, "undefined")
  }

  @MainActor
  func testTrackpadRecognizerRejectsDirectTouchesAndRestores() {
    let view = UIView()
    let input = TrackpadPinch()
    input.attach(to: view)
    let pinch = view.gestureRecognizers!.first!
    XCTAssertEqual(
      pinch.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)])
    XCTAssertFalse(pinch.cancelsTouchesInView)
    XCTAssertFalse(pinch.delaysTouchesBegan)
    XCTAssertFalse(pinch.delaysTouchesEnded)
    XCTAssertFalse(pinch.canPrevent(UIPanGestureRecognizer()))
    XCTAssertFalse(pinch.canBePrevented(by: UIPanGestureRecognizer()))
    XCTAssertFalse(input.gestureRecognizer(pinch, shouldReceive: UIEvent()))
    XCTAssertTrue(
      input.gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: UIPinchGestureRecognizer()))
    input.detach()
    XCTAssertTrue(view.gestureRecognizers?.isEmpty ?? true)
  }

  @MainActor
  func testCumulativeTrackpadStateAndFixedAnchor() {
    let input = TrackpadPinch()
    let pinch = DrivenPinch()
    var updates: [PinchUpdate] = []
    input.onUpdate = { updates.append($0) }
    pinch.drivenState = .began
    input.changed(pinch)
    pinch.point = CGPoint(x: 90, y: 80)
    for scale in [1.1, 1.15] {
      pinch.drivenState = .changed
      pinch.scale = scale
      input.changed(pinch)
      XCTAssertEqual(pinch.scale, scale)
    }
    pinch.drivenState = .ended
    pinch.scale = 1.2
    input.changed(pinch)
    pinch.drivenState = .changed
    input.changed(pinch)
    XCTAssertEqual(updates.map(\.phase), [.began, .changed, .changed, .ended])
    XCTAssertEqual(updates.map(\.scale), [1, 1.1, 1.15, 1.2])
    XCTAssertTrue(updates.allSatisfy { $0.location == CGPoint(x: 10, y: 20) })
    input.detach()
    input.changed(pinch)
    XCTAssertEqual(updates.count, 4)
  }

  @MainActor
  func testFakeRecognizerPolicyKeepsEventDeliveryAndOtherTouchTypes() {
    let types = [
      UITouch.TouchType.direct.rawValue, UITouch.TouchType.pencil.rawValue,
      UITouch.TouchType.indirectPointer.rawValue,
    ]
    for kind in [(true, false), (false, true), (false, false)] {
      let fake = WebKitGestureReroute.Facts(isPan: kind.0, isLongPress: kind.1, touchTypes: types)
      XCTAssertEqual(WebKitGestureReroute.reroutedTypes(fake, pencil: false), types)
      XCTAssertEqual(
        WebKitGestureReroute.reroutedTypes(fake, pencil: true),
        kind.0 || kind.1 ? [types[0], types[2]] : types)
    }
    let fake = WebKitGestureReroute.Facts(isPan: true, isLongPress: false, touchTypes: [])
    XCTAssertTrue(WebKitGestureReroute.reroutedTypes(fake, pencil: true).isEmpty)
  }

  @MainActor
  func testRecognizerWalkApplyRestoreAndRepeatWithFakeViewTree() {
    let root = UIScrollView()
    let nested = UIView()
    let deep = UIView()
    root.addSubview(nested)
    nested.addSubview(deep)
    let pan = UIPanGestureRecognizer()
    let hold = UILongPressGestureRecognizer()
    let tap = UITapGestureRecognizer()
    nested.addGestureRecognizer(pan)
    deep.addGestureRecognizer(hold)
    deep.addGestureRecognizer(tap)
    let types = [
      NSNumber(value: UITouch.TouchType.direct.rawValue),
      NSNumber(value: UITouch.TouchType.pencil.rawValue),
    ]
    for recognizer in [pan, hold, tap, root.panGestureRecognizer] {
      recognizer.allowedTouchTypes = types
    }
    let minimum = root.panGestureRecognizer.minimumNumberOfTouches
    let walked = WebKitGestureReroute.walk(root)
    XCTAssertTrue(walked.contains(pan))
    XCTAssertTrue(walked.contains(hold))
    XCTAssertEqual(Set(walked.map(ObjectIdentifier.init)).count, walked.count)
    let reroute = WebKitGestureReroute()
    reroute.apply(scrollView: root, pencil: true, finger: .canvas)
    XCTAssertEqual(pan.allowedTouchTypes, [types[0]])
    XCTAssertEqual(hold.allowedTouchTypes, [types[0]])
    XCTAssertEqual(tap.allowedTouchTypes, types)
    XCTAssertEqual(root.panGestureRecognizer.minimumNumberOfTouches, 2)
    reroute.apply(scrollView: root, pencil: false, finger: .page)
    XCTAssertEqual(pan.allowedTouchTypes, types)
    XCTAssertEqual(hold.allowedTouchTypes, types)
    XCTAssertEqual(root.panGestureRecognizer.minimumNumberOfTouches, 1)
    reroute.restore()
    XCTAssertEqual(root.panGestureRecognizer.minimumNumberOfTouches, minimum)
    XCTAssertEqual(root.panGestureRecognizer.allowedTouchTypes, types)
    XCTAssertEqual(reroute.changedCount, 0)
  }

  @MainActor
  func testBridgeAllowsOnlyExactBundledLabFileAndFixedVerdicts() throws {
    let url = try XCTUnwrap(ScriptBridge.labURL)
    XCTAssertTrue(ScriptBridge.acceptsFrame(url: url, protocolName: "file"))
    XCTAssertFalse(
      ScriptBridge.acceptsFrame(
        url: URL(fileURLWithPath: "/tmp/input-lab.html"), protocolName: "file"))
    XCTAssertFalse(ScriptBridge.acceptsFrame(url: nil, protocolName: "file"))
    var results = Dictionary(
      uniqueKeysWithValues: BridgeMessage.labItems.map { ($0, "NOT TESTED") })
    results["Pencil drag"] = "FAIL"
    XCTAssertEqual(
      BridgeMessage.validate(["name": "folioLabResults", "payload": ["results": results]]),
      .labResults(results))
    results["text-layer editing"] = "PASS"
    XCTAssertNil(
      BridgeMessage.validate(["name": "folioLabResults", "payload": ["results": results]]))
    results["text-layer editing"] = "NOT TESTED"
    XCTAssertFalse(ScriptBridge.acceptsFrame(url: nil, protocolName: "https"))
    XCTAssertFalse(ScriptBridge.acceptsFrame(url: url, protocolName: "https"))
    results["Pencil drag"] = "private text"
    XCTAssertNil(
      BridgeMessage.validate(["name": "folioLabResults", "payload": ["results": results]]))
    results["Pencil drag"] = "FAIL"
    results["extra"] = "PASS"
    XCTAssertNil(
      BridgeMessage.validate(["name": "folioLabResults", "payload": ["results": results]]))
  }
  @MainActor
  func testLabDisposalRemovesHandlersAndNetworkPageNeverGetsLabUI() async throws {
    let bridge = ScriptBridge()
    let browser = WKWebView(
      frame: .zero, configuration: WebViewConfiguration.make(mode: .normal, bridge: bridge))
    bridge.webView = browser
    let url = try XCTUnwrap(ScriptBridge.labURL)
    let navigationCompletion2 = NativeNavigationCompletionProbe(browser)
    browser.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    try await navigationCompletion2.wait()
    var ready = false
    for _ in 0..<100 {
      let result = try? await browser.evaluateJavaScript(
        "typeof globalThis.__folio?.setLabStrategy === 'function'", in: nil,
        contentWorld: ScriptBridge.world)
      if result as? Bool == true {
        ready = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(ready, "Bundled lab did not initialize")
    let count = try await browser.evaluateJavaScript(
      "document.querySelectorAll('#results select').length", in: nil,
      contentWorld: ScriptBridge.world)
    XCTAssertEqual(count as? Int, BridgeMessage.labItems.count)
    let touchCoordinates = try await browser.evaluateJavaScript(
      """
      window.dispatchEvent(new TouchEvent('touchstart', {
        changedTouches: [new Touch({identifier: 1, target: document.body, clientX: 13, clientY: 29})]
      }));
      document.getElementById('events').textContent.includes('xy=13,29')
      """, in: nil, contentWorld: ScriptBridge.world)
    XCTAssertEqual(touchCoordinates as? Bool, true)
    let disposed = try await browser.evaluateJavaScript(
      """
      globalThis.__folio.dispose();
      document.getElementById('events').textContent = 'unchanged';
      window.dispatchEvent(new KeyboardEvent('keydown', {key:'private text'}));
      document.getElementById('events').textContent
      """, in: nil, contentWorld: ScriptBridge.world)
    XCTAssertEqual(disposed as? String, "unchanged")
    let navigationCompletion3 = NativeNavigationCompletionProbe(browser)
    browser.loadHTMLString("<div id='results'></div>", baseURL: URL(string: "https://example.com"))
    try await navigationCompletion3.wait()
    var networkReady = false
    for _ in 0..<100 {
      let result = try? await browser.evaluateJavaScript(
        "location.protocol === 'https:' && !!globalThis.__folio", in: nil,
        contentWorld: ScriptBridge.world)
      if result as? Bool == true {
        networkReady = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(networkReady)
    let installed = try await browser.evaluateJavaScript(
      "typeof globalThis.__folio?.setLabStrategy", in: nil, contentWorld: ScriptBridge.world)
    XCTAssertEqual(installed as? String, "undefined")
    browser.stopLoading()
    browser.configuration.userContentController.removeAllScriptMessageHandlers()
  }

}

@MainActor
private final class DrivenPinch: UIPinchGestureRecognizer {
  var drivenState: UIGestureRecognizer.State = .possible
  var point = CGPoint(x: 10, y: 20)
  override var state: UIGestureRecognizer.State {
    get { drivenState }
    set { drivenState = newValue }
  }
  override func location(in view: UIView?) -> CGPoint { point }
}
