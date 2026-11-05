import WebKit
import XCTest

@testable import Folio

final class ButtonColorTests: XCTestCase {
  @MainActor
  func testInheritedDefaultAuthorLayersAndRuntimeRestoration() async throws {
    for mode in [BrowserMode.normal, .compatibility] {
      let browser = WKWebView(
        frame: .zero,
        configuration: WebViewConfiguration.make(
          mode: mode, bridge: ScriptBridge(), uaButtonColor: true))
      defer {
        browser.stopLoading()
        browser.configuration.userContentController.removeAllScriptMessageHandlers()
      }
      let navigationCompletion1 = NativeNavigationCompletionProbe(browser)
      browser.loadHTMLString(
        """
        <style>
        @layer reset, theme;
        @layer reset { button { background: white; } }
        @layer theme { :where(.primary) { color: rgb(1, 2, 255); } }
        body { color: rgb(20, 30, 40); }
        .explicit { color: rgb(255, 2, 1); }
        </style>
        <button id="plain">Default</button>
        <button id="primary" class="primary">Primary</button>
        <button id="explicit" class="explicit">Explicit</button>
        """, baseURL: nil)
      try await navigationCompletion1.wait()
      var ready = false
      for _ in 0..<100 {
        let value = try? await browser.evaluateJavaScript(
          "!!document.getElementById('plain') && typeof globalThis.__folio?.setUAButtonColor === 'function'",
          in: nil, contentWorld: ScriptBridge.world)
        if value as? Bool == true {
          ready = true
          break
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertTrue(ready)
      let colors =
        "['plain','primary','explicit'].map(id => getComputedStyle(document.getElementById(id)).color)"
      let initial = try await browser.evaluateJavaScript(colors)
      XCTAssertEqual(initial as? [String], ["rgb(20, 30, 40)", "rgb(1, 2, 255)", "rgb(255, 2, 1)"])
      let off = try await browser.evaluateJavaScript(
        "globalThis.__folio.setUAButtonColor(false); \(colors)",
        in: nil, contentWorld: ScriptBridge.world)
      XCTAssertNotEqual((off as? [String])?.first, "rgb(20, 30, 40)")
      let restored = try await browser.evaluateJavaScript(
        "globalThis.__folio.setUAButtonColor(true); globalThis.__folio.setUAButtonColor(true); \(colors)",
        in: nil, contentWorld: ScriptBridge.world)
      XCTAssertEqual(restored as? [String], initial as? [String])
      let disposed = try await browser.evaluateJavaScript(
        "globalThis.__folio.disposeUAButtonColor(); \(colors)",
        in: nil, contentWorld: ScriptBridge.world)
      XCTAssertEqual(disposed as? [String], off as? [String])
    }
  }

  @MainActor
  func testDisabledAndSafeDoNotNormalize() async throws {
    for mode in [BrowserMode.normal, .safe] {
      let browser = WKWebView(
        frame: .zero,
        configuration: WebViewConfiguration.make(
          mode: mode, bridge: ScriptBridge(), uaButtonColor: false))
      defer {
        browser.stopLoading()
        browser.configuration.userContentController.removeAllScriptMessageHandlers()
      }
      let navigationCompletion2 = NativeNavigationCompletionProbe(browser)
      browser.loadHTMLString(
        "<body style='color:rgb(20,30,40)'><button>Default</button>", baseURL: nil)
      try await navigationCompletion2.wait()
      var color: String?
      for _ in 0..<100 {
        color =
          try? await browser.evaluateJavaScript(
            "document.querySelector('button') ? getComputedStyle(document.querySelector('button')).color : null"
          ) as? String
        if color != nil { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertNotNil(color)
      XCTAssertNotEqual(color, "rgb(20, 30, 40)")
    }
  }
}
