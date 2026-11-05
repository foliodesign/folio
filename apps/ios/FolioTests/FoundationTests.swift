import WebKit
import XCTest

@testable import Folio

final class FoundationTests: XCTestCase {
  func testURLRedactionRemovesFileKeyTitleAndCredentials() {
    XCTAssertEqual(
      Privacy.redactedURL(
        URL(
          string:
            "https://user:password@www.figma.com/design/secretKey/Private-Title?token=secret#node-id=1"
        )),
      "www.figma.com/design/<file>"
    )
    for route in ["file", "proto", "board", "slides", "site", "make"] {
      XCTAssertEqual(
        Privacy.redactedURL(URL(string: "https://www.figma.com/\(route)/secret/Title")),
        "www.figma.com/\(route)/<file>")
    }
    XCTAssertEqual(
      Privacy.redactedURL(URL(string: "https://www.figma.com/login?code=secret#token")),
      "www.figma.com/login")
    XCTAssertEqual(Privacy.redactedURL(nil), "unavailable")
  }

  func testReportSanitization() {
    let clean = Privacy.sanitize(
      "https://example.com/?token=secret token=abc password=hunter2 Bearer abc.def eyJabc.def.ghi\u{0}"
    )
    XCTAssertFalse(clean.contains("secret"))
    XCTAssertFalse(clean.contains("hunter2"))
    XCTAssertFalse(clean.contains("abc"))
    XCTAssertFalse(clean.contains("\u{0}"))
    XCTAssertEqual(
      Privacy.sanitize("pointerdown key=<char>\nNormal"), "pointerdown key=<char>\nNormal")
  }

  @MainActor
  func testModeCrashAndNavigationPersistence() throws {
    let name = "folio.tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let state = SessionState(defaults: defaults)
    XCTAssertEqual(state.mode, .normal)
    state.mode = .safe
    state.recordCrash()
    state.lastURL = try XCTUnwrap(
      URL(string: "https://user:pass@www.figma.com/design/key/Title?token=secret#fragment"))
    let restored = SessionState(defaults: defaults)
    XCTAssertEqual(restored.mode, .safe)
    XCTAssertEqual(restored.crashCount, 1)
    XCTAssertEqual(restored.lastURL.absoluteString, "https://www.figma.com/design/key")
    defaults.set("bogus", forKey: "folio.mode")
    XCTAssertEqual(restored.mode, .normal)
  }

  @MainActor
  func testSafeModeHasNoUserScriptsAndPersistentStore() {
    let safe = WebViewConfiguration.make(mode: .safe, bridge: ScriptBridge())
    XCTAssertTrue(safe.userContentController.userScripts.isEmpty)
    XCTAssertTrue(safe.websiteDataStore.isPersistent)
    for mode in [BrowserMode.normal, .compatibility] {
      let config = WebViewConfiguration.make(mode: mode, bridge: ScriptBridge())
      XCTAssertEqual(
        config.userContentController.userScripts.count, 15
      )
      XCTAssertTrue(
        config.userContentController.userScripts.allSatisfy {
          $0.isForMainFrameOnly && $0.injectionTime == .atDocumentStart
        })
    }
  }

  func testBridgeRejectsUnknownMalformedAndExtraFields() {
    XCTAssertNil(BridgeMessage.validate(["name": "evaluate", "payload": ["code": "alert(1)"]]))
    XCTAssertNil(BridgeMessage.validate(["name": "folioDiagnostics", "payload": [:]]))
    var input = validInput()
    XCTAssertNotNil(BridgeMessage.validate(["name": "folioInputLog", "payload": input]))
    input["token"] = "secret"
    XCTAssertNil(BridgeMessage.validate(["name": "folioInputLog", "payload": input]))
    input.removeValue(forKey: "token")
    input["pressure"] = 2
    XCTAssertNil(BridgeMessage.validate(["name": "folioInputLog", "payload": input]))
    input["pressure"] = 0
    input["type"] = "arbitrary"
    XCTAssertNil(BridgeMessage.validate(["name": "folioInputLog", "payload": input]))
  }

  func testBridgeNeverRetainsPrintableOrUnknownKeys() {
    var input = validInput()
    for key in ["s", "some-private-text", "<char>"] {
      input["key"] = key
      guard
        case .input(let message) = BridgeMessage.validate([
          "name": "folioInputLog", "payload": input,
        ])
      else {
        XCTFail("Valid input was rejected")
        return
      }
      XCTAssertEqual(message.key, "<char>")
    }
  }

  func testCmdYLabelSurvivesWhileTextStaysRedacted() {
    var input = validInput()
    input["key"] = "Cmd+Y"
    guard
      case .input(let capture) = BridgeMessage.validate(["name": "folioInputLog", "payload": input])
    else {
      return XCTFail("Cmd+Y rejected")
    }
    XCTAssertEqual(capture.key, "Cmd+Y")
  }

