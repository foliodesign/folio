import UIKit

// WEBKIT_INTERNAL: public UIKit calls, but recognizer placement/types depend on WebKit.
// Verified for installation/restoration only on iPadOS 27.0 simulator. Pencil behavior unverified.
// No private names, selectors, KVC, delegate replacement, or irreversible failure dependencies.
@MainActor
final class WebKitGestureReroute {
  struct Facts: Equatable {
    let isPan: Bool
    let isLongPress: Bool
    let touchTypes: [Int]
  }
  // Separate policy permits fake recognizer facts in tests without WebKit internals.
  static func reroutedTypes(_ facts: Facts, pencil: Bool) -> [Int] {
    guard pencil, facts.isPan || facts.isLongPress else { return facts.touchTypes }
    return facts.touchTypes.filter { $0 != UITouch.TouchType.pencil.rawValue }
  }
  static func walk(_ root: UIView) -> [UIGestureRecognizer] {
    var seen: Set<ObjectIdentifier> = []
    func visit(_ view: UIView) -> [UIGestureRecognizer] {
      let local = (view.gestureRecognizers ?? []).filter {
        seen.insert(ObjectIdentifier($0)).inserted
      }
      return local + view.subviews.flatMap(visit)
    }
    return visit(root)
  }
  private struct Saved {
    let recognizer: UIGestureRecognizer
    let types: [NSNumber]
    let minimumTouches: Int?
  }
  private var saved: [Saved] = []
  private(set) var changedCount = 0

  func restore() {
    for entry in saved {
      entry.recognizer.allowedTouchTypes = entry.types
      if let pan = entry.recognizer as? UIPanGestureRecognizer, let min = entry.minimumTouches {
        pan.minimumNumberOfTouches = min
      }
    }
    saved.removeAll()
    changedCount = 0
  }
  func apply(
    scrollView: UIScrollView, pencil: Bool, finger: FingerPanStrategy
  ) {
    restore()
    for recognizer in Self.walk(scrollView) {
      let types = recognizer.allowedTouchTypes
      let facts = Facts(
        isPan: recognizer is UIPanGestureRecognizer,
        isLongPress: recognizer is UILongPressGestureRecognizer,
        touchTypes: types.map(\.intValue))
      let next = Self.reroutedTypes(facts, pencil: pencil).map { NSNumber(value: $0) }
      let pagePan = recognizer === scrollView.panGestureRecognizer && finger != .baseline
      guard next != types || pagePan else { continue }
      let pan = recognizer as? UIPanGestureRecognizer
      saved.append(
        Saved(recognizer: recognizer, types: types, minimumTouches: pan?.minimumNumberOfTouches))
      recognizer.allowedTouchTypes = next
      if pagePan { pan?.minimumNumberOfTouches = finger == .canvas ? 2 : 1 }
    }
    changedCount = saved.count
  }
}
