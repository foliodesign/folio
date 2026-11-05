import Foundation
import UIKit

enum PencilStrategy: String, CaseIterable {
  case none
  case mouseJS = "pencil-as-mouse-js"
  case gestureReroute = "pencil-gesture-reroute"

  var tier: String { self == .gestureReroute ? "Tier 2 WEBKIT_INTERNAL" : "Tier 1" }
}

enum FingerPanStrategy: String, CaseIterable {
  case baseline
  case page = "finger-pan-page"
  case canvas = "finger-pan-canvas"
}

enum TrackpadPinchRoute: String, CaseIterable, Codable { case wheel, gesture }

enum TouchMode: String, CaseIterable {
  case pencilAndTouch = "pencil-and-touch"
  case touchOnly = "touch-only"

  var title: String { self == .pencilAndTouch ? "Pencil & Touch" : "Touch Only" }
}

@MainActor
final class InputStrategies {
  private let defaults: UserDefaults
  private var overrides: [String: NSObject]?
  // A device verdict is deliberately never restored on another run or OS version.
  var penDragUnusable = false
  init(defaults: UserDefaults = .standard, isolated: Bool = false) {
    self.defaults = defaults
    // Reset persisted experimental focus controls once, before any tab snapshots them.
    let migration = "folio.h1KeyboardFocusMigration"
    if !defaults.bool(forKey: migration) {
      for key in [
        "folio.hardwareKeyboardAssistant", "folio.editorScrollLock",
        "folio.focusViewportLimit", "folio.focusRevealGuard",
      ] {
        defaults.set(false, forKey: key)
      }
      defaults.set(true, forKey: migration)
    }
    if defaults.object(forKey: "folio.resizeHelper") == nil {
      defaults.set(
        defaults.object(forKey: "folio.touchGestures") as? Bool ?? true,
        forKey: "folio.resizeHelper")
    }
    if isolated {
      let keys = [
        "folio.pencil", "folio.finger",
        "folio.trackpadPinchZoom", "folio.trackpadPinchRoute", "folio.fingerCanvasWheel",
        "folio.uaButtonColor", "folio.hideGoogle", "folio.phoneLayout", "folio.phoneWideViewport",
        "folio.phoneNumberKeyboard",
        "folio.touchGestures",
        "folio.resizeHelper",
        "folio.multiFingerTap",
        "folio.focusRevealGuard", "folio.editorScrollLock", "folio.focusViewportLimit",
        "folio.hardwareKeyboardAssistant", "folio.browserFocusRestoration",
      ]
      overrides = keys.reduce(into: [:]) { result, key in
        result[key] = defaults.object(forKey: key) as? NSObject
      }
    }
  }
  static let touchModeChanged = Notification.Name("folio.touchModeChanged")
  /// Shared model API for menus, Settings and future onboarding. User choices always win.
  var touchMode: TouchMode {
    get {
      // Phones without proven Pencil support (not a Duo) are always Touch Only.
      if !PhoneExperiencePolicy.supportsPencil(defaults) { return .touchOnly }
      if let raw = defaults.string(forKey: "folio.touchMode"), let mode = TouchMode(rawValue: raw) {
        return mode
      }
      // Phones start Touch Only until a Pencil is actually observed.
      return defaults.bool(forKey: "folio.pencilSeen")
        || (PhoneExperiencePolicy.followsSystemPencilPreference
          && UIPencilInteraction.prefersPencilOnlyDrawing)
        ? .pencilAndTouch : .touchOnly
    }
    set {
      defaults.set(newValue.rawValue, forKey: "folio.touchMode")
      NotificationCenter.default.post(name: Self.touchModeChanged, object: nil)
    }
  }
  /// Returns true only for the first automatic promotion; this is independent of logging.
  func observePencilTouch() -> Bool {
    PhoneExperiencePolicy.notePencilSeen(defaults)
    guard defaults.object(forKey: "folio.touchMode") == nil,
      !defaults.bool(forKey: "folio.pencilSeen")
    else { return false }
    defaults.set(true, forKey: "folio.pencilSeen")
    NotificationCenter.default.post(name: Self.touchModeChanged, object: nil)
    return true
  }
  func resetTouchMode() {
    defaults.removeObject(forKey: "folio.touchMode")
    NotificationCenter.default.post(name: Self.touchModeChanged, object: nil)
  }

