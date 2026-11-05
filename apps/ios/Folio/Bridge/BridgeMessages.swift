import Foundation

struct GraphicsCapture: Codable, Equatable {
  let available: Bool
  let renderer: String
  let maxTextureSize: Int
}

struct TrackpadPinchCapture: Codable, Equatable {
  let route: TrackpadPinchRoute
  let dispatched: Int
  let prevented: Int
  let gestureSupported: Bool
}

struct FocusRevealGuardCapture: Codable, Equatable {
  let restored: Int
  let ignored: Int
}

struct EnvironmentCapture: Codable, Equatable {
  let userAgent: String
  let gpuPresent: Bool
  let adapterResult: String
  let adapterInfo: String
  let webgl: GraphicsCapture
  let webgl2: GraphicsCapture
  let devicePixelRatio: Double
  let viewportWidth: Double
  let viewportHeight: Double
  let maxTouchPoints: Int
  let media: [String: Bool]
  var focusRevealGuard: FocusRevealGuardCapture? = nil
  var trackpadPinch: TrackpadPinchCapture? = nil
}

struct InputCapture: Codable, Equatable {
  let type: String
  let pointerType: String
  let isTrusted: Bool
  let button: Int
  let buttons: Int
  let prevented: Bool
  let coalesced: Int
  let pressure: Double
  let tiltX: Double
  let tiltY: Double
  let x: Double
  let y: Double
  let deltaX: Double
  let deltaY: Double
  var key: String
  let alt: Bool
  let ctrl: Bool
  let meta: Bool
  let shift: Bool
}

/// Figma's active tool as one of Folio's fixed tool keys (the phone strip's `onKey` names).
enum PhoneTool: String, CaseIterable {
  case move, hand, scale, frame, section, slice, rectangle, line, arrow, ellipse, pen, pencil, text
  case comment, measurement, annotation, none
}

/// Known DOM tool ids available in Figma's current visible carousel row.
/// Kept separate from PhoneTool, which drives the pill's active selection; this list decides which
/// of the pill's groups are shown (PhonePillLogic.layout).
enum PhoneVisibleTool: String, CaseIterable {
  case move = "Move-tool"
  case hand = "Hand tool-tool"
  case scale = "Scale-tool"
  case frame = "Frame-tool"
  case section = "Section-tool"
  case slice = "Slice-tool"
  case rectangle = "Rectangle-tool"
  case line = "Line-tool"
  case arrow = "Arrow-tool"
  case ellipse = "Ellipse-tool"
  case pen = "Pen-tool"
  case pencil = "Pencil-tool"
  case text = "Text-tool"
  case comment = "Comment-tool"
  case actions = "Actions-tool"
  case measurement = "Measurement-tool"
  case annotation = "Annotation-tool"
}

/// Figma's editor mode as read from its hidden tool bar; `unknown` when no reliable sign is found.
enum PhoneMode: String, CaseIterable {
  case design, dev, unknown
}

/// iPhone layout state from phone-layout.ts: shown sheet, active tool, Design/Dev Mode, and
/// whether Folio keeps Figma minimized for this tab.
struct PhoneLayoutState: Equatable {
  let panel: String
  let tool: PhoneTool
  var mode: PhoneMode = .unknown
  var visibleTools: [PhoneVisibleTool] = []
  let minimize: Bool
  /// A Figma popover (colour picker, menu, dialog) is open over the canvas or sheet.
  var overlay = false
  /// Layout width (CSS px) native adds left and right of the visible region with "Canvas beside
  /// panels" on: Figma's reservation, minus an open side panel's own part in landscape side
  /// panels. Clamped to 0...1200.
  var left: Double = 0
  var right: Double = 0
  /// iPhone landscape side panels: on-screen width (CSS px) of the open Layers and Properties
  /// panels, so the floating tool pill centres over the canvas between them. Clamped like left.
  var panelLeft: Double = 0
  var panelRight: Double = 0

  /// "both": iPhone landscape side panels, Layers and Properties open together.
  static let panels: Set<String> = ["off", "none", "left", "right", "both"]
  static let reserveRange: ClosedRange<Double> = 0...1200

