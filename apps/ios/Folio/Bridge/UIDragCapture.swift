import Foundation

/// Fixed metadata only. No page text, arbitrary labels, URLs or error messages.
struct UIDragCapture: Codable, Equatable {
  let kind: String
  let type: String
  let target: String
  let detail: String
  let drag: Int
  let x: Double
  let y: Double
  let buttons: Int
  let pointerId: Int
  let pointerType: String
  let isPrimary: Bool
  let defaultPrevented: Bool
  let trusted: Bool
  let time: Double

  static func validate(_ payload: [String: Any], data: Data) -> UIDragCapture? {
    guard
      Set(payload.keys) == [
        "kind", "type", "target", "detail", "drag", "x", "y", "buttons",
        "pointerId", "pointerType", "isPrimary", "defaultPrevented", "trusted", "time",
      ], let value = try? JSONDecoder().decode(Self.self, from: data),
      ["synthetic", "observed", "error", "draggable", "state", "real"].contains(value.kind),
      [
        "pointerdown", "pointermove", "pointerup", "pointercancel", "mousedown", "mousemove",
        "mouseup", "click", "contextmenu", "dblclick", "gotpointercapture", "lostpointercapture",
        "dragstart", "dragover", "drop", "dragend", "error", "unhandledrejection",
        "under-finger", "pending", "armed", "held", "mouse-down", "finish", "options",
      ].contains(value.type),
      value.target == "OTHER"
        || value.target.range(
          of:
            "^(DIV|SPAN|BUTTON|INPUT|UL|LI|SVG|PATH|CANVAS|BODY|HTML|A|OTHER)/role=(button|tree|treeitem|list|listitem|option|menuitem|row|grid|tab|tabpanel|redacted|none)/aria=(Layers|Pages|Assets|Move|Close|More|Search|redacted|none)$",
          options: .regularExpression) != nil,
      [
        "none", "none-found", "NotFoundError", "InvalidStateError", "TypeError", "Error",
        "SecurityError", "unknown", "capture-NotFoundError", "capture-InvalidStateError",
        "capture-TypeError", "capture-Error", "capture-SecurityError", "capture-unknown",
        "home-off", "home-ready", "home-disabled", "home-multi", "home-primary", "home-button",
        "home-target", "home-editable", "home-pending", "home-held", "home-moved", "home-armed",
        "home-cancelled", "home-await-click", "home-no-tap", "home-mouse", "home-click",
        "home-expired", "home-click-ancestor", "home-click-other", "home-distance", "home-double",
        "home-detached",
      ].contains(value.detail),
      ["mouse", "touch", "pen", "none"].contains(value.pointerType),
      (0...31).contains(value.buttons), value.drag >= 0,
      [value.x, value.y].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
      value.time.isFinite, value.time >= 0
    else { return nil }
    return value
  }
}
