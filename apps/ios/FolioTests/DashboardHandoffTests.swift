import WebKit
import XCTest

@testable import Folio

@MainActor
final class DashboardHandoffTests: XCTestCase {
  private let file = URL(string: "https://www.figma.com/design/source")!
  private let dashboard = URL(string: "https://www.figma.com/files")!

  private func withSource(
    _ body: (BrowserWindowController, FigmaWebViewController) throws -> Void
  ) throws {
    let name = "folio.handoff.tests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: memoryURL)
    }
    let session = WindowSession(defaults: defaults, migrateLegacy: false)
    let host = BrowserWindowController(
      session: session, websiteDataStore: .nonPersistent(),
      memory: MemoryLabStore(url: memoryURL), useFixture: true)
    host.loadViewIfNeeded()
    host.openExternalLink(file)
    let source = try XCTUnwrap(host.children.first as? FigmaWebViewController)
    defer {
      if source.webView != nil { source.closeTab() }
      for child in host.children {
        if let child = child as? FigmaWebViewController, child.webView != nil {
          child.closeTab()
        }
      }
    }
    source.onDocumentDashboardObserved?(dashboard)
    XCTAssertEqual(session.selectedID, session.home.id)
    try body(host, source)
  }

  private func seedReload(_ source: FigmaWebViewController) throws {
    // A first-party simulated response, never a Figma request. Seed only the tracked
    // navigation state because TabFixture deliberately bypasses the network reload path.
    let navigation = try XCTUnwrap(
      source.webView.loadSimulatedRequest(
        URLRequest(url: file), responseHTML: TabFixture.html(number: 1)))
    source.dashboardReload = FigmaWebViewController.DashboardReload(
      navigation: navigation, key: "source", generation: source.webGeneration,
      deadline: Date().addingTimeInterval(30), started: true, committed: true)
  }

  func testSettledDashboardRejectsInactiveSourceWithoutReopenHistory() throws {
    try withSource { host, source in
      try seedReload(source)
      XCTAssertEqual(host.session.tabs.count, 2)
      XCTAssertTrue(source.observeDashboardReload(dashboard, finished: true))
      XCTAssertEqual(host.session.tabs.map(\.id), [host.session.home.id])
      XCTAssertFalse(host.session.canReopenClosedTab)
    }
  }

  func testBackToFilesKeepsSourceInItsOriginalPosition() throws {
    try withSource { host, source in
      let order = host.session.tabs.map(\.id)
      let browser = source.webView
      try seedReload(source)
      // No HTTP rejection: the same-file result restores the retained tab.
      XCTAssertFalse(source.observeDashboardReload(file, finished: true))
      XCTAssertEqual(source.dashboardReload?.hidesTab, false)
      XCTAssertEqual(host.session.tabs.map(\.id), order)
      XCTAssertEqual(host.session.selectedID, host.session.home.id)
      XCTAssertTrue(source.webView === browser)
    }
  }

  func testSameFile200CanvasRestoresHiddenSource() throws {
    try withSource { host, source in
      let order = host.session.tabs.map(\.id)
      try seedReload(source)
      source.dashboardReload?.responseStatus = 200
      let restored = expectation(description: "Positive local canvas restores retained source")
      let render = source.onDashboardReloadVisibilityChanged
      source.onDashboardReloadVisibilityChanged = {
        render?()
        if source.dashboardReload?.hidesTab == false { restored.fulfill() }
      }
      defer { source.onDashboardReloadVisibilityChanged = render }
      wait(for: [restored], timeout: 10)
      XCTAssertEqual(host.session.tabs.map(\.id), order)
      XCTAssertEqual(host.session.selectedID, host.session.home.id)
      XCTAssertFalse(host.session.canReopenClosedTab)
    }
  }

  func testSelectedSourceRejectsStaleDashboardCompletion() throws {
    try withSource { host, source in
      try seedReload(source)
      source.setTabActive(true)
      XCTAssertFalse(source.observeDashboardReload(dashboard, finished: true))
      XCTAssertNil(source.dashboardReload)
      XCTAssertEqual(host.session.tabs.count, 2)
    }
  }

  func testProtectedSourceIsRetainedAtFinalCloseCallback() throws {
    try withSource { host, source in
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      source.setTabActive(true)
      XCTAssertNotNil(
        source.openPopup(configuration: configuration, url: URL(string: "about:blank")))
      source.setTabActive(false)
      XCTAssertTrue(source.hasProtectedTabWork)
      source.onDashboardReloadRejected?()
      XCTAssertEqual(host.session.tabs.count, 2)
      XCTAssertFalse(host.session.canReopenClosedTab)
    }
  }
}
