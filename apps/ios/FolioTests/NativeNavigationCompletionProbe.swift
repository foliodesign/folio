import WebKit
import XCTest

/// Observe the public loading completion without replacing the product's delegate.
/// Create before starting a navigation, or while the controller's initial load is active.
@MainActor
final class NativeNavigationCompletionProbe {
  private let completed = XCTestExpectation(description: "WebKit navigation loading completed")
  private var observation: NSKeyValueObservation?
  private var started = false
  private var finished = false

  init(_ browser: WKWebView) {
    observation = browser.observe(\.isLoading, options: [.initial, .new]) {
      [weak self] browser, _ in
      MainActor.assumeIsolated {
        guard let self, !self.finished else { return }
        if browser.isLoading { self.started = true }
        if self.started && !browser.isLoading {
          self.finished = true
          self.completed.fulfill()
        }
      }
    }
  }

  func waitSynchronously(file: StaticString = #filePath, line: UInt = #line) throws {
    defer { observation?.invalidate() }
    guard XCTWaiter.wait(for: [completed], timeout: 15) == .completed else {
      XCTFail("WebKit navigation completion missing", file: file, line: line)
      throw CocoaError(.fileReadUnknown)
    }
  }

  func wait(file: StaticString = #filePath, line: UInt = #line) async throws {
    let result = await XCTWaiter.fulfillment(of: [completed], timeout: 15)
    observation?.invalidate()
    guard result == .completed else {
      XCTFail("WebKit navigation completion missing", file: file, line: line)
      throw CocoaError(.fileReadUnknown)
    }
  }
}

@MainActor
enum NativeStateExpectation {
  /// Each asynchronous phase gets its own state expectation. Never reuse the
  /// navigation deadline for recorder, popup, or process completion.
  static func wait(
    _ description: String, timeout: TimeInterval = 5,
    file: StaticString = #filePath, line: UInt = #line,
    until condition: @escaping @MainActor () -> Bool
  ) async throws {
    if condition() { return }
    let expected = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
    expected.expectationDescription = description
    guard await XCTWaiter.fulfillment(of: [expected], timeout: timeout) == .completed else {
      XCTFail("State completion missing: " + description, file: file, line: line)
      throw CocoaError(.fileReadUnknown)
    }
  }
}
