import UIKit
import XCTest

@testable import Folio

final class PinchTransportTests: XCTestCase {
  @MainActor
  private final class Harness {
    var time: TimeInterval = 0
    var scripts: [String] = []
    var completions: [() -> Void] = []
    struct Deadline {
      let time: TimeInterval
      let action: @MainActor () -> Void
      var cancelled = false
    }
    var deadlines: [Deadline] = []
    func advance(to time: TimeInterval) {
      self.time = time
      // Fire only the due timers; callbacks may append a later deadline.
      let due = deadlines.indices.filter { !deadlines[$0].cancelled && deadlines[$0].time <= time }
      for index in due {
        deadlines[index].cancelled = true
        deadlines[index].action()
      }
    }
    lazy var transport = PinchTransport(
      send: { [unowned self] script, completion in
        scripts.append(script)
        completions.append(completion)
      }, now: { [unowned self] in time },
      schedule: { [unowned self] delay, action in
        let index = deadlines.count
        deadlines.append(Deadline(time: time + delay, action: action))
        return { [weak self] in self?.deadlines[index].cancelled = true }
      })
    func handle(_ phase: PinchPhase, _ scale: Double = 1) {
      transport.handle(PinchUpdate(phase: phase, scale: scale, location: CGPoint(x: 10, y: 20))) {
        "\($0.x), \($0.y)"
      }
    }
  }

  @MainActor
  func testBeginAndLatestChangedOnlyWhileInFlight() {
    let h = Harness()
    h.handle(.began)
    XCTAssertEqual(h.scripts.count, 1)
    XCTAssertTrue(h.scripts[0].contains("\"began\", 1.0, 10.0, 20.0"))
    for scale in [1.1, 1.2, 1.5] { h.handle(.changed, scale) }
    XCTAssertEqual(h.scripts.count, 1)
    XCTAssertEqual(h.transport.coalesced, 2)
    h.time = 0.02
    h.completions[0]()
    XCTAssertEqual(h.scripts.count, 2)
    XCTAssertTrue(h.scripts[1].contains("\"changed\", 1.5"))
    XCTAssertEqual(h.transport.maxRoundTrip, 0.02, accuracy: 1e-9)
  }

  @MainActor
  func testEndReplacesPendingMotionAndRejectsFurtherChanges() {
    let h = Harness()
    h.handle(.began)
    h.handle(.changed, 1.2)
    h.handle(.ended, 1.5)
    h.handle(.changed, 2)
    h.completions[0]()
    XCTAssertEqual(h.scripts.count, 2)
    XCTAssertTrue(h.scripts[1].contains("\"ended\", 1.5"))
    h.completions[1]()
    XCTAssertEqual(h.scripts.count, 2)
    h.handle(.began)
    XCTAssertEqual(h.scripts.count, 3)
  }

  @MainActor
  func testStaleSendAndLateCompletionCannotReleaseNewSlot() {
    let h = Harness()
    h.handle(.began)
    h.time = 0.6
    h.handle(.changed, 1.2)
    XCTAssertEqual(h.scripts.count, 2)
    XCTAssertEqual(h.transport.maxRoundTrip, 0)
    h.handle(.ended, 1.5)
    h.completions[0]()
    XCTAssertEqual(h.scripts.count, 2)
    XCTAssertEqual(h.transport.maxRoundTrip, 0.6, accuracy: 1e-9)
    h.completions[1]()
    XCTAssertEqual(h.scripts.count, 3)
    XCTAssertTrue(h.scripts.last!.contains("\"ended\", 1.5"))
  }

  @MainActor
  func testResetDropsPendingAndIgnoresOldCompletion() {
    let h = Harness()
    h.handle(.began)
    h.handle(.changed, 1.2)
    h.handle(.changed, 1.5)
    h.transport.reset()
    XCTAssertEqual(h.transport.sent, 0)
    XCTAssertEqual(h.transport.coalesced, 0)
    XCTAssertEqual(h.transport.maxRoundTrip, 0)
    h.handle(.began)
    h.handle(.ended, 2)
    h.time = 0.1
    h.completions[0]()
    XCTAssertEqual(h.scripts.count, 2)
    XCTAssertEqual(h.transport.maxRoundTrip, 0)
    h.completions[1]()
    XCTAssertEqual(h.scripts.count, 3)
  }