  private func value(_ key: String) -> NSObject? {
    if let overrides { return overrides[key] }
    return defaults.object(forKey: key) as? NSObject
  }
  private func set(_ value: NSObject, forKey key: String) {
    // Existing tabs retain their snapshot; new tabs/relaunch inherit the latest choice.
    if overrides != nil { overrides?[key] = value }
    defaults.set(value, forKey: key)
  }
  var pencil: PencilStrategy {
    get { PencilStrategy(rawValue: (value("folio.pencil") as? String) ?? "") ?? .none }
    set { set(newValue.rawValue as NSString, forKey: "folio.pencil") }
  }
  var finger: FingerPanStrategy {
    get { FingerPanStrategy(rawValue: (value("folio.finger") as? String) ?? "") ?? .baseline }
    set { set(newValue.rawValue as NSString, forKey: "folio.finger") }
  }
  // Pencil bindings are shared across tabs and windows, unlike strategy snapshots.
  var tapAction: PencilAction {
    get { FolioPreferences(defaults: defaults).pencilBinding(squeeze: false) }
    set { FolioPreferences(defaults: defaults).setPencilBinding(newValue, squeeze: false) }
  }
  var squeezeAction: PencilAction {
    get { FolioPreferences(defaults: defaults).pencilBinding(squeeze: true) }
    set { FolioPreferences(defaults: defaults).setPencilBinding(newValue, squeeze: true) }
  }
  static let defaultPinchRoute: TrackpadPinchRoute = .wheel
  var trackpadPinchRoute: TrackpadPinchRoute {
    get {
      TrackpadPinchRoute(rawValue: (value("folio.trackpadPinchRoute") as? String) ?? "")
        ?? Self.defaultPinchRoute
    }
    set { set(newValue.rawValue as NSString, forKey: "folio.trackpadPinchRoute") }
  }
  var trackpadPinchZoom: Bool {
    get { value("folio.trackpadPinchZoom") as? Bool ?? true }
    set { set(NSNumber(value: newValue), forKey: "folio.trackpadPinchZoom") }
  }
  var fingerCanvasWheel: Bool {
    get { value("folio.fingerCanvasWheel") as? Bool ?? true }
    set { set(NSNumber(value: newValue), forKey: "folio.fingerCanvasWheel") }
  }
  var touchGestures: Bool {
    get { value("folio.touchGestures") as? Bool ?? true }
    set { set(NSNumber(value: newValue), forKey: "folio.touchGestures") }
  }
  var multiFingerTap: Bool {
    get { value("folio.multiFingerTap") as? Bool ?? true }
    set { set(NSNumber(value: newValue), forKey: "folio.multiFingerTap") }
  }
  var resizeHelper: Bool {
    get { value("folio.resizeHelper") as? Bool ?? true }
    set { set(NSNumber(value: newValue), forKey: "folio.resizeHelper") }
  }
  var uaButtonColor: Bool {
    get { value("folio.uaButtonColor") as? Bool ?? true }
    set { set(NSNumber(value: newValue), forKey: "folio.uaButtonColor") }
  }
  var hideGoogle: Bool {
    get { value("folio.hideGoogle") as? Bool ?? true }
    set { set(NSNumber(value: newValue), forKey: "folio.hideGoogle") }
  }
  /// iPhone only: Figma's sidebars become one bottom sheet and its tool bar moves into Folio's.
  var phoneLayout: Bool {
    get { value("folio.phoneLayout") as? Bool ?? true }
    set { set(NSNumber(value: newValue), forKey: "folio.phoneLayout") }
  }
  /// iPhone only, experimental: while a sheet is open the web view is widened by Figma's panel
  /// reservation and shifted left, so the canvas stays visible above the sheet.
  var phoneWideViewport: Bool {
    get { value("folio.phoneWideViewport") as? Bool ?? true }
    set { set(NSNumber(value: newValue), forKey: "folio.phoneWideViewport") }
  }
  /// iPhone only: numeric property fields in the panel sheet open the decimal keypad, with
  /// Folio's key row for signs, units and operators.
  var phoneNumberKeyboard: Bool {
    get { value("folio.phoneNumberKeyboard") as? Bool ?? true }
    set { set(NSNumber(value: newValue), forKey: "folio.phoneNumberKeyboard") }
  }
  var editorScrollLock: Bool {
    get { value("folio.editorScrollLock") as? Bool ?? false }
    set { set(NSNumber(value: newValue), forKey: "folio.editorScrollLock") }
  }
  var focusViewportLimit: Bool {
    get { value("folio.focusViewportLimit") as? Bool ?? false }
    set { set(NSNumber(value: newValue), forKey: "folio.focusViewportLimit") }
  }
  var hardwareKeyboardAssistant: Bool {
    get { value("folio.hardwareKeyboardAssistant") as? Bool ?? false }
    set { set(NSNumber(value: newValue), forKey: "folio.hardwareKeyboardAssistant") }
  }
  static let defaultFocusRevealGuard = false
  var focusRevealGuard: Bool {
    get { value("folio.focusRevealGuard") as? Bool ?? Self.defaultFocusRevealGuard }
    set { set(NSNumber(value: newValue), forKey: "folio.focusRevealGuard") }
  }
  // Chrome must not start a WebKit input session unless the owner opts into this candidate.
  var browserFocusRestoration: Bool {
    get { value("folio.browserFocusRestoration") as? Bool ?? false }
    set { set(NSNumber(value: newValue), forKey: "folio.browserFocusRestoration") }
  }
  var savedFocusLabel: String { InputStrategies(defaults: defaults).focusLabel }
  var focusLabel: String {
    "focus-reveal-guard=\(focusRevealGuard) [Tier 1 candidate]; editor-scroll-lock=\(editorScrollLock) [Tier 2 WEBKIT_INTERNAL]; focus-viewport-limit=\(focusViewportLimit) [Tier 1]; hardware-keyboard-assistant=\(hardwareKeyboardAssistant) [Tier 2 WEBKIT_INTERNAL]; browser-focus-restoration=\(browserFocusRestoration) [Tier 2 WEBKIT_INTERNAL candidate, default OFF]"
  }
  func resetFocusSwitches() {
    focusRevealGuard = Self.defaultFocusRevealGuard
    editorScrollLock = false
    focusViewportLimit = false
    hardwareKeyboardAssistant = false
    browserFocusRestoration = false
  }
  /// Defaults for every input switch, focus candidates included.
  func resetInputDefaults() {
    resetFocusSwitches()
    resetTouchMode()
    pencil = .none
    finger = .baseline
    tapAction = .undo
    squeezeAction = .redo
    trackpadPinchRoute = Self.defaultPinchRoute
    trackpadPinchZoom = true
    fingerCanvasWheel = true
    multiFingerTap = true
    touchGestures = true
    resizeHelper = true
    uaButtonColor = true
    hideGoogle = true
    phoneLayout = true
    phoneWideViewport = true
    phoneNumberKeyboard = true
    penDragUnusable = false
  }
  var label: String {
    "touch-mode=\(touchMode.rawValue); \(pencil.rawValue) [\(pencil.tier)]; \(finger.rawValue) [\(finger == .baseline ? "Tier 1" : "Tier 2 WEBKIT_INTERNAL")]; trackpad-pinch-zoom=\(trackpadPinchZoom) [Tier 1]; trackpad-pinch-route=\(trackpadPinchRoute.rawValue) [Tier 1]; finger-pan-canvas-wheel=\(fingerCanvasWheel) [Tier 1]; touch-gestures=\(touchGestures) [Tier 1 DOM, canvas/Home; passive UI hold]; multi-finger-tap=\(multiFingerTap) [Tier 1]; resize-helper=\(resizeHelper) [Tier 1]; ua-button-color=\(uaButtonColor) [Tier 1]; pen drag unusable=\(penDragUnusable); tap=\(tapAction.rawValue); squeeze=\(squeezeAction.rawValue)"
  }
}
