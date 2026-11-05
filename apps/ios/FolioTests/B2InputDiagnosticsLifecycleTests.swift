import UIKit
import XCTest

@testable import Folio

@MainActor
final class B2InputDiagnosticsLifecycleTests: XCTestCase {
  func testCloseThenLateAdaptiveCallbackDoesNotRestoreTwiceOrClearSiblingCallback() throws {
    let suite = "folio.b2input.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: memoryURL)
    }
    let store = DiagnosticsStore(
      session: SessionState(defaults: defaults), strategies: InputStrategies(defaults: defaults),
      memory: MemoryLabStore(url: memoryURL))
    let first = DeveloperToolsController(store: store)
    let next = DeveloperToolsController(store: store)
    var completed: [String] = []
    first.onDismiss = { completed.append("first") }
    next.onDismiss = { completed.append("next") }
    // Model UIKit close completion followed by a delayed adaptive notification.
    first.completeDismissal()
    let presentation = UIPresentationController(
      presentedViewController: first, presenting: UIViewController())
    first.presentationControllerDidDismiss(presentation)
    XCTAssertEqual(completed, ["first"])
    XCTAssertNil(first.onDismiss)
    XCTAssertNotNil(next.onDismiss)
    next.completeDismissal()
    first.completeDismissal()
    XCTAssertEqual(completed, ["first", "next"])
  }

  func testAdaptiveCallbackThenCloseCompletionIsOneShotAndReleasesCapture() throws {
    let suite = "folio.b2input.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: memoryURL)
    }
    let panel = DeveloperToolsController(
      store: DiagnosticsStore(
        session: SessionState(defaults: defaults), strategies: InputStrategies(defaults: defaults),
        memory: MemoryLabStore(url: memoryURL)))
    var owner: NSObject? = NSObject()
    weak var released = owner
    var calls = 0
    panel.onDismiss = { [owner] in
      XCTAssertNotNil(owner)
      calls += 1
    }
    owner = nil
    XCTAssertNotNil(released)
    panel.presentationControllerDidDismiss(
      UIPresentationController(presentedViewController: panel, presenting: UIViewController()))
    panel.completeDismissal()
    XCTAssertEqual(calls, 1)
    XCTAssertNil(panel.onDismiss)
    XCTAssertNil(released)
  }
}
