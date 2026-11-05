import Combine
import CoreFoundation
import WebKit

enum InterfaceZoomPreset: Double, CaseIterable {
  case half = 0.5
  case threeQuarters = 0.75
  case small = 0.8
  /// iPhone only: offered in the picker, no longer a default.
  case phoneExpanded = 0.85
  case actual = 1
  case large = 1.25
  case larger = 1.5
  case double = 2
  var title: String { "\(Int((rawValue * 100).rounded()))%" }

  /// Presets offered in menus and Settings and used for zoom steps. iPad keeps its list.
  @MainActor static var available: [Self] {
    PhoneExperiencePolicy.isPhone ? allCases : allCases.filter { $0 != .phoneExpanded }
  }
}

struct InterfaceZoomState: Equatable {
  let scale: Double
  var percent: String { "\(Int((scale * 100).rounded()))%" }
  var canDecrease: Bool { scale > 0.5 }
  var canIncrease: Bool { scale < 2 }
}

enum InterfaceZoomAction {
  case decrease, increase, reset
  case preset(InterfaceZoomPreset)
}

/// App-owned on iPad and shared by every window. On iPhone each scene owns one, with separate
/// saved values for the phone-size (compact) and unfolded Duo (expanded) layouts, so a fold
/// rescales only its own window and never overwrites the other layout's choice.
/// Registers main views only.
@MainActor
final class InterfaceZoomStore: ObservableObject {
  static let preferenceKey = "folio.interfaceZoom"
  static let expandedPreferenceKey = "folio.interfaceZoom.phoneExpanded"
  @Published private(set) var state: InterfaceZoomState
  let defaults: UserDefaults
  /// iPhone: true for phone-size windows, false for the unfolded Duo. Always true on iPad,
  /// where it selects the legacy shared value.
  private(set) var compact = true
  private struct Entry { weak var view: WKWebView? }
  private var views: [Entry] = []

  static func appStore() -> InterfaceZoomStore {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--interface-zoom-lab")
        || ProcessInfo.processInfo.arguments.contains("--browser-chrome-visibility")
      {
        let name = "folio.interfaceZoom.fixture"
        let defaults = UserDefaults(suiteName: name)!
        if ProcessInfo.processInfo.arguments.contains("--interface-zoom-reset") {
          defaults.removePersistentDomain(forName: name)
        }
        return InterfaceZoomStore(defaults: defaults)
      }
    #endif
    return InterfaceZoomStore()
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if PhoneExperiencePolicy.isPhone { Self.migratePhoneDefault(in: defaults) }
    let scale = Self.saved(in: defaults, compact: true)
    state = InterfaceZoomState(scale: scale)
    // iPad keeps writing the resolved value. On iPhone only explicit choices save, so a
    // changed default is never frozen into the user's preferences.
    if !PhoneExperiencePolicy.isPhone { defaults.set(scale, forKey: Self.preferenceKey) }
  }

  static let phoneMigrationKey = "folio.phone.zoomDefaultMigration1"

  /// One time: earlier builds saved their 75% / 85% defaults as if chosen. Drop those so the
  /// current default applies.
  private static func migratePhoneDefault(in defaults: UserDefaults) {
    guard !defaults.bool(forKey: phoneMigrationKey) else { return }
    if (defaults.object(forKey: preferenceKey) as? NSNumber)?.doubleValue == 0.75 {
      defaults.removeObject(forKey: preferenceKey)
    }
    if (defaults.object(forKey: expandedPreferenceKey) as? NSNumber)?.doubleValue == 0.85 {
      defaults.removeObject(forKey: expandedPreferenceKey)
    }
    defaults.set(true, forKey: phoneMigrationKey)
  }

  private static func saved(in defaults: UserDefaults, compact: Bool) -> Double {
    let saved =
      defaults.object(forKey: compact ? preferenceKey : expandedPreferenceKey) as? NSNumber
    if let saved, CFGetTypeID(saved) != CFBooleanGetTypeID(), saved.doubleValue.isFinite {
      return clamp(saved.doubleValue)
    }
    return PhoneExperiencePolicy.defaultInterfaceZoom
  }

  /// iPhone: switch to the folded/phone-size or unfolded layout's own zoom. Only geometry
  /// changes call this; it never saves, so explicit choices survive folding. No-op on iPad.
  func setCompact(_ compact: Bool) {
    guard PhoneExperiencePolicy.isPhone, compact != self.compact else { return }
    self.compact = compact
    apply(Self.saved(in: defaults, compact: compact))
  }

  private static func clamp(_ scale: Double) -> Double { min(2, max(0.5, scale)) }

  /// Uses the exact supplied related configuration; never examines its storage or scripts.
  func makeMainWebView(configuration: WKWebViewConfiguration) -> WKWebView {
    let view = WKWebView(frame: .zero, configuration: configuration)
    registerMainWebView(view)
    return view
  }

  func registerMainWebView(_ view: WKWebView) {
    views.removeAll { $0.view == nil }
    if !views.contains(where: { $0.view === view }) { views.append(Entry(view: view)) }
    applyScale(state.scale, to: view)
  }

  var liveMainViewCount: Int {
    views.removeAll { $0.view == nil }
    return views.count
  }

  /// Reject nonfinite runtime values, clamp finite preferences, update every live main view.
  func setScale(_ scale: Double) {
    guard scale.isFinite else { return }
    let validated = Self.clamp(scale)
    defaults.set(validated, forKey: compact ? Self.preferenceKey : Self.expandedPreferenceKey)
    apply(validated)
  }

  private func apply(_ scale: Double) {
    views.removeAll { $0.view == nil }
    for entry in views {
      if let view = entry.view { applyScale(scale, to: view) }
    }
    state = InterfaceZoomState(scale: scale)
  }

  private func applyScale(_ scale: Double, to view: WKWebView) {
    // iOS pageZoom differs from Safari viewport zoom: bugs.webkit.org/show_bug.cgi?id=213603
    // Instead of scaling content relative to a fixed layout viewport,
    // lay out an inverse-sized browser and scale its native presentation to fit.
    // UIKit converts pointer/touch locations into the browser's local coordinates.
    view.pageZoom = 1
    view.transform = CGAffineTransform(scaleX: scale, y: scale)
    view.superview?.setNeedsLayout()
    view.superview?.layoutIfNeeded()
  }

  func send(_ action: InterfaceZoomAction) {
    switch action {
    case .reset: setScale(1)
    case .preset(let preset): setScale(preset.rawValue)
    case .decrease:
      setScale(InterfaceZoomPreset.available.last { $0.rawValue < state.scale }?.rawValue ?? 0.5)
    case .increase:
      setScale(InterfaceZoomPreset.available.first { $0.rawValue > state.scale }?.rawValue ?? 2)
    }
  }
}
