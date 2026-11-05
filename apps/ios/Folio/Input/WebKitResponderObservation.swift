import UIKit

/// WEBKIT_INTERNAL: observation only via public subviews/isFirstResponder.
/// No class-name assumptions or responder mutations. Diagnostics remain opt-in.
@MainActor
enum WebKitResponderObservation {
  enum Category: String {
    case mainWebContent, popupWebContent, folioTextInput, folioControl, otherNative, none, unknown
  }
  static func first(in root: UIView) -> UIView? {
    if root.isFirstResponder { return root }
    for child in root.subviews { if let found = first(in: child) { return found } }
    return nil
  }
  static func category(_ responder: UIResponder?, main: UIView?, popup: UIView?) -> Category {
    guard let responder else { return .unknown }
    guard let view = responder as? UIView else { return .unknown }
    if let popup, view === popup || view.isDescendant(of: popup) { return .popupWebContent }
    if let main, view === main || view.isDescendant(of: main) { return .mainWebContent }
    if view is UITextField || view is UITextView { return .folioTextInput }
    if view is UIControl { return .folioControl }
    return .otherNative
  }
}