  @MainActor
  func testQuietEndRecoversAtOriginalSendDeadlineWithoutCompletion() {
    let h = Harness()
    h.handle(.began)
    h.advance(to: 0.1)
    h.handle(.changed, 1.2)
    h.handle(.ended, 1.5)
    XCTAssertEqual(h.deadlines.count, 1)
    XCTAssertEqual(h.deadlines[0].time, 0.5, accuracy: 1e-9)
    h.advance(to: 0.499)
    XCTAssertEqual(h.scripts.count, 1)
    h.advance(to: 0.5)
    XCTAssertEqual(h.scripts.count, 2)
    XCTAssertTrue(h.scripts[1].contains("\"ended\", 1.5"))
    h.advance(to: 2)
    h.completions[0]()
    h.completions[1]()
    XCTAssertEqual(h.scripts.count, 2)
  }

  @MainActor
  func testLateTimerAndCompletionCannotReleaseRecoveredSend() {
    let h = Harness()
    h.handle(.began)
    h.advance(to: 0.1)
    h.handle(.changed, 1.2)
    h.advance(to: 0.5)
    XCTAssertEqual(h.scripts.count, 2)
    h.handle(.ended, 1.5)
    h.advance(to: 0.6)
    h.deadlines[0].action()
    h.completions[0]()
    XCTAssertEqual(h.scripts.count, 2)
    h.advance(to: 1)
    XCTAssertEqual(h.scripts.count, 3)
    XCTAssertTrue(h.scripts[2].contains("\"ended\", 1.5"))
    h.completions[1]()
    h.completions[2]()
    XCTAssertEqual(h.scripts.count, 3)
  }

  @MainActor
  func testCompletionCancelsDeadlineAndOldTimerCannotFlushNewSlot() {
    let h = Harness()
    h.handle(.began)
    h.handle(.changed, 1.2)
    h.advance(to: 0.1)
    h.completions[0]()
    XCTAssertTrue(h.deadlines[0].cancelled)
    h.handle(.ended, 1.5)
    h.advance(to: 0.5)
    h.deadlines[0].action()
    XCTAssertEqual(h.scripts.count, 2)
    h.advance(to: 0.6)
    XCTAssertEqual(h.scripts.count, 3)
  }

  @MainActor
  func testResetCancelsQuietEndRecoveryAndRejectsOldTimer() {
    let h = Harness()
    h.handle(.began)
    h.handle(.ended, 1.5)
    h.transport.reset()
    XCTAssertTrue(h.deadlines[0].cancelled)
    h.advance(to: 1)
    h.deadlines[0].action()
    h.completions[0]()
    XCTAssertEqual(h.scripts.count, 1)
    XCTAssertEqual(h.transport.sent, 0)
    XCTAssertEqual(h.transport.maxRoundTrip, 0)
    h.handle(.began)
    h.handle(.ended, 2)
    h.deadlines[0].action()
    XCTAssertEqual(h.scripts.count, 2)
    h.advance(to: 1.5)
    XCTAssertEqual(h.scripts.count, 3)
    XCTAssertTrue(h.scripts[2].contains("\"ended\", 2.0"))
  }

  @MainActor
  func testRapidSecondGesturePreservesQueuedBegin() {
    let h = Harness()
    h.handle(.began)
    h.handle(.ended, 1.2)
    h.handle(.began)
    h.handle(.changed, 1.3)
    h.handle(.ended, 1.5)
    h.completions[0]()
    XCTAssertTrue(h.scripts[1].contains("\"began\""))
    h.completions[1]()
    XCTAssertTrue(h.scripts[2].contains("\"ended\", 1.5"))
  }

