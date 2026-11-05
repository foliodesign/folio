import Foundation

/// Launch preferences are read when a window is created, never by closing live tabs.
@MainActor
final class FolioPreferences {
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  /// Shown in file tabs. Inherits the retired top-bar edit tools choice once.
  var bottomToolbarVisible: Bool {
    get {
      defaults.object(forKey: "folio.bottomToolbar") as? Bool
        ?? defaults.object(forKey: "folio.toolbarEditTools") as? Bool
        ?? PhoneExperiencePolicy.bottomToolbarDefault
    }
    set {
      defaults.set(newValue, forKey: "folio.bottomToolbar")
      defaults.removeObject(forKey: "folio.toolbarEditTools")
    }
  }

  /// Set when the welcome tour is first presented; replaying it never resets the flag.
  var onboardingSeen: Bool {
    get { defaults.bool(forKey: "folio.onboardingSeen") }
    set { defaults.set(newValue, forKey: "folio.onboardingSeen") }
  }

  var startAtHome: Bool {
    get { defaults.string(forKey: "folio.startPage") == "home" }
    set { defaults.set(newValue ? "home" : "last", forKey: "folio.startPage") }
  }
  var restoreTabs: Bool {
    get { defaults.object(forKey: "folio.restoreTabs") as? Bool ?? true }
    set {
      defaults.set(newValue, forKey: "folio.restoreTabs")
      if !newValue {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("folio.scene.") {
          defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: WindowSession.restorationKey)
        defaults.removeObject(forKey: "folio.lastURL")
      }
    }
  }
}

@MainActor
extension FolioPreferences {
  var pencilActions: [PencilAction] { PencilAction.allCases }

  func pencilBinding(squeeze: Bool) -> PencilAction {
    PencilAction(
      rawValue: defaults.string(forKey: squeeze ? "pencil.squeeze" : "pencil.doubleTap") ?? "")
      ?? (squeeze ? .redo : .undo)
  }

  func setPencilBinding(_ action: PencilAction, squeeze: Bool) {
    defaults.set(action.rawValue, forKey: squeeze ? "pencil.squeeze" : "pencil.doubleTap")
  }
}
