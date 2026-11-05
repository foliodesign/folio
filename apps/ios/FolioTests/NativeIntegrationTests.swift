import UIKit
import WebKit
import XCTest

@testable import Folio

final class NativeIntegrationTests: XCTestCase {
  func testStrictLinkBoundary() throws {
    for value in [
      "http://figma.com/design/key", "https://figma.com.evil.test/design/key",
      "https://evilfigma.com/", "https://user:pass@figma.com/design/key",
      "https://figma.com:444/", "file:///figma.com", "https://figma.com./",
    ] {
      XCTAssertNil(FolioLink.validated(try XCTUnwrap(URL(string: value))), value)
    }
    for value in ["https://figma.com/design/key?node-id=1#x", "https://www.figma.com:443/files"] {
      XCTAssertNotNil(FolioLink.validated(try XCTUnwrap(URL(string: value))))
    }
  }

  func testSchemeRejectsAmbiguousPayloads() throws {
    for value in [
      "folio://open?url=https%3A%2F%2Fevil.test",
      "folio://open?url=https%3A%2F%2Ffigma.com&url=https%3A%2F%2Ffigma.com",
      "folio://open/path?url=https%3A%2F%2Ffigma.com",
      "folio://user@open?url=https%3A%2F%2Ffigma.com",
      "folio://open?url=https%3A%2F%2Ffigma.com#x", "folio://other?url=https%3A%2F%2Ffigma.com",
    ] { XCTAssertNil(FolioLink.decode(try XCTUnwrap(URL(string: value))), value) }
    XCTAssertEqual(
      FolioLink.decode(
        try XCTUnwrap(
          URL(string: "folio://open?url=https%3A%2F%2Fwww.figma.com%2Fdesign%2Fkey%3Fnode-id%3D1")))?
        .absoluteString,
      "https://www.figma.com/design/key?node-id=1")
  }

  @MainActor
  func testShareInboxIsSanitizedAndConsumedOnce() throws {
    let name = "folio.native.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let inbox = SharedLinkInbox(defaults: defaults)
    XCTAssertTrue(
      inbox.save(
        try XCTUnwrap(URL(string: "https://figma.com/design/key/Private?token=secret#fragment"))))
    XCTAssertEqual(defaults.string(forKey: "pendingRoute"), "https://www.figma.com/design/key")
    XCTAssertEqual(inbox.take()?.absoluteString, "https://www.figma.com/design/key")
    XCTAssertNil(inbox.take())
    XCTAssertFalse(inbox.save(try XCTUnwrap(URL(string: "https://evil.test"))))
    defaults.set("https://evil.test/", forKey: "pendingRoute")
    XCTAssertNil(inbox.take())
  }