  func testDiagnosticsValidation() {
    let graphics: [String: Any] = [
      "available": true, "renderer": "Apple GPU", "maxTextureSize": 16384,
    ]
    var payload: [String: Any] = [
      "userAgent": "AppleWebKit/605.1.15", "gpuPresent": true, "adapterResult": "available",
      "adapterInfo": "Apple",
      "webgl": graphics, "webgl2": graphics, "devicePixelRatio": 2, "viewportWidth": 1024,
      "viewportHeight": 768, "maxTouchPoints": 5,
      "media": Dictionary(uniqueKeysWithValues: BridgeMessage.mediaKeys.map { ($0, false) }),
    ]
    XCTAssertNotNil(BridgeMessage.validate(["name": "folioDiagnostics", "payload": payload]))
    payload["media"] = ["unknown": true]
    XCTAssertNil(BridgeMessage.validate(["name": "folioDiagnostics", "payload": payload]))
  }

  @MainActor
  func testRingBufferBoundsAndInputDefaultOff() {
    let store = DiagnosticsStore(session: SessionState())
    XCTAssertFalse(store.inputLogging)
    for index in 0..<600 { store.log("event \(index)") }
    XCTAssertEqual(store.events.count, 500)
    XCTAssertTrue(store.events.first?.hasSuffix("event 100") == true)
    XCTAssertTrue(store.report.contains("event 599"))
  }

  func testUnknownURLsNeverExposePathsOrExternalHosts() {
    XCTAssertEqual(
      Privacy.redactedURL(URL(string: "https://www.figma.com/oauth/private-token")),
      "www.figma.com/<path>")
    XCTAssertEqual(
      Privacy.redactedURL(URL(string: "https://secret.example.com/callback/private-token")),
      "<external>")
  }

  @MainActor
  func testRecoveryIgnoresExternalAuthAndSanitizesStoredURLs() throws {
    let name = "folio.tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let state = SessionState(defaults: defaults)
    state.lastURL = try XCTUnwrap(
      URL(string: "https://www.figma.com/design/key/Title?token=secret"))
    state.lastURL = try XCTUnwrap(URL(string: "https://accounts.google.com/callback/path-token"))
    XCTAssertEqual(state.lastURL.absoluteString, "https://www.figma.com/design/key")
    defaults.set(
      "https://user:pass@www.figma.com/design/key/Title?code=secret", forKey: "folio.lastURL")
    XCTAssertEqual(state.lastURL.absoluteString, "https://www.figma.com/design/key")
    XCTAssertEqual(defaults.string(forKey: "folio.lastURL"), "https://www.figma.com/design/key")
    defaults.set("https://accounts.google.com/callback/path-token", forKey: "folio.lastURL")
    XCTAssertEqual(state.lastURL.absoluteString, "https://www.figma.com/files")
    XCTAssertNil(defaults.string(forKey: "folio.lastURL"))
    state.lastURL = try XCTUnwrap(URL(string: "https://www.figma.com/oauth/path-token"))
    XCTAssertEqual(state.lastURL.absoluteString, "https://www.figma.com/files")
  }

  func testRecoveryBoundsRapidCrashesWithoutResetOnNavigation() {
    var recovery = ProcessRecovery()
    XCTAssertTrue(recovery.shouldReload(now: 0))
    XCTAssertTrue(recovery.shouldReload(now: 1))
    XCTAssertFalse(recovery.shouldReload(now: 2))
    XCTAssertFalse(recovery.shouldReload(now: 119))
    XCTAssertFalse(recovery.shouldReload(now: 120))
    XCTAssertFalse(recovery.shouldReload(now: 121))
    XCTAssertFalse(recovery.shouldReload(now: 122))
  }

  @MainActor
  func testObserverCannotPreventBrowserGesturesAndControllerReleases() {
    let observer = InputObserver { _, _ in }
    let browserGesture = UIPanGestureRecognizer()
    XCTAssertFalse(observer.cancelsTouchesInView)
    XCTAssertFalse(observer.delaysTouchesBegan)
    XCTAssertFalse(observer.delaysTouchesEnded)
    XCTAssertFalse(observer.canPrevent(browserGesture))
    XCTAssertFalse(observer.canBePrevented(by: browserGesture))
    weak var released: FigmaWebViewController?
    autoreleasepool {
      let controller = FigmaWebViewController()
      controller.loadViewIfNeeded()
      released = controller
    }
    XCTAssertNil(released)
  }

  private func validInput() -> [String: Any] {
    [
      "type": "keydown", "pointerType": "none", "isTrusted": true, "button": 0, "buttons": 0,
      "prevented": false, "coalesced": 0,
      "pressure": 0,
      "tiltX": 0, "tiltY": 0, "x": 0, "y": 0, "deltaX": 0, "deltaY": 0, "key": "Enter",
      "alt": false, "ctrl": false, "meta": true, "shift": false,
    ]
  }
}
