import WebKit
import XCTest

@testable import Folio

@MainActor
final class B6TabsTests: XCTestCase {
  private func isolated(_ run: (UserDefaults) throws -> Void) rethrows {
    let name = "folio.b6.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try run(defaults)
  }

  func testCreationIntentsDoNotDeduplicateOrPersistNewAsFileKey() {
    isolated { defaults in
      let window = WindowSession(defaults: defaults)
      let first = window.openFile(url: TabNavigationRouter.newDesignURL)
      let second = window.openFile(url: TabNavigationRouter.newDesignURL)
      XCTAssertNotEqual(first.id, second.id)
      XCTAssertTrue(first.creatingFile)
      XCTAssertEqual(window.tabs.count, 3)
      for route in ["design", "file"] {
        let url = URL(string: "https://figma.com/\(route)/new")!
        XCTAssertEqual(TabNavigationRouter.classify(url), .creation)
        _ = window.openFile(url: url)
        _ = window.openFile(url: url)
        XCTAssertEqual(
          defaults.string(forKey: WindowSession.restorationKey),
          SessionState.startURL.absoluteString)
      }
      XCTAssertEqual(window.tabs.count, 7)
      let real = URL(string: "https://figma.com/design/RealKey")!
      XCTAssertNil(window.resolveCreation(first.id, url: real))
      XCTAssertFalse(first.creatingFile)
      XCTAssertTrue(window.openFile(url: real) === first)
      window.select(second.id)
      XCTAssertEqual(window.resolveCreation(second.id, url: real), second.id)
      XCTAssertEqual(window.selectedID, first.id)
      XCTAssertFalse(window.tabs.contains { $0.id == second.id })
      XCTAssertFalse(window.close(window.home.id))
    }
  }

  func testOldCreationCheckpointCannotCreateAnotherFileOnRelaunch() {
    for route in ["design", "file"] {
      isolated { defaults in
        defaults.set("https://www.figma.com/\(route)/new", forKey: WindowSession.restorationKey)
        let window = WindowSession(defaults: defaults)
        XCTAssertEqual(window.tabs.count, 1)
        XCTAssertEqual(window.selectedID, window.home.id)
        XCTAssertEqual(
          defaults.string(forKey: WindowSession.restorationKey),
          SessionState.startURL.absoluteString)
      }
    }
  }

  func testOrdinaryHomeNavigationAndExcludedRequests() {
    let destination = URL(string: "https://figma.com/design/RealKey")!
    for kind in [WKNavigationType.linkActivated, .other, .backForward, .reload] {
      XCTAssertEqual(
        TabNavigationRouter.action(
          home: true, currentURL: SessionState.startURL,
          input: .init(destination: destination, kind: kind)), .openFile)
    }
    for input in [
      TabNavigationRouter.Input(destination: destination, method: "POST", kind: .other),
      .init(destination: destination, mainFrame: false, kind: .other),
      .init(destination: destination, download: true, kind: .other),
    ] {
      XCTAssertEqual(
        TabNavigationRouter.action(home: true, currentURL: SessionState.startURL, input: input),
        .allow)
    }
    for raw in [
      "https://figma.new.evil.test", "https://figma.new/design/new",
      "https://user@figma.new", "https://figma.new:444", "http://figma.new",
      "https://figma.com/design/key%2Fsecret", "https://evil.test/design/key",
    ] {
      XCTAssertEqual(TabNavigationRouter.classify(URL(string: raw)!), .external)
    }
  }

