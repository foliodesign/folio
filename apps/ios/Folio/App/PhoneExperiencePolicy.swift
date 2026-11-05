import UIKit

/// Compact-layout and iPhone (Alpha) decisions in one place. The layout rule is per scene and
/// applies to narrow iPad windows too; every device capability below (Pencil, windows, tab
/// limits, defaults) keeps existing behaviour on iPad. Withdraw iPhone builds by returning
/// `TARGETED_DEVICE_FAMILY` to '2' in project.yml.
@MainActor
enum PhoneExperiencePolicy {
  static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

  /// iPad windows narrower than this (points) get the compact layout: phone chrome and the
  /// phone-layout script (decided 2026-10-19). Size classes are not used on iPad, because a
  /// half-screen 11-inch window (about 590-600 pt, more with Display "More Space") reports
  /// compact width but keeps the iPad layout. A one-third split (about 375 pt), Slide Over
  /// (320-375 pt) and narrow Stage Manager windows fall below it.
  static let compactWindowWidth: CGFloat = 500
  /// A compact iPad window returns to the iPad layout only at `compactWindowWidth` plus this,
  /// so a resize that stops near the threshold does not flap.
  static let compactWindowHysteresis: CGFloat = 20

  /// Compact chrome (Home, tab switcher, ⋯, tool strip, sidebar sheet) and the phone-layout
  /// script for a scene. iPhone: compact width or compact height, so a landscape Pro Max stays
  /// compact and the unfolded iPhone Duo (regular/regular) gets the iPad chrome. iPad: only the
  /// window width counts (`compactWindowWidth`); compact height alone never switches.
  static func usesCompactLayout(
    _ traits: UITraitCollection, width: CGFloat, current: Bool
  ) -> Bool {
    if isPhone {
      return traits.horizontalSizeClass != .regular || traits.verticalSizeClass != .regular
    }
    return compactWindow(width: width, current: current)
  }

  /// iPad rule alone, with hysteresis. An unknown (zero) width keeps the current layout.
  static func compactWindow(width: CGFloat, current: Bool) -> Bool {
    guard width > 0 else { return current }
    return width < compactWindowWidth + (current ? compactWindowHysteresis : 0)
  }

  /// Unsaved interface zoom is 100% everywhere, phone-size and unfolded alike.
  static let defaultInterfaceZoom: Double = 1

  static let pencilSeenKey = "folio.phone.pencilSeen"
  static let regularSeenKey = "folio.phone.regularSeen"

  /// iPad always. A phone only once it has shown it is an iPhone Duo (public APIs only): it
  /// reported a regular/regular scene, or delivered an Apple Pencil touch. Both persist.
  static func supportsPencil(_ defaults: UserDefaults = .standard) -> Bool {
    !isPhone || defaults.bool(forKey: pencilSeenKey) || defaults.bool(forKey: regularSeenKey)
  }

  /// Records proof of Pencil support. Returns true when it just made `supportsPencil` true.
  @discardableResult
  static func notePencilSeen(_ defaults: UserDefaults = .standard) -> Bool {
    note(pencilSeenKey, defaults)
  }

  /// Records that a scene was regular in both size classes (unfolded Duo).
  @discardableResult
  static func noteRegularLayout(_ defaults: UserDefaults = .standard) -> Bool {
    note(regularSeenKey, defaults)
  }

  private static func note(_ key: String, _ defaults: UserDefaults) -> Bool {
    guard isPhone, !defaults.bool(forKey: key) else { return false }
    let before = supportsPencil(defaults)
    defaults.set(true, forKey: key)
    if !before {
      NotificationCenter.default.post(name: InputStrategies.touchModeChanged, object: nil)
    }
    return !before
  }

  /// Live file tabs when retention is Automatic. Zero keeps the iPad memory-driven policy.
  static var automaticTabLimit: Int { isPhone ? 1 : 0 }

  /// Explicit retention choices offered in ⋯ and Settings.
  static var tabLimitChoices: [Int] { isPhone ? [0, 2] : [0, 3, 5, 8] }

  /// Shown by default everywhere. On iPhone it is a scrolling strip that replaces Figma's
  /// floating tool bar, so it starts visible there too.
  static var bottomToolbarDefault: Bool { true }

  /// Phones have one window per app; no New window or Move to window.
  static var supportsMultipleWindows: Bool { !isPhone }

  /// The automatic touch mode follows the system Pencil preference only on iPad.
  static var followsSystemPencilPreference: Bool { !isPhone }
}
