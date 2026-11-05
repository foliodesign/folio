import UIKit
import XCTest

@testable import Folio

/// Observe the public UIKit removal callback independently of the state guard.
@MainActor
private final class MenuRemovalWindow: UIWindow {
  private var removals: [ObjectIdentifier: XCTestExpectation] = [:]

  func removal(of view: UIView) -> XCTestExpectation {
    let removed = XCTestExpectation(description: "UIKit removed exact chrome menu")
    if view.superview == nil {
      removed.fulfill()
    } else {
      removals[ObjectIdentifier(view)] = removed
    }
    return removed
  }

  override func willRemoveSubview(_ subview: UIView) {
    super.willRemoveSubview(subview)
    removals.removeValue(forKey: ObjectIdentifier(subview))?.fulfill()
  }
}

@MainActor
final class ChromeMenuFocusTests: XCTestCase {
  private final class ResponderView: UIView {
    override var canBecomeFirstResponder: Bool { true }
  }

  private func withWindow(_ exercise: (UIWindow, UIView) async throws -> Void) async throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = MenuRemovalWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer {
      ChromeMenuPresenter.dismissOpen(in: window)
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    try await exercise(window, controller.view)
  }

  private func waitForDismissal(_ menu: ChromeMenuPresenter, in window: UIWindow) async {
    guard let observedWindow = window as? MenuRemovalWindow else {
      XCTFail("Missing UIKit removal observer")
      return
    }
    // Keep the original five-second state guard after the actual UIKit callback.
    await fulfillment(of: [observedWindow.removal(of: menu)], timeout: 15)
    let removed = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in MainActor.assumeIsolated { menu.superview == nil } },
      object: nil)
    await fulfillment(of: [removed], timeout: 5)
  }

  func testDismissReturnsFocusBeforeMenuActionAndNeverOverridesItsDestination() async throws {
    try await withWindow { window, root in
      let source = ResponderView()
      let destination = ResponderView()
      root.addSubview(source)
      root.addSubview(destination)
      XCTAssertTrue(source.becomeFirstResponder())
      let menu = ChromeMenuPresenter.present(in: window, below: .zero, items: { [] })
      XCTAssertTrue(menu.isFirstResponder)
      menu.dismiss()
      // activate(_:in:) runs its action immediately after dismiss(), before the fade ends.
      XCTAssertTrue(source.isFirstResponder, "Return focus before the action captures its owner")
      XCTAssertTrue(destination.becomeFirstResponder())
      await waitForDismissal(menu, in: window)
      XCTAssertTrue(destination.isFirstResponder, "The fade must not refocus the old page")
      XCTAssertNil(menu.superview)
    }
  }

  func testDismissDoesNotStealNativeFieldFocusAndIsIdempotent() async throws {
    try await withWindow { window, root in
      let source = ResponderView()
      let field = UITextField()
      root.addSubview(source)
      root.addSubview(field)
      XCTAssertTrue(source.becomeFirstResponder())
      let menu = ChromeMenuPresenter.present(in: window, below: .zero, items: { [] })
      XCTAssertTrue(field.becomeFirstResponder())
      menu.dismiss()
      menu.dismiss()
      await waitForDismissal(menu, in: window)
      XCTAssertTrue(field.isFirstResponder)
      XCTAssertNil(menu.superview)
    }
  }

  func testDismissSkipsDetachedSourceAndPreservesSuccessorMenu() async throws {
    try await withWindow { window, root in
      let source = ResponderView()
      root.addSubview(source)
      XCTAssertTrue(source.becomeFirstResponder())
      let menu = ChromeMenuPresenter.present(in: window, below: .zero, items: { [] })
      source.removeFromSuperview()
      let successor = ChromeMenuPresenter.present(in: window, below: .zero, items: { [] })
      menu.dismiss()
      await waitForDismissal(menu, in: window)
      XCTAssertTrue(successor.isFirstResponder)
      successor.dismiss()
      await waitForDismissal(successor, in: window)
    }
  }

  func testDismissDoesNotRestoreHiddenSourceOrRemainAnEscapeTarget() async throws {
    try await withWindow { window, root in
      let source = ResponderView()
      let container = UIView()
      root.addSubview(container)
      container.addSubview(source)
      XCTAssertTrue(source.becomeFirstResponder())
      let menu = ChromeMenuPresenter.present(in: window, below: .zero, items: { [] })
      XCTAssertNotNil(FolioEscape.action(in: window))
      container.isHidden = true
      menu.dismiss()
      XCTAssertNil(FolioEscape.action(in: window))
      await waitForDismissal(menu, in: window)
      XCTAssertFalse(source.isFirstResponder)
    }
  }

  func testCloseKeyCommandRoutesFromMenuAndPreservesDestinationFocus() async throws {
    try await withWindow { window, _ in
      let name = "folio.menu.focus.\(UUID())"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
      let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: memoryURL)
      }
      let controller = BrowserWindowController(
        session: WindowSession(defaults: defaults, migrateLegacy: false),
        websiteDataStore: .nonPersistent(), memory: MemoryLabStore(url: memoryURL), useFixture: true
      )
      window.rootViewController = controller
      controller.loadViewIfNeeded()
      let tab = controller.addTab(
        url: try XCTUnwrap(URL(string: "https://www.figma.com/design/fixture1")))
      controller.view.layoutIfNeeded()
      let source = try XCTUnwrap(controller.children.first as? FigmaWebViewController)
      let sourceBrowser = try XCTUnwrap(source.webView)
      XCTAssertTrue(sourceBrowser.becomeFirstResponder())
      let menu = ChromeMenuPresenter.present(in: window, below: .zero, items: { [] })
      let flags: UIKeyModifierFlags = [.control, .command]
      let commands: [UIKeyCommand] = controller.keyCommands ?? []
      let command = commands.first { command in
        command.input == "w" && command.modifierFlags == flags
      }
      let close = try XCTUnwrap(command)
      let action = try XCTUnwrap(close.action)
      XCTAssertTrue(
        menu.target(forAction: action, withSender: close) as? BrowserWindowController
          === controller)
      _ = controller.perform(action)
      XCTAssertFalse(controller.session.tabs.contains { $0.id == tab.id })
      XCTAssertEqual(controller.session.selectedID, controller.session.home.id)
      let destination = try XCTUnwrap(controller.children.first as? FigmaWebViewController)
      let browser = try XCTUnwrap(destination.webView)
      // Isolate dismissal from fixture navigation readiness. This is the destination's
      // normal focus acquisition, not a claim that a page finished loading.
      XCTAssertTrue(browser.becomeFirstResponder())
      await waitForDismissal(menu, in: window)
      let responder = BrowserResponderFocus.first(in: window)
      XCTAssertTrue(responder === browser || responder?.isDescendant(of: browser) == true)
      XCTAssertNil(sourceBrowser.window)
      destination.closeTab()
    }
  }
}
