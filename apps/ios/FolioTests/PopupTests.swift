import WebKit
import XCTest

@testable import Folio

final class PopupTests: XCTestCase {
  @MainActor
  func testHomeAccountChildAndDelayedDocumentWindow() async throws {
    let name = "folio.account.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: memoryURL)
    }
    for raw in ["https://figma.com/login", "https://www.figma.com/sso/callback"] {
      XCTAssertTrue(PopupPolicy.allowsHomeAuthWindow(URL(string: raw)))
    }
    for raw in [
      "about:blank", "https://example.test/login", "https://figma.com.evil.test/login",
      "https://accounts.google.com/o/oauth2/auth", "https://figma.com:444/login",
      "https://user:pass@figma.com/login", "https://figma.com/design/file",
    ] {
      XCTAssertFalse(PopupPolicy.allowsHomeAuthWindow(URL(string: raw)), raw)
    }
    let tab = TabSession(kind: .home, url: SessionState.startURL, defaults: defaults)
    let controller = FigmaWebViewController(
      tab: tab, websiteDataStore: .nonPersistent(),
      memory: MemoryLabStore(url: memoryURL), fixtureNumber: 1)
    controller.loadViewIfNeeded()
    defer { controller.closeTab() }
    for _ in 0..<200 {
      if controller.initialPageReady { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.initialPageReady)
    XCTAssertTrue(
      controller.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    let routed = expectation(description: "Home delayed document still reaches tab routing")
    controller.onRoute = { url, _ in
      XCTAssertEqual(TabNavigationRouter.classify(url), .file("account-fixture-copy"))
      routed.fulfill()
      return nil
    }
    _ = try await controller.webView.evaluateJavaScript(
      "setTimeout(() => window.open('https://www.figma.com/design/account-fixture-copy'), 100); void 0"
    )
    await fulfillment(of: [routed], timeout: 10)
    controller.showingAuthLab = true
    let lab = try XCTUnwrap(FigmaWebViewController.authLabURL)
    controller.initialPageReady = false
    controller.webView.loadFileURL(lab, allowingReadAccessTo: lab.deletingLastPathComponent())
    for _ in 0..<200 {
      if controller.initialPageReady { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(controller.initialPageReady)
    // Mirror Home's automatic-window setting on the exact offline lab URLs.
    controller.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    _ = try await controller.webView.evaluateJavaScript(
      "document.querySelector('details').open = true; document.getElementById('add-account').click()"
    )
    for _ in 0..<200 {
      if controller.popup?.browser?.isLoading == false { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let child = try XCTUnwrap(controller.popup?.browser)
    XCTAssertTrue(child.configuration.userContentController.userScripts.isEmpty)
    XCTAssertFalse(child.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    var acknowledgement: String?
    for _ in 0..<200 {
      acknowledgement =
        try? await child.evaluateJavaScript(
          "document.getElementById('result')?.textContent") as? String
      if acknowledgement == "PASS: opener acknowledgement received" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(acknowledgement, "PASS: opener acknowledgement received")
    // The fixture alone sends its fixed completion marker, closes and lets the opener reload.
    _ = try? await child.evaluateJavaScript("document.getElementById('complete-account').click()")
    for _ in 0..<200 {
      if controller.popup == nil, controller.webView.isLoading == false {
        let result =
          try? await controller.webView.evaluateJavaScript(
            "document.getElementById('result')?.textContent") as? String
        if result == "PASS: account child closed and opener reloaded" { return }
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let finalState = try? await controller.webView.evaluateJavaScript(
      "JSON.stringify({result:document.getElementById('result')?.textContent,navigation:performance.getEntriesByType('navigation')[0]?.type})"
    )
    XCTFail(
      "Account child must close and its opener must reload. Popup absent: \(controller.popup == nil), fixture: \(String(describing: finalState))"
    )
  }

  func testAutomaticDocumentWindowsRejectExternalAndAuthDestinations() {
    for raw in [
      "about:blank", "https://www.figma.com/design/copy", "https://www.figma.com/file/new",
      "https://figma.new",
    ] {
      XCTAssertTrue(PopupPolicy.allowsDocumentWindow(URL(string: raw)), raw)
    }
    for raw in [
      "https://example.test", "https://www.figma.com/login", "https://www.figma.com/files",
      "https://accounts.google.com/o/oauth2/auth", "javascript:alert(1)",
      "https://u:p@figma.com/design/copy", "https://figma.com:444/design/copy",
    ] {
      XCTAssertFalse(PopupPolicy.allowsDocumentWindow(URL(string: raw)), raw)
    }
    XCTAssertFalse(PopupPolicy.allowsDocumentWindow(nil))
  }

  func testWindowSourceRequiresExactFigmaOrigin() {
    for raw in [
      "https://figma.com/design/source", "https://www.figma.com/files",
      "https://figma.com:443/login",
    ] {
      XCTAssertTrue(PopupPolicy.isFigmaPage(URL(string: raw)), raw)
    }
    for raw in [
      "http://figma.com", "https://figma.com.evil.test", "https://plugin.figma.com",
      "https://figma.com:444", "https://u:p@figma.com", "about:blank",
    ] {
      XCTAssertFalse(PopupPolicy.isFigmaPage(URL(string: raw)), raw)
    }
  }

  func testDashboardEvidenceContainsOnlyFixedLabels() throws {
    let url = try XCTUnwrap(
      URL(
        string:
          "https://www.figma.com/files/private-account/recents?token=private-token&section=trash#private-fragment"
      ))
    let evidence = TabNavigationRouter.dashboardEvidence(url)
    XCTAssertTrue(evidence.contains("dashboardSection=recents"))
    XCTAssertTrue(evidence.contains("trashHint=true"))
    XCTAssertFalse(evidence.contains("private"))
    XCTAssertFalse(evidence.contains("token"))
  }

  func testNavigationBoundary() throws {
    for raw in ["https://www.figma.com/login", "https://idp.example.test/saml", "about:blank"] {
      XCTAssertTrue(PopupPolicy.allows(URL(string: raw)))
    }
    for raw in [
      "http://example.test", "javascript:alert(1)", "data:text/html,test",
      "about:config", "file:///tmp/auth.html", "folio://callback", "https://u:p@figma.com",
    ] { XCTAssertFalse(PopupPolicy.allows(URL(string: raw))) }
    XCTAssertFalse(PopupPolicy.allows(nil))
    let fixture = try XCTUnwrap(URL(string: "file:///bundle/auth-child.html"))
    XCTAssertTrue(PopupPolicy.allows(fixture, localURLs: [fixture]))
    XCTAssertFalse(
      PopupPolicy.allows(URL(string: "file:///bundle/other.html"), localURLs: [fixture]))
  }

  func testGoogleClassificationHasExactOriginAndRoutes() {
    for raw in [
      "https://accounts.google.com/o/oauth2/v2/auth",
      "https://accounts.google.com/signin/oauth/error?error=disallowed_useragent",
      "https://accounts.google.com/o/oauth2/auth",
    ] { XCTAssertTrue(PopupPolicy.isGoogleOAuth(URL(string: raw))) }
    for raw in [
      "https://accounts.google.com.evil.test/signin/oauth/error?error=disallowed_useragent",
      "http://accounts.google.com/o/oauth2/auth", "https://accounts.google.com/o/saml2",
      "https://accounts.google.com/o/oauth2not-auth",
      "https://www.figma.com/login?error=disallowed_useragent",
    ] { XCTAssertFalse(PopupPolicy.isGoogleOAuth(URL(string: raw))) }
    XCTAssertFalse(PopupPolicy.isGoogleEmbeddedError(nil))
    XCTAssertFalse(
      PopupPolicy.isGoogleEmbeddedError(
        URL(
          string:
            "https://accounts.google.com/signin/oauth/error?error=access_denied")))

  }

  func testHostRedaction() {
    XCTAssertEqual(
      PopupPolicy.hostLabel(
        URL(
          string:
            "https://employee.private-company.test/saml?code=secret#token")), "External site")
    XCTAssertEqual(
      PopupPolicy.hostLabel(
        URL(
          string:
            "https://www.figma.com/login?code=secret")), "www.figma.com")
    XCTAssertEqual(PopupPolicy.hostLabel(URL(string: "file:///private/path")), "Local test page")
  }

  @MainActor
  func testConfigurationIsolationAndCloseRelease() async throws {
    let config = WebViewConfiguration.make(mode: .normal, bridge: ScriptBridge())
    let parentPreferences = config.preferences
    parentPreferences.javaScriptCanOpenWindowsAutomatically = true
    let original = config.userContentController
    weak var released: WKWebView?
    autoreleasepool {
      let popup = PopupController(configuration: config, url: URL(string: "about:blank"))
      released = popup.browser
      XCTAssertEqual(original.userScripts.count, 15)
      XCTAssertTrue(popup.browser?.configuration.userContentController.userScripts.isEmpty == true)
      XCTAssertFalse(popup.browser?.configuration.userContentController === original)
      XCTAssertTrue(popup.browser?.configuration.websiteDataStore === config.websiteDataStore)
      XCTAssertFalse(
        popup.browser?.configuration.preferences.javaScriptCanOpenWindowsAutomatically == true)
      XCTAssertTrue(parentPreferences.javaScriptCanOpenWindowsAutomatically)
      popup.close()
      XCTAssertNil(popup.browser)
    }
    // WebKit may retain a new view until its pending main-run-loop work finishes.
    for _ in 0..<40 {
      if released == nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertNil(released)
  }

  @MainActor
  func testOnePopupScriptCloseAndReopen() throws {
    let controller = FigmaWebViewController()
    controller.loadViewIfNeeded()
    let first = try XCTUnwrap(
      controller.openPopup(
        configuration: WKWebViewConfiguration(),
        url: URL(string: "about:blank")))
    XCTAssertNil(
      controller.openPopup(
        configuration: WKWebViewConfiguration(),
        url: URL(string: "about:blank")))
    let popup = try XCTUnwrap(controller.popup)
    XCTAssertTrue(controller.webView.accessibilityElementsHidden)
    popup.webViewDidClose(controller.webView)
    XCTAssertNotNil(controller.popup)
    popup.webViewDidClose(first)
    XCTAssertNil(controller.popup)
    XCTAssertFalse(controller.webView.accessibilityElementsHidden)
    XCTAssertNil(first.uiDelegate)
    XCTAssertNil(first.navigationDelegate)
    XCTAssertNotNil(
      controller.openPopup(
        configuration: WKWebViewConfiguration(),
        url: URL(string: "about:blank")))
    controller.popup?.close()
  }

  @MainActor
  func testChildDeathDoesNotReloadOrCrashParentAndParentDeathClosesChild() throws {
    let controller = FigmaWebViewController()
    controller.loadViewIfNeeded()
    let child = try XCTUnwrap(
      controller.openPopup(
        configuration: WKWebViewConfiguration(),
        url: URL(string: "about:blank")))
    let popup = try XCTUnwrap(controller.popup)
    popup.webViewWebContentProcessDidTerminate(child)
    XCTAssertEqual(
      popup.message,
      "This window stopped. The cause is unavailable. Close it and try again.")
    XCTAssertNil(popup.browser)
    XCTAssertNil(child.uiDelegate)
    XCTAssertNil(child.navigationDelegate)
    XCTAssertNotNil(controller.popup)
    controller.webViewWebContentProcessDidTerminate(controller.webView)
    XCTAssertNil(controller.popup)
    XCTAssertNil(popup.browser)
  }

  @MainActor
  func testControllerWithPopupReleases() {
    weak var released: FigmaWebViewController?
    weak var child: PopupController?
    autoreleasepool {
      let controller = FigmaWebViewController()
      controller.loadViewIfNeeded()
      _ = controller.openPopup(
        configuration: WKWebViewConfiguration(), url: URL(string: "about:blank"))
      released = controller
      child = controller.popup
    }
    XCTAssertNil(released)
    XCTAssertNil(child)
  }

  @MainActor
  func testGoogleNavigationIsCancelledByRealWebKitDelegate() async throws {
    let popup = PopupController(
      configuration: WKWebViewConfiguration(), url: URL(string: "about:blank"))
    let child = try XCTUnwrap(popup.browser)
    // Synthetic authorization URL, no account or credential data. Policy must cancel before loading.
    child.load(
      URLRequest(url: try XCTUnwrap(URL(string: "https://accounts.google.com/o/oauth2/auth"))))
    for _ in 0..<100 {
      if popup.message != nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(popup.message, PopupPolicy.googleMessage)
    XCTAssertNil(popup.browser)
    XCTAssertNil(child.url)
    XCTAssertNil(child.navigationDelegate)
    popup.close()
  }

  @MainActor
  func testTerminalMessageReleasesBrowserAndIgnoresLateFailures() throws {
    let popup = PopupController(
      configuration: WKWebViewConfiguration(), url: URL(string: "about:blank"))
    let child = try XCTUnwrap(popup.browser)
    popup.showMessage(PopupPolicy.googleMessage)
    XCTAssertNil(popup.browser)
    XCTAssertNil(child.navigationDelegate)
    XCTAssertNil(child.uiDelegate)
    XCTAssertNil(child.superview)
    popup.webView(
      child, didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
    popup.webView(child, didFail: nil, withError: URLError(.networkConnectionLost))
    popup.webViewWebContentProcessDidTerminate(child)
    XCTAssertEqual(popup.message, PopupPolicy.googleMessage)
    popup.close()
  }

  @MainActor
  func testCommittedFailureAndUnrelatedFailureHandling() throws {
    let popup = PopupController(
      configuration: WKWebViewConfiguration(), url: URL(string: "about:blank"))
    let child = try XCTUnwrap(popup.browser)
    popup.webView(
      WKWebView(), didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
    popup.webView(child, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
    XCTAssertNil(popup.message)
    XCTAssertNotNil(popup.browser)
    popup.webView(child, didFail: nil, withError: URLError(.networkConnectionLost))
    XCTAssertEqual(popup.message, "This window could not load. Close it and try again.")
    XCTAssertNil(popup.browser)
    popup.close()
  }

  @MainActor
  func testGoogleMessageAndRejectedInitialSchemes() throws {
    let controller = FigmaWebViewController()
    controller.loadViewIfNeeded()
    XCTAssertNil(
      controller.openPopup(
        configuration: WKWebViewConfiguration(),
        url: URL(string: "javascript:alert(1)")))
    XCTAssertNil(
      controller.openPopup(
        configuration: WKWebViewConfiguration(),
        url: URL(
          string: "https://accounts.google.com/signin/oauth/error?error=disallowed_useragent")))
    XCTAssertEqual(controller.popup?.message, PopupPolicy.googleMessage)
    XCTAssertNil(controller.popup?.browser)
    controller.popup?.close()
  }
}
