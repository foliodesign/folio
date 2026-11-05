import Foundation

enum PublicSite {
  static let baseURL = URL(string: "https://foliodesign.app")!
  static let supportURL = baseURL.appendingPathComponent("support")
  static let privacyURL = baseURL.appendingPathComponent("privacy")
  static let termsURL = baseURL.appendingPathComponent("terms")
  static let legalURL = baseURL.appendingPathComponent("legal")
}

// Shared by the app and extension. Never log an incoming URL.
enum FolioLink {
  static let appGroup = "group.app.foliodesign.folio"
  static func validated(_ url: URL) -> URL? {
    guard url.absoluteString.count <= 8192,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == "https",
      let host = parts.host?.lowercased(), ["figma.com", "www.figma.com"].contains(host),
      parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443
    else { return nil }
    return url
  }
  static func decode(_ url: URL) -> URL? {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme == "folio", parts.host == "open", parts.path.isEmpty,
      parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
      let items = parts.queryItems, items.count == 1, items[0].name == "url",
      let value = items[0].value, let destination = URL(string: value)
    else { return nil }
    return validated(destination)
  }
}

// Only the recovery route crosses processes/disk, never query/fragment/title/auth information.
@MainActor
struct SharedLinkInbox {
  let defaults: UserDefaults
  static var shared: SharedLinkInbox? {
    UserDefaults(suiteName: FolioLink.appGroup).map { SharedLinkInbox(defaults: $0) }
  }
  func save(_ url: URL) -> Bool {
    guard FolioLink.validated(url) != nil, let route = Privacy.recoveryURL(url) else {
      return false
    }
    defaults.set(route.absoluteString, forKey: "pendingRoute")
    return true
  }
  func take() -> URL? {
    let value = defaults.string(forKey: "pendingRoute")
    defaults.removeObject(forKey: "pendingRoute")
    guard let value, let url = URL(string: value), FolioLink.validated(url) != nil else {
      return nil
    }
    return Privacy.recoveryURL(url)
  }
}
