import Foundation

struct KeyboardRoutingCapture: Codable, Equatable {
  enum Chord: String, Codable {
    case none
    case undo = "Cmd+Z"
    case redo = "Cmd+Shift+Z"
    case redoY = "Cmd+Y"
  }
  enum Event: String, Codable { case keydown, keyup, beforeinput, input, snapshot }
  enum Phase: String, Codable {
    case capture
    case postDispatch = "post-dispatch"
  }
  enum History: String, Codable { case none, historyUndo, historyRedo }
  let chord: Chord
  let event: Event
  let phase: Phase
  let history: History
  let sequence: Int
  let time: Double
  let alt: Bool
  let ctrl: Bool
  let meta: Bool
  let shift: Bool
  let `repeat`: Bool
  let isComposing: Bool
  let isTrusted: Bool
  let defaultPrevented: Bool
  let documentFocus: Bool
  let tag: String
  let inputType: String
  let editable: Bool
  let iframe: Bool

  static func validate(_ payload: [String: Any], data: Data) -> Self? {
    guard
      Set(payload.keys) == [
        "chord", "event", "phase", "history", "sequence", "time", "alt", "ctrl", "meta", "shift",
        "repeat", "isComposing", "isTrusted", "defaultPrevented", "documentFocus", "tag",
        "inputType",
        "editable", "iframe",
      ], let value = try? JSONDecoder().decode(Self.self, from: data),
      (1...9_007_199_254_740_991).contains(value.sequence), value.time.isFinite,
      (0...1_000_000_000_000).contains(value.time),
      ["", "INPUT", "TEXTAREA", "DIV", "SPAN", "BODY", "BUTTON", "SELECT", "IFRAME", "OTHER"]
        .contains(value.tag),
      [
        "", "text", "password", "email", "search", "url", "tel", "number", "checkbox", "radio",
        "button", "submit", "hidden", "other",
      ].contains(value.inputType),
      value.iframe == (value.tag == "IFRAME")
    else { return nil }
    switch value.event {
    case .keydown, .keyup:
      guard value.chord != .none, value.history == .none, value.meta, !value.alt, !value.ctrl,
        value.shift == (value.chord == .redo)
      else { return nil }
    case .beforeinput, .input:
      guard value.chord == .none, value.history != .none else { return nil }
    case .snapshot:
      guard value.chord == .none, value.history == .none, value.phase == .capture else {
        return nil
      }
    }
    return value
  }
}