  @MainActor
  func testRapidQuietSecondGestureRecoversBothStartAndEnd() {
    let h = Harness()
    h.handle(.began)
    h.advance(to: 0.1)
    h.handle(.ended, 1.2)
    h.handle(.began)
    h.handle(.ended, 1.5)
    h.advance(to: 0.5)
    XCTAssertEqual(h.scripts.count, 2)
    XCTAssertTrue(h.scripts[1].contains("\"began\""))
    h.advance(to: 1)
    XCTAssertEqual(h.scripts.count, 3)
    XCTAssertTrue(h.scripts[2].contains("\"ended\", 1.5"))
    for completion in h.completions { completion() }
    h.advance(to: 2)
    XCTAssertEqual(h.scripts.count, 3)
  }

  func testOptionalPinchDiagnosticsValidation() throws {
    let capture = EnvironmentCapture(
      userAgent: "AppleWebKit/605.1.15", gpuPresent: false, adapterResult: "unavailable",
      adapterInfo: "unavailable",
      webgl: GraphicsCapture(available: false, renderer: "unavailable", maxTextureSize: 0),
      webgl2: GraphicsCapture(available: false, renderer: "unavailable", maxTextureSize: 0),
      devicePixelRatio: 2, viewportWidth: 1024, viewportHeight: 768, maxTouchPoints: 5,
      media: Dictionary(uniqueKeysWithValues: BridgeMessage.mediaKeys.map { ($0, false) }))
    var payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(capture)) as? [String: Any])
    XCTAssertNotNil(BridgeMessage.validate(["name": "folioDiagnostics", "payload": payload]))
    payload["trackpadPinch"] = [
      "route": "wheel", "dispatched": 4, "prevented": 2, "gestureSupported": false,
    ]
    XCTAssertNotNil(BridgeMessage.validate(["name": "folioDiagnostics", "payload": payload]))
    for bad: [String: Any] in [
      ["route": "other", "dispatched": 4, "prevented": 2, "gestureSupported": false],
      ["route": "wheel", "dispatched": 1, "prevented": 2, "gestureSupported": false],
      ["route": "wheel", "dispatched": -1, "prevented": 0, "gestureSupported": false],
      [
        "route": "wheel", "dispatched": 4, "prevented": 2, "gestureSupported": false,
        "text": "private",
      ],
    ] {
      payload["trackpadPinch"] = bad
      XCTAssertNil(BridgeMessage.validate(["name": "folioDiagnostics", "payload": payload]))
    }
  }

  #if DEBUG
    @MainActor
    func testRecorderSeparatesQueuedDispatchAndCompletionTimesAndReset() {
      let h = Harness()
      var dispatches: [Double] = []
      var completions: [Double] = []
      h.transport.onDispatch = { _, time in dispatches.append(time) }
      h.transport.onCompletion = { _, _, time in completions.append(time) }
      h.handle(.began)
      h.advance(to: 0.1)
      h.handle(.ended, 1.5)
      XCTAssertEqual(dispatches, [0])
      h.advance(to: 0.2)
      h.completions[0]()
      XCTAssertEqual(dispatches, [0, 0.2])
      XCTAssertEqual(completions, [0.2])
      h.transport.reset()
      h.advance(to: 1)
      h.completions[1]()
      XCTAssertEqual(completions, [0.2], "Reset rejects old recording completions")
    }
  #endif

  @MainActor
  func testCSSPointPreservesViewportConversion() {
    let expression = PinchTransport.cssPoint(
      CGPoint(x: 20, y: 40), bounds: CGRect(x: 0, y: 0, width: 500, height: 400))
    XCTAssertTrue(expression.contains("20.0 * (visualViewport?.width ?? innerWidth) / 500.0"))
    XCTAssertTrue(expression.contains("40.0 * (visualViewport?.height ?? innerHeight) / 400.0"))
    XCTAssertTrue(expression.contains("visualViewport?.offsetLeft"))
    XCTAssertTrue(expression.contains("visualViewport?.offsetTop"))
  }
}
