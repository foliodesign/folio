import QuartzCore
import UIKit

// Tier 1. Latest cumulative state wins while WebContent is busy.
@MainActor
final class PinchTransport {
  typealias Send = (_ script: String, _ completion: @escaping () -> Void) -> Void
  typealias Schedule = (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> (
    () -> Void
  )
  #if DEBUG
    var onCompletion: ((PinchUpdate, TimeInterval, TimeInterval) -> Void)?
    var onDispatch: ((PinchUpdate, TimeInterval) -> Void)?
  #endif
  private let schedule: Schedule
  private var cancelRecovery: (() -> Void)?
  private let send: Send
  private let now: () -> TimeInterval
  private let staleAfter: TimeInterval
  private var pending: PinchUpdate?
  // Preserve a queued start across updates from a second, rapid gesture.
  private var pendingBegan: PinchUpdate?
  private var cssPoint: ((CGPoint) -> String)?
  private var inFlight: Int?
  private var inFlightSince: TimeInterval = 0
  private var serial = 0
  private var generation = 0
  private var ended = false
  private(set) var sent = 0
  private(set) var coalesced = 0
  private(set) var maxRoundTrip: TimeInterval = 0

  init(
    send: @escaping Send, now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
    staleAfter: TimeInterval = 0.5,
    schedule: @escaping Schedule = { delay, action in
      let task = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        guard !Task.isCancelled else { return }
        action()
      }
      return { task.cancel() }
    }
  ) {
    self.send = send
    self.now = now
    self.staleAfter = staleAfter
    self.schedule = schedule
  }

  func handle(_ update: PinchUpdate, cssPoint: @escaping (CGPoint) -> String) {
    guard update.scale.isFinite, update.scale > 0,
      update.location.x.isFinite, update.location.y.isFinite
    else { return }
    self.cssPoint = cssPoint
    switch update.phase {
    case .began:
      ended = false
      pending = nil
      pendingBegan = update
    case .changed:
      guard !ended else { return }
      if pending != nil { coalesced += 1 }
      pending = update
    case .ended:
      ended = true
      pending = update
    }
    flush()
  }

  private func flush() {
    guard let update = pendingBegan ?? pending, let cssPoint else { return }
    let started = now()
    if let token = inFlight, started - inFlightSince < staleAfter {
      // The deadline belongs to the send, so more input cannot postpone recovery.
      if cancelRecovery == nil {
        let epoch = generation
        cancelRecovery = schedule(staleAfter - (started - inFlightSince)) { [weak self] in
          guard let self, self.generation == epoch, self.inFlight == token else { return }
          self.cancelRecovery = nil
          self.flush()
        }
      }
      return
    }
    cancelRecovery?()
    cancelRecovery = nil
    if pendingBegan != nil { pendingBegan = nil } else { pending = nil }
    serial += 1
    let token = serial
    let epoch = generation
    inFlight = token
    inFlightSince = started
    sent += 1
    let script =
      "globalThis.__folio?.trackpadPinch?.(\"\(update.phase.rawValue)\", \(update.scale), \(cssPoint(update.location))); void 0"
    #if DEBUG
      onDispatch?(update, started)
    #endif
    send(script) { [weak self] in
      guard let self, self.generation == epoch else { return }
      #if DEBUG
        self.onCompletion?(update, started, self.now())
      #endif
      self.maxRoundTrip = max(self.maxRoundTrip, self.now() - started)
      // A stale callback must not release a newer send's slot.
      guard self.inFlight == token else { return }
      self.cancelRecovery?()
      self.cancelRecovery = nil
      self.inFlight = nil
      self.flush()
    }
    // A queued begin can leave a final state waiting behind this new send.
    flush()
  }

  func reset() {
    generation += 1
    cancelRecovery?()
    cancelRecovery = nil
    pending = nil
    pendingBegan = nil
    cssPoint = nil
    inFlight = nil
    ended = false
    sent = 0
    coalesced = 0
    maxRoundTrip = 0
  }

  static func cssPoint(_ point: CGPoint, bounds: CGRect) -> String {
    "\(point.x) * (visualViewport?.width ?? innerWidth) / \(bounds.width) + (visualViewport?.offsetLeft ?? 0), \(point.y) * (visualViewport?.height ?? innerHeight) / \(bounds.height) + (visualViewport?.offsetTop ?? 0)"
  }
}
