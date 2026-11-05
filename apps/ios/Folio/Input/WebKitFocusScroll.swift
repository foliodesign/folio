import UIKit
import WebKit

// WEBKIT_INTERNAL: KVO/restore assumes WebKit uses its public root UIScrollView
// for focus scrolling and zooming. No delegate replacement, private API or subview names.
// Tier 2. iPadOS 27 simulator fixture verification; Figma/device acceptance still required.
@MainActor
final class WebKitFocusScroll {
  private let clockOrigin = ProcessInfo.processInfo.systemUptime
  private weak var scroll: UIScrollView?
  private var observations: [NSKeyValueObservation] = []
  private var keyboardObservers: [NSObjectProtocol] = []
  private var enforcing = false
  private var lastGeometry: String?
  private(set) var locked = false
  var logging = false {
    didSet {
      if logging && !oldValue { sample("logging-enabled") }
      if !logging { lastGeometry = nil }
    }
  }
  var onLog: ((String) -> Void)?
  var onKeyboard: (() -> Void)?
  var onGeometry: (() -> Void)?
  private(set) var keyboardFrames = 0
  private struct Saved {
    let min: CGFloat
    let max: CGFloat
    let zoom: CGFloat
    let inset: UIEdgeInsets
    let adjustment: UIScrollView.ContentInsetAdjustmentBehavior
    let pinch: Bool?
  }
  private var saved: Saved?

  func attach(to scroll: UIScrollView) {
    detach()
    self.scroll = scroll
    func observe<Value>(_ path: KeyPath<UIScrollView, Value>, _ label: String) {
      observations.append(
        scroll.observe(path, options: [.new]) { [weak self] _, _ in
          MainActor.assumeIsolated {
            guard let self, !self.enforcing else { return }
            self.sample(label)
            self.enforce()
            self.onGeometry?()
          }
        })
    }
    observe(\.zoomScale, "zoomScale")
    observe(\.contentOffset, "contentOffset")
    observe(\.contentInset, "contentInset")
    observe(\.adjustedContentInset, "adjustedContentInset")
    observe(\.minimumZoomScale, "minimumZoomScale")
    observe(\.maximumZoomScale, "maximumZoomScale")
    for name in [
      UIResponder.keyboardWillChangeFrameNotification,
      UIResponder.keyboardDidChangeFrameNotification,
      UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
    ] {
      keyboardObservers.append(
        NotificationCenter.default.addObserver(
          forName: name, object: nil, queue: .main
        ) { [weak self] note in
          let frame =
            (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            ?? .zero
          MainActor.assumeIsolated {
            guard let self else { return }
            if self.logging {
              self.onLog?(
                "Native keyboard \(name.rawValue) frame=\(frame) elapsed=\(ProcessInfo.processInfo.systemUptime - self.clockOrigin)"
              )
              self.sample("keyboard")
            }
            self.onKeyboard?()
            self.enforce()
            if name == UIResponder.keyboardDidChangeFrameNotification { self.keyboardFrames += 1 }
            self.onGeometry?()
          }
        })
    }
  }
  func setLocked(_ value: Bool) {
    guard let scroll else { return }
    if value == locked {
      if value { enforce() }
      return
    }
    locked = value
    if value {
      saved = Saved(
        min: scroll.minimumZoomScale, max: scroll.maximumZoomScale,
        zoom: scroll.zoomScale, inset: scroll.contentInset,
        adjustment: scroll.contentInsetAdjustmentBehavior,
        pinch: scroll.pinchGestureRecognizer?.isEnabled)
      enforce()
    } else if let saved {
      enforcing = true
      scroll.minimumZoomScale = saved.min
      scroll.maximumZoomScale = saved.max
      scroll.setZoomScale(saved.zoom, animated: false)
      scroll.contentInsetAdjustmentBehavior = saved.adjustment
      scroll.contentInset = saved.inset
      if let pinch = saved.pinch { scroll.pinchGestureRecognizer?.isEnabled = pinch }
      enforcing = false
      self.saved = nil
    }
    sample(value ? "lock-on" : "lock-off")
  }
  func enforce() {
    guard locked, !enforcing, let scroll else { return }
    enforcing = true
    defer {
      enforcing = false
      sample("lock-restored")
    }
    if scroll.contentInsetAdjustmentBehavior != .never {
      scroll.contentInsetAdjustmentBehavior = .never
    }
    if scroll.contentInset != .zero { scroll.contentInset = .zero }
    if scroll.minimumZoomScale != 1 { scroll.minimumZoomScale = 1 }
    if scroll.maximumZoomScale != 1 { scroll.maximumZoomScale = 1 }
    if scroll.zoomScale != 1 { scroll.setZoomScale(1, animated: false) }
    if scroll.contentOffset != .zero { scroll.setContentOffset(.zero, animated: false) }
    if scroll.pinchGestureRecognizer?.isEnabled == true {
      scroll.pinchGestureRecognizer?.isEnabled = false
    }
  }
  func sample(_ reason: String) {
    guard logging, let scroll else { return }
    let geometry =
      "zoomScale=\(scroll.zoomScale) min=\(scroll.minimumZoomScale) max=\(scroll.maximumZoomScale) contentOffset=\(scroll.contentOffset) contentInset=\(scroll.contentInset) adjustedContentInset=\(scroll.adjustedContentInset) bounds=\(scroll.bounds.size)"
    let force = reason == "capture" || reason == "logging-enabled" || reason.hasPrefix("lock-o")
    guard force || geometry != lastGeometry else { return }
    lastGeometry = geometry
    onLog?(
      "Native scroll \(reason) \(geometry) elapsed=\(ProcessInfo.processInfo.systemUptime - clockOrigin)"
    )
  }
  func detach() {
    setLocked(false)
    for observation in observations { observation.invalidate() }
    observations.removeAll()
    for observer in keyboardObservers { NotificationCenter.default.removeObserver(observer) }
    keyboardObservers.removeAll()
    scroll = nil
    lastGeometry = nil
  }
  isolated deinit { detach() }
}