  @MainActor
  func testFreshBrowserWindowRestoresDurableSelectedFileRoute() throws {
    let name = "folio.restore.\(UUID())"
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: memoryURL)
    }
    var first: UserDefaults? = try XCTUnwrap(UserDefaults(suiteName: name))
    first?.set("https://www.figma.com/design/legacy", forKey: "folio.lastURL")
    weak var oldHost: BrowserWindowController?
    autoreleasepool {
      // Exercise the host's production session factory, without loading a network page.
      let host = BrowserWindowController(
        memory: MemoryLabStore(url: memoryURL), defaults: first!)
      oldHost = host
      let tab = host.session.add(url: URL(string: "https://figma.com/design/opened")!)
      _ = host.session.add(url: URL(string: "https://figma.com/design/other")!)
      host.session.select(tab.id)
      tab.session.lastURL = URL(string: "https://figma.com/design/key/Title?token=x#node-id=1")!
    }
    XCTAssertNil(oldHost)
    first = nil
    let second = try XCTUnwrap(UserDefaults(suiteName: name))
    let restored = BrowserWindowController(
      memory: MemoryLabStore(url: memoryURL), defaults: second)
    XCTAssertEqual(restored.session.tabs.count, 4)
    XCTAssertEqual(
      restored.session.selected.recoveryURL.absoluteString, "https://www.figma.com/design/key")
    XCTAssertEqual(
      second.string(forKey: WindowSession.restorationKey), "https://www.figma.com/design/key")
  }

  @MainActor
  func testColdHostExternalLinkLoadsFullURLExactlyOnce() throws {
    try assertExternalLinkLoadsOnce(warm: false)
  }

  @MainActor
  func testWarmHostExternalLinkLoadsFullURLExactlyOnce() throws {
    try assertExternalLinkLoadsOnce(warm: true)
  }

  @MainActor
  private func assertExternalLinkLoadsOnce(warm: Bool) throws {
    for mode in BrowserMode.allCases {
      let name = "folio.link-load.\(UUID())"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
      defer { defaults.removePersistentDomain(forName: name) }
      defaults.set(mode.rawValue, forKey: "folio.mode")
      let window = WindowSession(defaults: defaults, migrateLegacy: false)
      let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: memoryURL) }
      let host = BrowserWindowController(
        session: window, websiteDataStore: .nonPersistent(), memory: MemoryLabStore(url: memoryURL),
        makeWebView: { RecordingLinkWebView(frame: .zero, configuration: $0) })
      if warm { host.loadViewIfNeeded() }
      let url = try XCTUnwrap(
        URL(
          string: "https://figma.com/design/linkLoadKey/PrivateTitle?node-id=1%3A2#linkLoadFragment"
        ))
      host.openExternalLink(url)
      let controller = try XCTUnwrap(host.children.first as? FigmaWebViewController)
      let browser = try XCTUnwrap(controller.webView as? RecordingLinkWebView)
      // Observe the production host's actual WKWebView.load calls, including a cancelled first load.
      XCTAssertEqual(browser.requests.map(\.url), [url], mode.rawValue)
      XCTAssertEqual(window.tabs.count, 2)
      XCTAssertEqual(controller.tabSession.id, window.selectedID)
      let recovery = try XCTUnwrap(URL(string: "https://www.figma.com/design/linkLoadKey"))
      XCTAssertEqual(window.selected.recoveryURL, recovery)
      XCTAssertFalse(controller.diagnostics.report.contains("PrivateTitle"))
      XCTAssertFalse(controller.diagnostics.report.contains("node-id"))
      XCTAssertFalse(controller.diagnostics.report.contains("linkLoadFragment"))
      let persisted = String(describing: defaults.persistentDomain(forName: name))
      XCTAssertFalse(persisted.contains("PrivateTitle"))
      XCTAssertFalse(persisted.contains("node-id"))
      XCTAssertFalse(persisted.contains("linkLoadFragment"))

      window.select(window.home.id)
      host.showSelectedTab()
      window.select(controller.tabSession.id)
      host.showSelectedTab()
      XCTAssertEqual(browser.requests.map(\.url), [url])
      host.openExternalLink(try XCTUnwrap(URL(string: "https://evil.test/design/key")))
      XCTAssertEqual(window.tabs.count, 2)
      XCTAssertEqual(browser.requests.map(\.url), [url])

      // The full request is consumed once. Recovery still uses only the private-safe route.
      controller.webViewWebContentProcessDidTerminate(browser)
      XCTAssertEqual(browser.requests.map(\.url), [url, recovery])
      host.closeSelectedTab()
      (host.children.first as? FigmaWebViewController)?.closeTab()
    }
  }

  @MainActor
  func testFolioCommandsDoNotReserveEditorShortcutsOrPriority() throws {
    let commands = try XCTUnwrap(FigmaWebViewController().keyCommands)
    XCTAssertEqual(commands.count, 1)
    XCTAssertEqual(Set(commands.compactMap(\.input)), ["s"])
    for command in commands {
      XCTAssertEqual(command.modifierFlags, [.command, .alternate, .shift])
      XCTAssertFalse(command.wantsPriorityOverSystemBehavior)
    }
  }

  @MainActor
  func testExportFilenameCannotEscapeTemporaryDirectory() {
    XCTAssertEqual(DownloadHandler.filename("../../private.txt"), "private.txt")
    XCTAssertEqual(DownloadHandler.filename(".."), "export")
    XCTAssertEqual(DownloadHandler.filename("bad\\name\u{0}.txt"), "badname.txt")
    XCTAssertEqual(DownloadHandler.filename(""), "export")
  }
}

@MainActor
private final class RecordingLinkWebView: WKWebView {
  private(set) var requests: [URLRequest] = []

  override func load(_ request: URLRequest) -> WKNavigation? {
    requests.append(request)
    return nil
  }
}
