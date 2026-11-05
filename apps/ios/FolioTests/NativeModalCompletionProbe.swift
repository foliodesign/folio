import UIKit
import XCTest

/// Fixture-only observation of UIKit completion, independent of the completion
/// deliberately withheld from the download owner. State/ownership checks still
/// use their original deadlines after UIKit has finished its system transition.
@MainActor
final class NativeModalCompletionProbe {
  @MainActor
  private final class Request {
    let expectation: XCTestExpectation
    let started = Date()
    var completed = false

    init(_ controller: UIViewController) {
      expectation = XCTestExpectation(
        description: "UIKit presented " + String(describing: type(of: controller)))
    }
  }
  private enum WaitError: Error { case timedOut }
  private var observers: [(UIViewController) -> Void] = []
  private var requests: [ObjectIdentifier: Request] = [:]

  func completion(for controller: UIViewController) -> () -> Void {
    let request = Request(controller)
    requests[ObjectIdentifier(controller)] = request
    // Each callback owns its request. A stale completion cannot certify a retry
    // of the same controller or a successor's presentation.
    return {
      guard !request.completed else { return }
      request.completed = true
      print(
        "\(request.expectation.expectationDescription) completed after \(Date().timeIntervalSince(request.started)) s"
      )
      request.expectation.fulfill()
      for observer in self.observers { observer(controller) }
    }
  }

  var hasPending: Bool { requests.values.contains { !$0.completed } }

  static func hasTransitions(in windows: [UIWindow]) -> Bool {
    func active(_ controller: UIViewController?) -> Bool {
      guard let controller else { return false }
      return controller.transitionCoordinator != nil || active(controller.presentedViewController)
        || controller.children.contains { active($0) }
    }
    return windows.contains { active($0.rootViewController) }
  }

  /// Drain actual UIKit completions before starting the original state deadline.
  /// Owner acknowledgements remain independently controlled by each fixture.
  func waitForPending(file: StaticString = #filePath, line: UInt = #line) throws {
    while let request = requests.values.first(where: { !$0.completed }) {
      try wait(for: request.expectation, file: file, line: line)
    }
  }

  static func waitForTransitions(
    in windows: [UIWindow], file: StaticString = #filePath, line: UInt = #line
  ) throws {
    func transition(_ controller: UIViewController?) -> UIViewControllerTransitionCoordinator? {
      guard let controller else { return nil }
      if let coordinator = controller.transitionCoordinator { return coordinator }
      if let coordinator = transition(controller.presentedViewController) { return coordinator }
      return controller.children.compactMap { transition($0) }.first
    }
    for window in windows {
      while let coordinator = transition(window.rootViewController) {
        let finished = XCTestExpectation(description: "UIKit transition completed")
        guard coordinator.animate(alongsideTransition: nil, completion: { _ in finished.fulfill() })
        else { break }
        guard XCTWaiter.wait(for: [finished], timeout: 15) == .completed else {
          XCTFail("UIKit transition completion missing", file: file, line: line)
          throw WaitError.timedOut
        }
      }
    }
  }

  func expectPresentation(of type: UIViewController.Type) -> XCTestExpectation {
    let expected = XCTestExpectation(description: "UIKit completed " + String(describing: type))
    var fulfilled = false
    observers.append { controller in
      guard !fulfilled, controller.isKind(of: type) else { return }
      fulfilled = true
      expected.fulfill()
    }
    return expected
  }

  func wait(for expected: XCTestExpectation, file: StaticString = #filePath, line: UInt = #line)
    throws
  {
    guard XCTWaiter.wait(for: [expected], timeout: 15) == .completed else {
      XCTFail(
        "UIKit completion missing: " + expected.expectationDescription, file: file, line: line)
      throw WaitError.timedOut
    }
  }

  func present(
    _ host: UIViewController, _ controller: UIViewController,
    _ ownerCompletion: @escaping () -> Void, acknowledgeOwner: Bool
  ) {
    let completed = completion(for: controller)
    host.present(controller, animated: true) {
      if acknowledgeOwner { ownerCompletion() }
      completed()
    }
  }

  func wait(
    for controller: UIViewController, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let request = try XCTUnwrap(requests[ObjectIdentifier(controller)], file: file, line: line)
    guard !request.completed else { return }
    guard XCTWaiter.wait(for: [request.expectation], timeout: 15) == .completed else {
      XCTFail(
        "UIKit presentation completion missing: " + request.expectation.expectationDescription,
        file: file, line: line)
      throw WaitError.timedOut
    }
  }
}
