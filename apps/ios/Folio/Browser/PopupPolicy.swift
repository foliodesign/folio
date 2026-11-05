import Foundation

/// URL-only decisions. Never retain or report auth parameters.
enum PopupPolicy {
  static func isFigmaPage(_ url: URL?) -> Bool {
    guard let url else { return false }
    return url.scheme == "https" && url.user == nil && url.password == nil
      && (url.port == nil || url.port == 443)
      && ["figma.com", "www.figma.com"].contains(url.host?.lowercased() ?? "")
  }

  /// Home may open Figma's account flow, never an external/Google destination.
  static func allowsHomeAuthWindow(_ url: URL?) -> Bool {
    guard let url, isFigmaPage(url) else { return false }
    return TabNavigationRouter.classify(url) == .auth
  }

  /// Automatic document children cannot enter authentication or external sites.
  static func allowsDocumentWindow(_ url: URL?) -> Bool {
    guard let url else { return false }
    if url.absoluteString == "about:blank" { return true }
    switch TabNavigationRouter.classify(url) {
    case .file, .creation: return true
    default: return false
    }
  }

  static func allows(_ url: URL?, localURLs: [URL] = []) -> Bool {
    guard let url else { return false }
    if url.absoluteString == "about:blank" { return true }
    if localURLs.contains(url), url.isFileURL { return true }
    return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
  }

  static func isGoogleOAuth(_ url: URL?) -> Bool {
    guard let url, url.scheme == "https", url.host?.lowercased() == "accounts.google.com" else {
      return false
    }
    return ["/o/oauth2", "/o/oauth", "/signin/oauth"].contains {
      url.path == $0 || url.path.hasPrefix($0 + "/")
    } || isGoogleEmbeddedError(url)
  }

  static func isGoogleEmbeddedError(_ url: URL?) -> Bool {
    guard let url, url.scheme == "https", url.host?.lowercased() == "accounts.google.com",
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return false }
    for item in parts.queryItems ?? [] {
      if item.name == "error", item.value == "disallowed_useragent" { return true }

    }
    return false
  }

  static func hostLabel(_ url: URL?) -> String {
    guard let url else { return "New window" }
    if url.absoluteString == "about:blank" { return "New window" }
    if url.isFileURL { return "Local test page" }
    switch url.host?.lowercased() {
    case "figma.com": return "figma.com"
    case "www.figma.com": return "www.figma.com"
    case "accounts.google.com": return "accounts.google.com"
    default: return "External site"
    }
  }

  static let googleMessage =
    "Google sign-in cannot run in this embedded browser. Close this window and use Figma's email and password option if your account allows it, or your organization's supported SSO. You can also use Figma in Safari. Signing in there does not sign Folio in."
}
