import Foundation

enum BrowserMode: String, CaseIterable {
  case normal = "Normal"
  case compatibility = "Compatibility"
  case safe = "Safe"
}

@MainActor
final class SessionState {
  // Logged out, /files redirects to Figma's login; logged in, it shows the file browser.
  static let startURL = URL(string: "https://www.figma.com/files")!
  private let defaults: UserDefaults
  private var tabURL: URL?
  private var tabMode: BrowserMode?
  private var tabCrashes = 0
  var onRecoveryURLChange: (() -> Void)?
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  init(tabURL: URL, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.tabURL = Privacy.recoveryURL(tabURL) ?? Self.startURL
    self.tabMode = BrowserMode(rawValue: defaults.string(forKey: "folio.mode") ?? "") ?? .normal
  }

  var mode: BrowserMode {
    get { tabMode ?? BrowserMode(rawValue: defaults.string(forKey: "folio.mode") ?? "") ?? .normal }
    set {
      if tabMode != nil {
        tabMode = newValue
      } else {
        defaults.set(newValue.rawValue, forKey: "folio.mode")
      }
    }
  }
  var crashCount: Int { tabURL != nil ? tabCrashes : defaults.integer(forKey: "folio.crashCount") }
  var lastURL: URL {
    get {
      if let tabURL { return tabURL }
      guard let value = defaults.string(forKey: "folio.lastURL"), let url = URL(string: value),
        let safeURL = Privacy.recoveryURL(url)
      else {
        defaults.removeObject(forKey: "folio.lastURL")
        return Self.startURL
      }
      defaults.set(safeURL.absoluteString, forKey: "folio.lastURL")
      return safeURL
    }
    set {
      guard let url = Privacy.recoveryURL(newValue) else { return }
      if tabURL != nil {
        tabURL = url
        onRecoveryURLChange?()
      } else {
        defaults.set(url.absoluteString, forKey: "folio.lastURL")
      }
    }
  }
  func recordCrash() {
    if tabURL != nil {
      tabCrashes += 1
    } else {
      defaults.set(crashCount + 1, forKey: "folio.crashCount")
    }
  }
}
