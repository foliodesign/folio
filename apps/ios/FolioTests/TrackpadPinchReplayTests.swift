#if DEBUG
  import UIKit
  import XCTest

  @testable import Folio

  final class TrackpadPinchReplayTests: XCTestCase {
    @MainActor
    func testReplayPreservesCumulativeScaleAndFixedAnchorAcrossHoldAndRelease() {
      let pinch = TrackpadPinch()
      let host = UIView()
      pinch.attach(to: host)
      var updates: [PinchUpdate] = []
      pinch.onUpdate = { updates.append($0) }
      let anchor = CGPoint(x: 40, y: 80)
      pinch.replay(.began, cumulativeScale: 1, location: anchor)
      for frame in 1...72 {
        pinch.replay(.changed, cumulativeScale: pow(1.6, Double(frame) / 72), location: .zero)
      }
      pinch.replay(.ended, cumulativeScale: 1.6, location: .zero)
      XCTAssertEqual(updates.count, 74)
      XCTAssertEqual(updates.first?.phase, .began)
      XCTAssertEqual(updates.last?.phase, .ended)
      XCTAssertEqual(updates.last?.scale ?? 0, 1.6, accuracy: 1e-12)
      XCTAssertTrue(updates.allSatisfy { $0.location == anchor })
      pinch.replay(.changed, cumulativeScale: 2, location: anchor)
      XCTAssertEqual(updates.count, 74, "Changes after release cannot continue a gesture")
    }

    @MainActor
    func testReplayIgnoresInvalidInputAndDetachedRecognizer() {
      let pinch = TrackpadPinch()
      let host = UIView()
      pinch.attach(to: host)
      var updates: [PinchUpdate] = []
      pinch.onUpdate = { updates.append($0) }
      pinch.replay(.began, cumulativeScale: 1, location: .zero)
      pinch.replay(.changed, cumulativeScale: .nan, location: .zero)
      pinch.replay(.changed, cumulativeScale: 0, location: .zero)
      pinch.replay(.ended, cumulativeScale: 0.8, location: .zero)
      XCTAssertEqual(updates.count, 2)
      XCTAssertEqual(updates.last?.scale ?? 0, 0.8, accuracy: 1e-12)
      pinch.detach()
      pinch.replay(.began, cumulativeScale: 1, location: .zero)
      XCTAssertEqual(updates.count, 2)
    }
    @MainActor
    func testRealCallbackRecordsCumulativeScaleWithoutResetEvenWithoutActiveGesture() {
      let pinch = TrackpadPinch()
      var samples: [PinchCallbackSample] = []
      pinch.onCallback = { samples.append($0) }
      let recognizer = UIPinchGestureRecognizer()
      let event = UIEvent()
      _ = pinch.gestureRecognizer(recognizer, shouldReceive: event)
      recognizer.scale = 1.25
      pinch.changed(recognizer)
      XCTAssertEqual(samples.count, 1)
      XCTAssertEqual(samples[0].scale, 1.25)
      XCTAssertEqual(samples[0].eventType, event.type.rawValue)
      XCTAssertEqual(samples[0].state, recognizer.state.rawValue)
      XCTAssertEqual(samples[0].velocity, Double(recognizer.velocity))
      XCTAssertEqual(recognizer.scale, 1.25)
      pinch.onCallback = nil
      pinch.changed(recognizer)
      XCTAssertEqual(samples.count, 1, "Recorder is opt-in")
    }

    @MainActor
    func testRecordedIncrementReplayIncludesFinalScaleAndIgnoresReleaseTail() {
      let pinch = TrackpadPinch()
      let host = UIView()
      pinch.attach(to: host)
      var updates: [PinchUpdate] = []
      pinch.onUpdate = { updates.append($0) }
      for (state, scale) in [
        (UIGestureRecognizer.State.began, 1.0),
        (.changed, 1.2), (.changed, 1.0), (.ended, 1.25), (.changed, 2.0),
      ] {
        pinch.replayCallback(
          PinchCallbackSample(
            time: 0, state: state.rawValue,
            scale: scale, velocity: 3, eventType: UIEvent.EventType.transform.rawValue,
            location: CGPoint(x: 40, y: 80)))
      }
      XCTAssertEqual(updates.count, 4)
      XCTAssertEqual(updates.last?.scale ?? 0, 1.25, accuracy: 1e-12)
      XCTAssertEqual(updates.last?.location, CGPoint(x: 40, y: 80))
      pinch.cancelReplay()
      pinch.replayCallback(
        PinchCallbackSample(
          time: 0, state: 2, scale: 2,
          velocity: 0, eventType: -1, location: .zero))
      XCTAssertEqual(updates.count, 4)
      pinch.detach()
      pinch.replayCallback(
        PinchCallbackSample(
          time: 0, state: 1, scale: 1,
          velocity: 0, eventType: -1, location: .zero))
      XCTAssertEqual(updates.count, 4)
    }

    @MainActor
    func testRecordedInvalidTerminalIncrementStillEndsSequence() {
      let pinch = TrackpadPinch()
      let host = UIView()
      pinch.attach(to: host)
      var updates: [PinchUpdate] = []
      pinch.onUpdate = { updates.append($0) }
      for (state, scale) in [
        (UIGestureRecognizer.State.began, 1.0),
        (.changed, 1.2), (.ended, Double.nan), (.changed, 2.0),
      ] {
        pinch.replayCallback(
          PinchCallbackSample(
            time: 0, state: state.rawValue,
            scale: scale, velocity: .nan, eventType: -1, location: .zero))
      }
      XCTAssertEqual(updates.count, 3)
      XCTAssertEqual(updates.last?.phase, .ended)
      XCTAssertEqual(updates.last?.scale, 1.2)
    }

    @MainActor
    func testRecorderBoundsAndNonfiniteValuesEncodeWithoutContent() throws {
      let trace = PinchReplayHarness.CallbackTrace(source: "real-callbacks", origin: 0)
      let sample = PinchCallbackSample(
        time: 0, state: 0, scale: .nan,
        velocity: .infinity, eventType: -1, location: .zero)
      for _ in 0...PinchReplayHarness.CallbackTrace.limit { trace.append(sample) }
      XCTAssertEqual(trace.callbacks.count, 4096)
      XCTAssertEqual(trace.dropped, 1)
      XCTAssertNil(trace.callbacks[0].scale)
      XCTAssertNil(trace.callbacks[0].velocity)
      let update = PinchUpdate(phase: .ended, scale: 1.5, location: .zero)
      for _ in 0...PinchReplayHarness.CallbackTrace.limit {
        trace.timing(update, sentAt: 0, time: 1, completion: false)
        trace.timing(update, sentAt: 0, time: 1, completion: true)
      }
      XCTAssertEqual(trace.dispatches.count, 4096)
      XCTAssertEqual(trace.completions.count, 4096)
      XCTAssertEqual(trace.dropped, 3)
      XCTAssertNoThrow(try JSONEncoder().encode(trace))
      XCTAssertTrue(PinchReplayHarness.observer.contains("const limit = 4096"))
      XCTAssertTrue(PinchReplayHarness.observer.contains("value <= 100000"))
      XCTAssertTrue(PinchReplayHarness.observer.contains("trusted:e.isTrusted"))
    }
  }
#endif
