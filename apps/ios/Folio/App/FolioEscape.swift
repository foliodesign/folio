import UIKit

/// The one Esc route for Folio overlays. The window offers an Esc key command only while an
/// overlay is open, so Esc reaches the page (Figma) otherwise.
///
/// Order: the topmost presented controller first (its registered close action, else a plain
/// dismissal followed by a browser focus restore), then in-window overlays registered with
/// `register(_:when:action:)`, newest first. Controllers with their own Esc command (the ⋯
/// menu, Developer Tools) still get it first when they hold the first responder.
@MainActor
enum FolioEscape {
  private final class Entry {
    weak var owner: AnyObject?
    let isOpen: () -> Bool
    let action: () -> Void
    init(owner: AnyObject, isOpen: @escaping () -> Bool, action: @escaping () -> Void) {
      self.owner = owner
      self.isOpen = isOpen
      self.action = action
    }
  }
  private static var entries: [Entry] = []

  /// Registers the close action for `owner` (a presented controller, an overlay view or a
  /// controller whose view hosts the overlay). The entry lives as long as `owner`.
  static func register(
    _ owner: AnyObject, when isOpen: @escaping () -> Bool = { true },
    action: @escaping () -> Void
  ) {
    entries.removeAll { $0.owner == nil || $0.owner === owner }
    entries.append(Entry(owner: owner, isOpen: isOpen, action: action))
  }

  static func unregister(_ owner: AnyObject) {
    entries.removeAll { $0.owner == nil || $0.owner === owner }
  }

  /// The close action for the topmost Folio overlay in `window`, or nil.
  static func action(in window: UIWindow) -> (() -> Void)? {
    entries.removeAll { $0.owner == nil }
    guard let root = window.rootViewController else { return nil }
    var top = root
    while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
    if top !== root {
      let candidates = [top] + ((top as? UINavigationController)?.viewControllers.prefix(1) ?? [])
      for controller in candidates {
        if let entry = entries.last(where: { $0.owner === controller }) { return entry.action }
      }
      return { [weak top, weak window] in
        top?.dismiss(animated: true) { if let window { restoreFocus(in: window) } }
      }
    }
    for entry in entries.reversed() where entry.isOpen() {
      let view = (entry.owner as? UIViewController)?.viewIfLoaded ?? entry.owner as? UIView
      if let view, view.window === window, isVisible(view) { return entry.action }
    }
    return nil
  }

  /// Returns keyboard focus to the selected tab's page after a plain dismissal.
  static func restoreFocus(in window: UIWindow) {
    var stack: [UIViewController] = window.rootViewController.map { [$0] } ?? []
    while let controller = stack.popLast() {
      if let browser = controller as? BrowserWindowController {
        browser.restoreActiveBrowserFocus()
        return
      }
      stack.append(contentsOf: controller.children)
    }
  }

  private static func isVisible(_ view: UIView) -> Bool {
    var current: UIView? = view
    while let candidate = current {
      if candidate.isHidden || candidate.alpha < 0.01 { return false }
      current = candidate.superview
    }
    return true
  }
}

/// Scene window that owns the Esc command for Folio overlays.
final class FolioWindow: UIWindow {
  override var keyCommands: [UIKeyCommand]? {
    let inherited = super.keyCommands ?? []
    guard FolioEscape.action(in: self) != nil else { return inherited }
    let escape = UIKeyCommand(
      input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeFolioOverlay))
    escape.wantsPriorityOverSystemBehavior = true
    return inherited + [escape]
  }

  @objc private func closeFolioOverlay() { FolioEscape.action(in: self)?() }
}