  static func validate(_ payload: [String: Any]) -> PhoneLayoutState? {
    guard
      Set(payload.keys) == [
        "panel", "tool", "mode", "visibleTools", "minimize", "overlay", "left", "right",
        "panelLeft", "panelRight",
      ],
      let panel = payload["panel"] as? String, panels.contains(panel),
      let tool = (payload["tool"] as? String).flatMap(PhoneTool.init(rawValue:)),
      let mode = (payload["mode"] as? String).flatMap(PhoneMode.init(rawValue:)),
      let ids = payload["visibleTools"] as? [String],
      ids.count <= PhoneVisibleTool.allCases.count, Set(ids).count == ids.count,
      ids.allSatisfy({ PhoneVisibleTool(rawValue: $0) != nil }),
      let minimize = payload["minimize"] as? Bool,
      let overlay = payload["overlay"] as? Bool,
      let left = (payload["left"] as? NSNumber)?.doubleValue, left.isFinite,
      let right = (payload["right"] as? NSNumber)?.doubleValue, right.isFinite,
      let panelLeft = (payload["panelLeft"] as? NSNumber)?.doubleValue, panelLeft.isFinite,
      let panelRight = (payload["panelRight"] as? NSNumber)?.doubleValue, panelRight.isFinite
    else { return nil }
    let clamp = { (value: Double) in
      min(reserveRange.upperBound, max(reserveRange.lowerBound, value.rounded()))
    }
    return PhoneLayoutState(
      panel: panel, tool: tool, mode: mode,
      visibleTools: ids.compactMap(PhoneVisibleTool.init(rawValue:)), minimize: minimize,
      overlay: overlay,
      left: clamp(left), right: clamp(right), panelLeft: clamp(panelLeft),
      panelRight: clamp(panelRight))
  }
}

/// iPhone sheet field state from phone-layout.ts: whether the focused sheet field is numeric
/// (show the key row). The sheet's keyboard raise is native's (BrowserWindowController).
struct PhoneFieldState: Equatable {
  let numeric: Bool

  static func validate(_ payload: [String: Any]) -> PhoneFieldState? {
    guard Set(payload.keys) == ["numeric"], let numeric = payload["numeric"] as? Bool
    else { return nil }
    return PhoneFieldState(numeric: numeric)
  }
}

enum BridgeMessage: Equatable {
  case keyboard(KeyboardRoutingCapture)
  case diagnostics(EnvironmentCapture)
  case input(InputCapture)
  case focus(FocusCapture)
  case uiDrag(UIDragCapture)
  case focusAssistant
  case labResults([String: String])
  case phoneState(PhoneLayoutState)
  case phoneField(PhoneFieldState)

  static let labItems: Set<String> = [
    "finger tap", "one-finger drag", "two-finger pan", "pinch", "mouse click", "mouse drag",
    "mouse wheel", "trackpad scroll", "trackpad pinch", "Pencil tap", "Pencil drag", "Pencil hover",
    "keyboard modifiers", "keyboard shortcuts", "text field", "text-layer editing",
  ]

  static let mediaKeys: Set<String> = [
    "pointer:none", "pointer:coarse", "pointer:fine", "any-pointer:none", "any-pointer:coarse",
    "any-pointer:fine", "hover:none", "hover:hover", "any-hover:none", "any-hover:hover",
  ]
  static let inputTypes: Set<String> = [
    "pointerdown", "pointerup", "pointermove", "pointercancel", "pointerover", "pointerout",
    "pointerenter", "pointerleave", "gotpointercapture", "lostpointercapture", "touchstart",
    "touchmove", "touchend", "touchcancel", "mousedown", "mouseup", "mousemove", "mouseover",
    "mouseout", "mouseenter", "mouseleave", "click", "dblclick", "contextmenu", "wheel",
    "gesturestart", "gesturechange", "gestureend", "keydown",
    "keyup",
  ]

  private static func validPinch(_ payload: Any?, _ capture: TrackpadPinchCapture?) -> Bool {
    guard let payload else { return capture == nil }
    guard let dict = payload as? [String: Any], let capture,
      Set(dict.keys) == ["route", "dispatched", "prevented", "gestureSupported"]
    else { return false }
    return capture.dispatched >= 0 && capture.prevented >= 0
      && capture.prevented <= capture.dispatched
  }

  private static func validRevealGuard(_ payload: Any?, _ capture: FocusRevealGuardCapture?) -> Bool
  {
    guard let payload else { return capture == nil }
    guard let dict = payload as? [String: Any], let capture,
      Set(dict.keys) == ["restored", "ignored"]
    else { return false }
    return capture.restored >= 0 && capture.ignored >= 0
  }