  func testChromeHasIconOnlyHomeCreateAndIndependentCloseActions() {
    isolated { defaults in
      let session = WindowSession(defaults: defaults, migrateLegacy: false)
      let first = session.openFile(url: URL(string: "https://figma.com/design/First")!)
      let second = session.openFile(url: URL(string: "https://figma.com/board/Second")!)
      let chrome = BrowserChromeView()
      chrome.render(
        B3BrowserChromeState(
          tabs: session.tabs.map {
            .init(
              id: $0.id, home: $0.kind == .home, title: $0.displayTitle, pinned: $0.isPinned,
              symbol: ChromeFileIcon.symbol(for: $0.routingURL))
          }, selectedID: second.id, canGoBack: false, canGoForward: false, loading: false))
      @MainActor func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
      }
      let views = descendants(chrome)
      let controls = views.compactMap { $0 as? UIButton }
      let home = views.first { $0.accessibilityIdentifier == "tab-0" } as? ChromeTabView
      XCTAssertEqual(home?.accessibilityLabel, "Home")
      XCTAssertFalse(home?.subviews.contains { $0 is UILabel } ?? true)
      XCTAssertTrue(home?.subviews.contains { ($0 as? UIImageView)?.image != nil } ?? false)
      XCTAssertFalse(home?.subviews.contains { $0 is UIButton } ?? true)
      var closed: UUID?
      chrome.onCloseTab = { closed = $0 }
      let firstTab = views.first { $0.accessibilityIdentifier == "tab-1" } as? ChromeTabView
      let close = firstTab?.subviews.compactMap { $0 as? UIButton }.first {
        $0.accessibilityLabel == "Close tab"
      }
      XCTAssertNotNil(close)
      close?.sendActions(for: .touchUpInside)
      XCTAssertEqual(closed, first.id)
      var created = 0
      chrome.onCreateDesign = { created += 1 }
      let create = controls.first { $0.accessibilityIdentifier == "browser-create-design" }
      XCTAssertEqual(create?.accessibilityLabel, "New Design file")
      create?.sendActions(for: .touchUpInside)
      create?.sendActions(for: .touchUpInside)
      XCTAssertEqual(created, 2)
      XCTAssertEqual(
        ChromeFileIcon.symbol(for: URL(string: "https://evil.test/board/key")), "doc")
      XCTAssertEqual(
        ChromeFileIcon.symbol(for: URL(string: "https://www.figma.com/design/key/Name?m=dev")),
        ChromeFileIcon.dev)
      XCTAssertEqual(
        ChromeFileIcon.symbol(for: URL(string: "https://www.figma.com/design/key/Name?m=auto")),
        ChromeFileIcon.design)
    }
  }

  func testEvidenceRedactsEveryRouteAndArbitraryMethod() {
    let url = URL(
      string: "https://figma.com/design/SecretKey/SecretTitle?token=SecretQuery#SecretFragment")!
    let observed = TabNavigationRouter.evidence(.observedURL, url: url)
    XCTAssertTrue(observed.contains("target=none"))
    XCTAssertTrue(observed.contains("sourceMain=none"))
    for event in [
      TabNavigationRouter.Event.trustedAnchor, .navigationAction, .nilTargetChild,
      .blankPromotion, .observedURL, .redirect,
    ] {
      let line = TabNavigationRouter.evidence(
        event, url: url,
        input: .init(destination: url, method: "SecretMethod", kind: .other))
      XCTAssertFalse(line.contains("Secret"))
      XCTAssertTrue(line.contains("destination=file"))
      XCTAssertTrue(line.contains("method=other"))
    }
  }

  func testEvidenceIsOptInBoundedAndObservationNeverManufacturesTab() {
    isolated { defaults in
      let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: file) }
      let controller = FigmaWebViewController(
        tab: TabSession(
          kind: .home,
          url: SessionState.startURL, defaults: defaults), memory: MemoryLabStore(url: file))
      let url = URL(string: "https://figma.com/design/SecretKey")!
      XCTAssertFalse(controller.handoffObservedURL(url))
      XCTAssertTrue(controller.routeEvidence.isEmpty)
      controller.diagnostics.inputLogging = true
      for _ in 0..<300 { XCTAssertFalse(controller.handoffObservedURL(url)) }
      XCTAssertEqual(controller.routeEvidence.count, 128)
      XCTAssertFalse(controller.routeEvidence.joined().contains("SecretKey"))
      XCTAssertNil(controller.tabSession.displayTitle)
    }
  }
}
