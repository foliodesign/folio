import WebKit
import XCTest

@testable import Folio

@MainActor
final class TabSessionTests: XCTestCase {
  private func withDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
    let name = "folio.tabs.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try test(defaults)
  }

  func testMembershipSelectionAndCloseInvariants() {
    withDefaults { defaults in
      let window = WindowSession(defaults: defaults)
      let home = window.home
      XCTAssertEqual(window.selectedID, home.id)
      XCTAssertFalse(window.close(home.id))
      let first = window.add(url: URL(string: "https://www.figma.com/design/first")!)
      let second = window.add(url: URL(string: "https://www.figma.com/design/second")!)
      let third = window.add(url: URL(string: "https://www.figma.com/design/third")!)
      XCTAssertEqual(Set(window.tabs.map(\.id)).count, 4)
      window.select(first.id)
      window.select(UUID())
      XCTAssertEqual(window.selectedID, first.id)
      XCTAssertTrue(window.close(second.id))
      XCTAssertTrue(window.selected === first)
      XCTAssertEqual(window.tabs.map(\.id), [home.id, first.id, third.id])
      XCTAssertTrue(window.close(first.id))
      XCTAssertTrue(window.selected === third)
      XCTAssertTrue(window.close(third.id))
      XCTAssertTrue(window.selected === home)
      XCTAssertFalse(window.close(third.id))
      XCTAssertEqual(window.tabs.count, 1)
    }
  }

  func testTabNavigationModeInputAndRecoveryAreIndependent() {
    withDefaults { defaults in
      defaults.set("Compatibility", forKey: "folio.mode")
      let window = WindowSession(defaults: defaults)
      let first = window.add(
        url: URL(string: "https://www.figma.com/design/first/Title?token=secret")!)
      let second = window.add(url: URL(string: "https://www.figma.com/design/second")!)
      first.session.lastURL = URL(string: "https://www.figma.com/design/changed?token=secret#node")!
      first.session.mode = .safe
      first.strategies.fingerCanvasWheel = false
      first.strategies.trackpadPinchRoute = .gesture
      first.session.recordCrash()
      XCTAssertTrue(first.recovery.shouldReload(now: 1))
      XCTAssertTrue(first.recovery.shouldReload(now: 2))
      XCTAssertFalse(first.recovery.shouldReload(now: 3))
      XCTAssertTrue(second.recovery.shouldReload(now: 3))
      XCTAssertEqual(second.recoveryURL.path, "/design/second")
      XCTAssertEqual(first.recoveryURL.absoluteString, "https://www.figma.com/design/changed")
      XCTAssertEqual(second.session.mode, .compatibility)
      XCTAssertTrue(second.strategies.fingerCanvasWheel)
      XCTAssertEqual(second.strategies.trackpadPinchRoute, .wheel)
      XCTAssertEqual(defaults.string(forKey: "folio.trackpadPinchRoute"), "gesture")
      XCTAssertEqual(second.session.crashCount, 0)
      XCTAssertEqual(defaults.string(forKey: "folio.mode"), "Compatibility")
      XCTAssertNil(defaults.object(forKey: "folio.lastURL"))
      XCTAssertEqual(defaults.bool(forKey: "folio.fingerCanvasWheel"), false)
      XCTAssertEqual(window.home.recoveryURL, SessionState.startURL)
    }
  }

  func testWindowsDoNotShareMembershipOrSelection() {
    withDefaults { defaults in
      let first = WindowSession(defaults: defaults)
      let second = WindowSession(defaults: defaults)
      let tab = first.add(url: URL(string: "https://www.figma.com/design/first")!)
      second.select(tab.id)
      XCTAssertNotEqual(first.id, second.id)
      XCTAssertNotEqual(first.home.id, second.home.id)
      XCTAssertEqual(second.tabs.count, 1)
      XCTAssertEqual(second.selectedID, second.home.id)
    }
  }

  func testLegacyMigrationSanitizesAndNeverReceivesTabWrites() {
    withDefaults { defaults in
      let legacy = "https://www.figma.com/design/legacy/Private?token=secret#fragment"
      defaults.set(legacy, forKey: "folio.lastURL")
      let window = WindowSession(defaults: defaults)
      XCTAssertEqual(window.tabs.count, 2)
      XCTAssertEqual(
        window.selected.recoveryURL.absoluteString, "https://www.figma.com/design/legacy")
      window.selected.session.lastURL = URL(string: "https://www.figma.com/design/new")!
      XCTAssertEqual(
        defaults.string(forKey: "folio.lastURL"), "https://www.figma.com/design/legacy")
    }
    let seeds: [(String, String?)] = [
      ("invalid", nil), ("https://other.example/design/key", nil),
      ("https://www.figma.com/login?code=secret", SessionState.startURL.absoluteString),
      (SessionState.startURL.absoluteString, SessionState.startURL.absoluteString),
    ]
    for (value, sanitized) in seeds {
      // Full archives win over legacy routes since badbd0b. Each seed models a
      // separate first migration, rather than editing an already migrated archive.
      withDefaults { defaults in
        defaults.set(value, forKey: "folio.lastURL")
        let fresh = WindowSession(defaults: defaults)
        XCTAssertEqual(fresh.tabs.count, 1)
        XCTAssertEqual(fresh.selectedID, fresh.home.id)
        XCTAssertEqual(defaults.string(forKey: "folio.lastURL"), sanitized)
      }
    }
  }

  func testLegacySeedIsSanitizedWhenArchiveWinsOrRestorationIsDisabled() {
    for restore in [true, false] {
      withDefaults { defaults in
        let saved = WindowSession(defaults: defaults)
        let route = URL(string: "https://www.figma.com/design/saved")!
        saved.add(url: route)
        defaults.set(restore, forKey: "folio.restoreTabs")
        defaults.set(
          "https://www.figma.com/design/legacy/Private?token=secret#fragment",
          forKey: "folio.lastURL")
        let fresh = WindowSession(defaults: defaults)
        XCTAssertEqual(fresh.selected.recoveryURL, restore ? route : SessionState.startURL)
        XCTAssertEqual(
          defaults.string(forKey: "folio.lastURL"), "https://www.figma.com/design/legacy")
        fresh.selected.session.lastURL = URL(string: "https://www.figma.com/design/other")!
        XCTAssertEqual(
          defaults.string(forKey: "folio.lastURL"), "https://www.figma.com/design/legacy")
      }
    }
  }

  func testRestartUsesSelectionAndIgnoresBackgroundNavigation() {
    withDefaults { defaults in
      let window = WindowSession(defaults: defaults)
      let first = window.add(
        url: URL(string: "https://figma.com/design/first/Private?token=x#node")!)
      let second = window.add(url: URL(string: "https://figma.com/board/second")!)
      window.select(first.id)
      second.session.lastURL = URL(string: "https://figma.com/design/background")!
      first.session.lastURL = URL(string: "https://figma.com/proto/changed/Title?code=x#node")!
      first.session.lastURL = URL(string: "https://accounts.google.com/oauth?code=x")!
      window.select(UUID())
      XCTAssertEqual(
        WindowSession(defaults: defaults).selected.recoveryURL.absoluteString,
        "https://www.figma.com/proto/changed")
      window.select(second.id)
      XCTAssertEqual(
        WindowSession(defaults: defaults).selected.recoveryURL.absoluteString,
        "https://www.figma.com/design/background")
      XCTAssertEqual(first.recoveryURL.absoluteString, "https://www.figma.com/proto/changed")
      XCTAssertEqual(second.recoveryURL.absoluteString, "https://www.figma.com/design/background")
    }
  }

  func testCloseAndHomeSelectionPersistWithoutResurrectingLegacy() {
    withDefaults { defaults in
      defaults.set("https://www.figma.com/design/legacy", forKey: "folio.lastURL")
      let window = WindowSession(defaults: defaults)
      let tab = window.add(url: URL(string: "https://figma.com/design/new")!)
      XCTAssertTrue(window.close(tab.id))
      tab.session.lastURL = URL(string: "https://figma.com/design/closed")!
      XCTAssertEqual(
        WindowSession(defaults: defaults).selected.recoveryURL.path, "/design/legacy")
      window.select(window.home.id)
      let fresh = WindowSession(defaults: defaults)
      // Selecting Home keeps the other tabs in the scene archive.
      XCTAssertEqual(fresh.tabs.count, 2)
      XCTAssertEqual(fresh.selectedID, fresh.home.id)
      window.select(window.tabs[1].id)
      XCTAssertTrue(window.close(window.selectedID))
      let closed = WindowSession(defaults: defaults)
      XCTAssertEqual(closed.tabs.count, 1)
      XCTAssertEqual(closed.selectedID, closed.home.id)
    }
  }

  func testCheckpointReadSanitizesAndRejectsCorruptionWithoutLegacyFallback() {
    withDefaults { defaults in
      defaults.set("https://www.figma.com/design/legacy", forKey: "folio.lastURL")
      defaults.set(
        "https://user:pass@figma.com/design/key/Private?token=secret#fragment",
        forKey: WindowSession.restorationKey)
      XCTAssertEqual(WindowSession(defaults: defaults).selected.recoveryURL.path, "/design/key")
      XCTAssertEqual(
        defaults.string(forKey: WindowSession.restorationKey), "https://www.figma.com/design/key")
    }
    // Each case models first migration. An existing full archive correctly wins
    // over later mutations to the obsolete single-route checkpoint.
    for value in [
      "invalid", "https://other.example/design/key", "https://www.figma.com/login?code=secret",
      "https://www.figma.com/oauth?token=secret", "https://www.figma.com/design/%ZZ",
    ] {
      withDefaults { defaults in
        defaults.set("https://www.figma.com/design/legacy", forKey: "folio.lastURL")
        defaults.set(value, forKey: WindowSession.restorationKey)
        let fresh = WindowSession(defaults: defaults)
        XCTAssertEqual(fresh.tabs.count, 1, value)
        XCTAssertEqual(fresh.selectedID, fresh.home.id, value)
        XCTAssertEqual(
          defaults.string(forKey: WindowSession.restorationKey),
          SessionState.startURL.absoluteString)
      }
    }
    withDefaults { defaults in
      defaults.set(42, forKey: WindowSession.restorationKey)
      XCTAssertEqual(WindowSession(defaults: defaults).tabs.count, 1)
    }
  }

  func testFileOpenedInHomeRestoresAsDocumentAndAuthNeverPersists() {
    withDefaults { defaults in
      let window = WindowSession(defaults: defaults)
      let document = window.openFile(
        url: URL(string: "https://figma.com/design/dashboard/Title?token=x")!)
      let fresh = WindowSession(defaults: defaults)
      XCTAssertEqual(fresh.tabs.count, 2)
      XCTAssertEqual(fresh.selected.kind, .document)
      XCTAssertEqual(fresh.selected.recoveryURL.path, "/design/dashboard")
      document.session.lastURL = URL(string: "https://figma.com/login?code=secret#auth")!
      XCTAssertEqual(document.recoveryURL, SessionState.startURL)
      window.select(window.home.id)
      XCTAssertEqual(
        defaults.string(forKey: WindowSession.restorationKey), SessionState.startURL.absoluteString)
      let homeSelected = WindowSession(defaults: defaults)
      XCTAssertEqual(homeSelected.tabs.count, 1)
      XCTAssertEqual(homeSelected.selected.kind, .home)
      XCTAssertFalse(
        String(describing: defaults.dictionaryRepresentation()).contains("code=secret"))
    }
  }

  func testFixtureSessionNeitherRestoresNorOverwritesCheckpoint() {
    withDefaults { defaults in
      let route = "https://www.figma.com/design/saved"
      defaults.set(route, forKey: WindowSession.restorationKey)
      let fixture = WindowSession(defaults: defaults, migrateLegacy: false)
      XCTAssertEqual(fixture.tabs.count, 1)
      let tab = fixture.add(url: URL(string: "https://figma.com/design/fixture")!)
      tab.session.lastURL = URL(string: "https://figma.com/design/changed")!
      fixture.select(fixture.home.id)
      XCTAssertTrue(fixture.close(tab.id))
      XCTAssertEqual(defaults.string(forKey: WindowSession.restorationKey), route)
    }
  }

  func testHostAllowanceEvictionRequiresKnownLowReading() {
    XCTAssertFalse(BrowserWindowController.hostAllowanceRequiresEviction(nil))
    XCTAssertTrue(BrowserWindowController.hostAllowanceRequiresEviction(0))
    XCTAssertTrue(BrowserWindowController.hostAllowanceRequiresEviction(128 * 1024 * 1024 - 1))
    XCTAssertFalse(BrowserWindowController.hostAllowanceRequiresEviction(128 * 1024 * 1024))
    XCTAssertFalse(BrowserWindowController.hostAllowanceRequiresEviction(UInt64.max))
  }

  func testHostRetainsViewsAcrossSelectionAndReleasesClosedTab() {
    withDefaults { defaults in
      let window = WindowSession(defaults: defaults, migrateLegacy: false)
      let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: memoryURL) }
      let store = WKWebsiteDataStore.default()
      let host = BrowserWindowController(
        session: window, websiteDataStore: store, memory: MemoryLabStore(url: memoryURL),
        useFixture: true)
      host.loadViewIfNeeded()
      weak var firstController: FigmaWebViewController?
      weak var firstView: WKWebView?
      autoreleasepool {
        let first = host.addTab(url: URL(string: "https://www.figma.com/design/first")!)
        firstController = host.children.first as? FigmaWebViewController
        firstView = firstController?.webView
        let second = host.addTab(url: URL(string: "https://www.figma.com/design/second")!)
        XCTAssertFalse(firstController?.isTabActive ?? true)
        XCTAssertNil(firstView?.window)
        XCTAssertEqual(firstController?.snapshotAttempted, true)
        XCTAssertEqual(firstController?.snapshotPending, false)
        XCTAssertTrue(firstView?.configuration.websiteDataStore === store)
        window.select(first.id)
        host.showSelectedTab()
        XCTAssertTrue((host.children.first as? FigmaWebViewController) === firstController)
        XCTAssertTrue((host.children.first as? FigmaWebViewController)?.webView === firstView)
        window.select(second.id)
        host.showSelectedTab()
        window.select(first.id)
        host.showSelectedTab()
        host.closeSelectedTab()
        XCTAssertEqual(window.selectedID, second.id)
        host.closeSelectedTab()
        XCTAssertEqual(window.selectedID, window.home.id)
      }
      XCTAssertNil(firstController)
      let releaseStarted = Date()
      let deadline = releaseStarted.addingTimeInterval(2)
      while firstView != nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      print(
        "Closed detached WebView released=\(firstView == nil) after \(Date().timeIntervalSince(releaseStarted))s; snapshotPending=false"
      )
      XCTAssertNil(firstView)
    }
  }
}