  static func validate(_ body: Any) -> BridgeMessage? {
    guard let envelope = body as? [String: Any], Set(envelope.keys) == ["name", "payload"],
      let name = envelope["name"] as? String, let payload = envelope["payload"] as? [String: Any],
      JSONSerialization.isValidJSONObject(payload),
      let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= 8192
    else { return nil }
    let decoder = JSONDecoder()
    switch name {
    case "folioKeyboardRouting":
      guard let value = KeyboardRoutingCapture.validate(payload, data: data) else { return nil }
      return .keyboard(value)
    case "folioUIDrag":
      guard let value = UIDragCapture.validate(payload, data: data) else { return nil }
      return .uiDrag(value)
    case "folioFocusAssist":
      return payload.isEmpty ? .focusAssistant : nil
    case "folioPhoneState":
      return PhoneLayoutState.validate(payload).map { .phoneState($0) }
    case "folioPhoneField":
      return PhoneFieldState.validate(payload).map { .phoneField($0) }
    case "folioFocusLog":
      guard
        Set(payload.keys) == [
          "event", "tag", "inputType", "innerWidth", "innerHeight", "width", "height", "offsetLeft",
          "offsetTop", "scale", "scrollX", "scrollY", "time",
        ],
        let value = try? decoder.decode(FocusCapture.self, from: data),
        [
          "focusin", "focusout", "windowresize", "windowscroll", "viewportresize", "viewportscroll",
          "logging-enabled", "revealguard", "innerscroll",
        ].contains(value.event),
        ["", "INPUT", "TEXTAREA", "DIV", "SPAN", "BODY", "BUTTON", "SELECT", "IFRAME", "OTHER"]
          .contains(value.tag),
        [
          "", "text", "password", "email", "search", "url", "tel", "number", "checkbox", "radio",
          "button", "submit", "hidden", "other",
        ].contains(value.inputType),
        [value.innerWidth, value.innerHeight, value.width, value.height].allSatisfy(validDimension),
        [value.offsetLeft, value.offsetTop, value.scrollX, value.scrollY].allSatisfy({
          $0.isFinite && abs($0) <= 1_000_000
        }),
        value.scale.isFinite, (0.01...100).contains(value.scale), value.time.isFinite,
        value.time >= 0
      else { return nil }
      return .focus(value)
    case "folioDiagnostics":
      let keys: Set<String> = [
        "userAgent", "gpuPresent", "adapterResult", "adapterInfo", "webgl", "webgl2",
        "devicePixelRatio", "viewportWidth", "viewportHeight", "maxTouchPoints", "media",
      ]
      guard Set(payload.keys).subtracting(["trackpadPinch", "focusRevealGuard"]) == keys,
        let value = try? decoder.decode(EnvironmentCapture.self, from: data),
        validPinch(payload["trackpadPinch"], value.trackpadPinch),
        validRevealGuard(payload["focusRevealGuard"], value.focusRevealGuard),
        value.userAgent.count <= 1024, value.adapterInfo.count <= 1024,
        ["available", "unavailable", "null", "timed out", "requestAdapter error"].contains(
          value.adapterResult),
        validGraphics(payload["webgl"], value.webgl),
        validGraphics(payload["webgl2"], value.webgl2),
        value.devicePixelRatio.isFinite, (0.1...10).contains(value.devicePixelRatio),
        validDimension(value.viewportWidth), validDimension(value.viewportHeight),
        (0...100).contains(value.maxTouchPoints), Set(value.media.keys) == mediaKeys
      else { return nil }
      return .diagnostics(value)
    case "folioLabResults":
      guard Set(payload.keys) == ["results"], let results = payload["results"] as? [String: String],
        Set(results.keys) == labItems, results["text-layer editing"] == "NOT TESTED",
        results.values.allSatisfy({ ["NOT TESTED", "PASS", "FAIL"].contains($0) })
      else { return nil }
      return .labResults(results)
    case "folioInputLog":
      let keys: Set<String> = [
        "type", "pointerType", "isTrusted", "button", "buttons", "prevented", "coalesced",
        "pressure", "tiltX", "tiltY",
        "x", "y",
        "deltaX", "deltaY", "key", "alt", "ctrl", "meta", "shift",
      ]
      guard Set(payload.keys) == keys,
        var value = try? decoder.decode(InputCapture.self, from: data),
        inputTypes.contains(value.type),
        ["mouse", "touch", "pen", "none"].contains(value.pointerType),
        (-1...5).contains(value.button), (0...31).contains(value.buttons),
        (0...10000).contains(value.coalesced),
        (0...1).contains(value.pressure),
        (-90...90).contains(value.tiltX), (-90...90).contains(value.tiltY),
        [value.x, value.y, value.deltaX, value.deltaY].allSatisfy({
          $0.isFinite && abs($0) <= 1_000_000
        }),
        value.key.count <= 64
      else { return nil }
      let allowedKeys: Set<String> = [
        "", "<char>", "Enter", "Tab", "Escape", "Backspace", "Delete", "ArrowUp", "ArrowDown",
        "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown", "Shift", "Control", "Alt",
        "Meta", "CapsLock", "Unidentified", "Dead", "Space", "Cmd+C", "Cmd+V", "Cmd+Z",
        "Cmd+Shift+Z", "Cmd+Y", "Cmd+D",
      ]
      if !allowedKeys.contains(value.key) { value.key = "<char>" }
      return .input(value)
    default: return nil
    }
  }

  private static func validDimension(_ value: Double) -> Bool {
    value.isFinite && (0...100_000).contains(value)
  }
  private static func validGraphics(_ payload: Any?, _ value: GraphicsCapture) -> Bool {
    guard let object = payload as? [String: Any],
      Set(object.keys) == ["available", "renderer", "maxTextureSize"]
    else { return false }
    return value.renderer.count <= 256 && (0...1_048_576).contains(value.maxTextureSize)
  }
}
