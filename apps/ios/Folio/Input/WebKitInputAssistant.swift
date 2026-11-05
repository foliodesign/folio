import GameController
import UIKit

// WEBKIT_INTERNAL: public responder traversal, since WKWebView's focused descendant
// owns inputAssistantItem. Tier 2, no private class/selector or accessory-view replacement.
// Candidate only, default OFF. Clearing groups does not promise to remove the entire bar.
@MainActor
final class WebKitInputAssistant {
  private weak var host: UIView?
  private var enabled = false
  private var observers: [NSObjectProtocol] = []
  private struct Saved {
    let item: UITextInputAssistantItem
    let leading: [UIBarButtonItemGroup]
    let trailing: [UIBarButtonItemGroup]
  }
  private var saved: [Saved] = []
  func attach(to host: UIView) {
    detach()
    self.host = host
    for name in [NSNotification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated { self?.refresh() }
        })
    }
  }
  func setEnabled(_ value: Bool) {
    enabled = value
    refresh()
  }
  func refresh(hardwareKeyboardAttached: Bool = GCKeyboard.coalesced != nil) {
    guard enabled, hardwareKeyboardAttached, let host else {
      restore()
      return
    }
    func responder(_ view: UIView) -> UIView? {
      if view.isFirstResponder { return view }
      for child in view.subviews { if let result = responder(child) { return result } }
      return nil
    }
    guard let focused = responder(host) else { return }
    let item = focused.inputAssistantItem
    if !saved.contains(where: { $0.item === item }) {
      saved.append(
        Saved(
          item: item, leading: item.leadingBarButtonGroups, trailing: item.trailingBarButtonGroups))
    }
    item.leadingBarButtonGroups = []
    item.trailingBarButtonGroups = []
  }
  private func restore() {
    for entry in saved {
      entry.item.leadingBarButtonGroups = entry.leading
      entry.item.trailingBarButtonGroups = entry.trailing
    }
    saved.removeAll()
  }
  func detach() {
    restore()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    host = nil
    enabled = false
  }
  isolated deinit { detach() }
}
