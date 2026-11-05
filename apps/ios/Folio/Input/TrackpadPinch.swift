import QuartzCore
import UIKit

// Tier 1. Transform events drive trackpad pinch without synthetic UITouches.
// allowedScrollTypesMask belongs to UIPanGestureRecognizer, not UIPinchGestureRecognizer.
@MainActor
private final class NonBlockingPinch: UIPinchGestureRecognizer {
  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
    false
  }
}

enum PinchPhase: String { case began, changed, ended }

struct PinchUpdate: Equatable {
  var phase: PinchPhase
  var scale: Double
  var location: CGPoint
}

#if DEBUG
  // Fixed numeric schema. Nil marks a nonfinite value; no event text or page data.
  struct PinchCallbackSample: Codable, Equatable {
    var time: Double
    let state: Int
    let scale: Double?
    let velocity: Double?
    let eventType: Int
    let x: Double?
    let y: Double?

    init(
      time: Double, state: Int, scale: Double, velocity: Double, eventType: Int, location: CGPoint
    ) {
      self.time = time
      self.state = state
      self.scale = scale.isFinite ? scale : nil
      self.velocity = velocity.isFinite ? velocity : nil
      self.eventType = eventType
      x = location.x.isFinite ? Double(location.x) : nil
      y = location.y.isFinite ? Double(location.y) : nil
    }
  }
#endif

@MainActor
final class TrackpadPinch: NSObject, UIGestureRecognizerDelegate {
  private weak var host: UIView?
  private var recognizer: UIPinchGestureRecognizer?
  var onUpdate: ((PinchUpdate) -> Void)?
  private var cumulative = 1.0
  private var anchor = CGPoint.zero
  private var active = false
  #if DEBUG
    var onCallback: ((PinchCallbackSample) -> Void)?
    private var eventType = -1
  #endif

  func attach(to view: UIView) {
    if host === view, recognizer != nil { return }
    detach()
    host = view
    let pinch = NonBlockingPinch(target: self, action: #selector(changed(_:)))
    pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
    pinch.cancelsTouchesInView = false
    pinch.delaysTouchesBegan = false
    pinch.delaysTouchesEnded = false
    pinch.delegate = self
    view.addGestureRecognizer(pinch)
    recognizer = pinch
  }
  func detach() {
    if let recognizer { host?.removeGestureRecognizer(recognizer) }
    recognizer = nil
    host = nil
    active = false
    cumulative = 1
    #if DEBUG
      eventType = -1
    #endif
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent)
    -> Bool
  {
    #if DEBUG
      eventType = event.type.rawValue
    #endif
    return event.type == .transform
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  { false }
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool { true }
  @objc func changed(_ pinch: UIPinchGestureRecognizer) {
    let state = pinch.state
    // The recognizer's own scale is cumulative since the gesture began. It is never reset, so the
    // result does not depend on how UIKit treats scale writes for trackpad transform events.
    let scale = Double(pinch.scale)
    let location = pinch.location(in: host)
    #if DEBUG
      onCallback?(
        PinchCallbackSample(
          time: CACurrentMediaTime(), state: state.rawValue, scale: scale,
          velocity: Double(pinch.velocity), eventType: eventType, location: location))
    #endif
    receive(state: state, scale: scale, location: location)
  }

  // Recognizer and DEBUG replay use this same state machine and onUpdate callback.
  private func receive(state: UIGestureRecognizer.State, scale: Double, location: CGPoint) {
    switch state {
    case .began:
      cumulative = 1
      anchor = location
      active = anchor.x.isFinite && anchor.y.isFinite
      guard active else { return }
      onUpdate?(PinchUpdate(phase: .began, scale: 1, location: anchor))
    case .changed:
      guard active, scale.isFinite, scale > 0 else { return }
      cumulative = scale
      onUpdate?(PinchUpdate(phase: .changed, scale: cumulative, location: anchor))
    case .ended, .cancelled, .failed:
      guard active else { return }
      if state == .ended, scale.isFinite, scale > 0 { cumulative = scale }
      active = false
      onUpdate?(PinchUpdate(phase: .ended, scale: cumulative, location: anchor))
    default: break
    }
  }
  #if DEBUG
    func cancelReplay() {
      active = false
      cumulative = 1
    }

    // Recorded cumulative scales go through the physical callback state machine.
    func replayCallback(_ sample: PinchCallbackSample) {
      guard recognizer != nil, let state = UIGestureRecognizer.State(rawValue: sample.state)
      else { return }
      receive(
        state: state, scale: sample.scale ?? .nan,
        location: CGPoint(x: sample.x ?? .nan, y: sample.y ?? .nan))
    }

    func replay(_ phase: PinchPhase, cumulativeScale: Double, location: CGPoint) {
      guard recognizer != nil, cumulativeScale.isFinite, cumulativeScale > 0 else { return }
      let state: UIGestureRecognizer.State =
        phase == .began ? .began : phase == .changed ? .changed : .ended
      receive(state: state, scale: cumulativeScale, location: location)
    }
  #endif

}
