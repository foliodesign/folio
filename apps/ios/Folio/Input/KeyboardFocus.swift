import UIKit

/// Fixed native chrome transitions. Never sourced from page strings.
enum BrowserFocusReason: String {
  case tabSelected, sameTabSelected, diagnosticsDismissed, nativeAlertDismissed, popupClosed,
    viewAppeared, sceneActivated, navigationFinished, pageReady, layoutReady
}

struct BrowserFocusGuard {
  var active: Bool
  var foreground: Bool
  var attached: Bool
  var popup: Bool
  var presentation: Bool
  var geometryReady = true
  var eligible: Bool {
    active && foreground && attached && geometryReady && !popup && !presentation
  }
  var mayRetryContainment: Bool {
    active && foreground && (!attached || !geometryReady) && !popup && !presentation
  }
}

/// One queued containment retry. Lifecycle invalidation cancels it without a timer.
@MainActor
final class KeyboardFocusRestoration {
  private(set) var epoch = UUID()
  private var pending = false
  func invalidate() {
    epoch = UUID()
    pending = false
  }
  func request(
    enabled: Bool, guard state: BrowserFocusGuard, focus: () -> Void,
    enqueue: (@escaping @MainActor () -> Void) -> Void,
    retry: @escaping @MainActor () -> Void
  ) {
    guard enabled else {
      invalidate()
      return
    }
    if state.eligible {
      invalidate()
      focus()
      return
    }
    guard state.mayRetryContainment, !pending else { return }
    pending = true
    let token = epoch
    enqueue { [weak self] in
      guard let self, self.epoch == token else { return }
      self.pending = false
      retry()
    }
  }
}

/// A cold page/tab focus request survives early inactive/unfinished attachment callbacks.
/// Successful focus consumes it; native chrome never creates another initial request.
struct InitialBrowserFocus {
  private(set) var pending = true
  mutating func begin() { pending = true }
  mutating func cancel() { pending = false }
  mutating func request(guard state: BrowserFocusGuard, focus: () -> Bool) {
    guard pending, state.eligible else { return }
    if focus() { pending = false }
  }
}

/// WEBKIT_INTERNAL: public responder containment traversal, no class-name assumptions.
/// Public responder traversal preserves an existing browser editable sink and native field undo.
/// No DOM inspection, focus/blur or script injection, including in Safe.
@MainActor
enum BrowserResponderFocus {
  static func first(in root: UIView) -> UIView? {
    if root.isFirstResponder { return root }
    for child in root.subviews {
      if let responder = first(in: child) { return responder }
    }
    return nil
  }

  enum Ownership: String {
    case none, browser, content, nativeText, other
  }

  static func ownership(_ responder: UIView?, browser: UIView) -> Ownership {
    guard let responder else { return .none }
    if responder === browser { return .browser }
    if responder.isDescendant(of: browser) { return .content }
    if responder is UITextField || responder is UITextView { return .nativeText }
    return .other
  }

  /// A sample tests native containment only; it does not certify DOM or system-window hits.
  static func hitOwner(at point: CGPoint, browser: UIView, root: UIView) -> String {
    guard browser.bounds.contains(point), browser.isDescendant(of: root) else {
      return "unattached"
    }
    guard let hit = root.hitTest(browser.convert(point, to: root), with: nil) else { return "none" }
    return hit === browser || hit.isDescendant(of: browser) ? "browser" : "native"
  }

  static func visibility(of browser: UIView) -> String {
    var hidden = 0
    var accessibilityHidden = 0
    var modal = 0
    var current: UIView? = browser
    while let view = current {
      if view.isHidden || view.alpha < 0.01 { hidden += 1 }
      if view.accessibilityElementsHidden { accessibilityHidden += 1 }
      if view.accessibilityViewIsModal { modal += 1 }
      current = view.superview
    }
    return
      "hiddenAncestors=\(hidden) axHiddenAncestors=\(accessibilityHidden) modalAncestors=\(modal)"
  }

  /// WEBKIT_INTERNAL: the editable WebKit content lives below its public scroll view.
  /// Use public UITextInput/responder APIs, never internal class names or selectors.
  static func editingResponder(in browser: UIView) -> UIView? {
    if let responder = first(in: browser), responder !== browser { return responder }
    _ = browser.becomeFirstResponder()
    if let responder = first(in: browser), responder !== browser { return responder }
    func content(in root: UIView) -> UIView? {
      if root !== browser, root is UITextInput, root.canBecomeFirstResponder { return root }
      for child in root.subviews {
        if let responder = content(in: child) { return responder }
      }
      return nil
    }
    guard let responder = content(in: browser), responder.becomeFirstResponder() else { return nil }
    return responder
  }

  static func restore(_ browser: UIView, in root: UIView) -> Bool {
    if let responder = first(in: root) {
      // Outer WKWebView ownership alone does not prove that WebKit content is ready.
      if responder !== browser && responder.isDescendant(of: browser) { return true }
      if responder is UITextField || responder is UITextView { return false }
    }
    return browser.becomeFirstResponder()
  }
}

/// Wait for UIKit's automatic action dismissal, then dismiss only the same retained alert.
/// The invalid-URL integration hierarchy returned this alert still attached after ten seconds.
@MainActor
func afterAlertDismissal(
  _ alert: UIAlertController?, attempts: Int = 20, completion: @escaping @MainActor () -> Void
) {
  guard let alert else {
    completion()
    return
  }
  if alert.presentingViewController == nil && !alert.isBeingDismissed {
    completion()
    return
  }
  if attempts == 0 {
    guard !alert.isBeingDismissed else {
      if let transition = alert.transitionCoordinator {
        transition.animate(alongsideTransition: nil) { _ in completion() }
      }
      return
    }
    // Never dismiss a successor sheet through the host/presenter.
    alert.dismiss(animated: true, completion: completion)
    return
  }
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
    afterAlertDismissal(alert, attempts: attempts - 1, completion: completion)
  }
}

#if DEBUG
  /// Read-only accessibility evidence, available without tapping chrome or changing focus.
  @MainActor
  final class BrowserReadinessButton: UIButton {
    var readiness: (() -> String)?
    override var accessibilityValue: String? {
      get { readiness?() }
      set { super.accessibilityValue = newValue }
    }
  }
#endif
