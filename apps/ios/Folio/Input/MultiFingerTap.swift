import UIKit

/// A tap remains non-blocking while WebKit handles pan/pinch. All points are checked in the DOM.
/// Install on a view *outside* the WKWebView: WebKit defers every recognizer on or under the web
/// view until the page handles the touch, and fails them when the page prevents default, which
/// Figma's canvas (and the finger transport) do for two-finger touches.
@MainActor
final class MultiFingerTap: NSObject, UIGestureRecognizerDelegate {
  private(set) weak var host: UIView?
  private var taps: [CanvasTap] = []
  var eligible: (() -> Bool)?
  var validate: (([CGPoint], Bool, @escaping @MainActor (Bool) -> Void) -> Void)?
  var onTap: ((Bool) -> Void)?
  var log: ((String) -> Void)?

  func attach(to host: UIView) {
    guard self.host !== host else { return }
    detach()
    self.host = host
    for count in [2, 3] {
      let tap = CanvasTap(target: self, action: #selector(tapped(_:)))
      tap.numberOfTouchesRequired = count
      tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
      tap.cancelsTouchesInView = false
      tap.delaysTouchesBegan = false
      tap.delaysTouchesEnded = false
      tap.delegate = self
      tap.log = { [weak self] message in self?.log?("tap=\(count) \(message)") }
      tap.check = { [weak self, weak tap] points in
        guard let self, let tap else { return }
        let token = tap.token
        self.validate?(points, false) { [weak tap] accepted in
          guard let tap, tap.token == token else { return }
          if !accepted { tap.reject() }
        }
      }
      host.addGestureRecognizer(tap)
      taps.append(tap)
    }
  }

  func detach() {
    for tap in taps {
      tap.token = UUID()
      host?.removeGestureRecognizer(tap)
    }
    taps.removeAll()
    host = nil
  }

  @objc private func tapped(_ tap: CanvasTap) {
    log?("recognized count=\(tap.numberOfTouchesRequired) state=\(tap.state.rawValue)")
    guard tap.state == .ended, eligible?() == true else { return }
    let token = tap.token
    validate?(tap.points, true) { [weak self, weak tap] accepted in
      guard let self, let tap, tap.token == token, accepted, self.eligible?() == true else {
        return
      }
      self.log?("command=\(tap.numberOfTouchesRequired == 3 ? "redo" : "undo")")
      self.onTap?(tap.numberOfTouchesRequired == 3)
    }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  {
    let accepted = eligible?() == true && touch.type == .direct
    log?("receive state=\(gestureRecognizer.state.rawValue) eligible=\(accepted)")
    return accepted
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool { true }
}

@MainActor
private final class CanvasTap: UITapGestureRecognizer {
  var token = UUID()
  var points: [CGPoint] = []
  var check: (([CGPoint]) -> Void)?
  var log: ((String) -> Void)?
  private var starts: [UITouch: CGPoint] = [:]
  private var beganAt: TimeInterval = 0
  private var deadline: Timer?

  private var reason: String?
  private var maxContacts = 0

  func reject(_ reason: String = "canvas-gate") {
    log?("reject=\(reason) state=\(state.rawValue)")
    if self.reason == nil { self.reason = reason }
    if state == .possible { state = .failed }
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let view else { return }
    if starts.isEmpty {
      reason = nil
      maxContacts = 0
      beganAt = event.timestamp
      token = UUID()
      points.removeAll()
      deadline = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.reject("timeout") }
      }
    }
    for touch in touches {
      let point = touch.location(in: view)
      starts[touch] = point
      points.append(point)
    }
    maxContacts = max(maxContacts, starts.count)
    if starts.count > numberOfTouchesRequired {
      reject("contact-count")
      return
    }
    log?("began contacts=\(starts.count)")
    check?(points)
    super.touchesBegan(touches, with: event)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard stationary(touches) else {
      reject("movement")
      return
    }
    super.touchesMoved(touches, with: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard event.timestamp - beganAt <= 0.3, stationary(touches), let view else {
      reject("end-duration-or-movement")
      return
    }
    log?("ended contacts=\(touches.count) elapsed=\(event.timestamp - beganAt)")
    points.append(contentsOf: touches.map { $0.location(in: view) })
    if event.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) == true {
      deadline?.invalidate()
    }
    super.touchesEnded(touches, with: event)
  }

  private func stationary(_ touches: Set<UITouch>) -> Bool {
    guard let view else { return false }
    return touches.allSatisfy { touch in
      guard let start = starts[touch] else { return false }
      let point = touch.location(in: view)
      return hypot(point.x - start.x, point.y - start.y) <= 8
    }
  }

  // WebKit can begin a pan for stationary multi-touch. Observe alongside it; our own movement
  // limit and the DOM pan/pinch gate reject motion without delaying or cancelling WebKit.
  override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by other: UIGestureRecognizer) -> Bool {
    false
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    log?("cancelled state=\(state.rawValue)")
    super.touchesCancelled(touches, with: event)
  }

  override func reset() {
    // One line per multi-finger attempt, so a failed tap is diagnosable from an input log.
    if maxContacts >= 2 {
      let system = state == .cancelled ? "system-cancelled" : "system-failed"
      let result =
        state == .ended || state == .recognized
        ? "recognized" : "rejected reason=\(reason ?? system)"
      log?("attempt contacts=\(maxContacts) \(result)")
    }
    reason = nil
    maxContacts = 0
    deadline?.invalidate()
    deadline = nil
    starts.removeAll()
    super.reset()
  }
}
