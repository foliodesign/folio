import Foundation
import WebKit

/// Runtime URLs stay in memory. File identity ignores route, title, query and fragment.
enum TabNavigationRouter {
  enum Destination: Equatable {
    case file(String)
    case creation
    case dashboard
    case auth
    case external
  }

  enum Action: Equatable {
    case allow
    case openFile
    case selectHome
  }

  static func classify(_ url: URL) -> Destination {
    if url.scheme == "https", url.host?.lowercased() == "figma.new",
      url.user == nil, url.password == nil, url.port == nil || url.port == 443,
      url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil
    {
      return .creation
    }
    if PopupPolicy.isGoogleOAuth(url) { return .auth }
    guard url.scheme == "https", url.user == nil, url.password == nil,
      url.port == nil || url.port == 443,
      ["figma.com", "www.figma.com"].contains(url.host?.lowercased() ?? "")
    else { return .external }
    guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
      !path.lowercased().contains("%2f")
    else { return .external }
    let parts = url.path.split(separator: "/").map(String.init)
    if parts == ["new"] { return .creation }
    if parts.count >= 2,
      ["design", "file", "board", "proto", "slides", "site", "make"].contains(parts[0]),
      parts[1].range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
    {
      if ["design", "file"].contains(parts[0]), parts[1] == "new" { return .creation }
      return .file(parts[1])
    }
    if let first = parts.first,
      ["login", "signup", "oauth", "sso", "auth", "logout"].contains(first)
    {
      return .auth
    }
    if parts.isEmpty
      || ["files", "projects", "project", "settings", "search", "teams", "team"]
        .contains(parts[0])
    {
      return .dashboard
    }
    return .external
  }

  static let newDesignURL = URL(string: "https://www.figma.com/file/new")!

  enum Event: String {
    case trustedAnchor, navigationAction, nilTargetChild, blankPromotion, observedURL, redirect
    case homeHandoff, homeRestore, documentDashboard, handoffSuppressed
    case automaticChildRejected
    case dashboardReloadRejected
  }

  /// Fixed public route labels only. Unknown path components and all query values stay private.
  static func dashboardEvidence(_ url: URL) -> String {
    let labels: Set<String> = [
      "recents", "recent", "drafts", "trash", "deleted", "search", "projects", "files", "teams",
      "team", "project", "settings",
    ]
    let parts = url.path.lowercased().split(separator: "/").map(String.init)
    let section = parts.last(where: { labels.contains($0) }) ?? "other"
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let trashHint =
      parts.contains("trash") || parts.contains("deleted")
      || query.contains { ["trash", "deleted"].contains($0.value?.lowercased() ?? "") }
    return
      "dashboardSection=\(section) pathDepth=\(min(parts.count, 8)) queryPresent=\(!query.isEmpty) fragmentPresent=\(url.fragment != nil) trashHint=\(trashHint)"
  }

  /// Fixed labels only: no URLs, keys, titles, auth hosts, query or document contents.
  static func evidence(_ event: Event, url: URL?, input: Input? = nil) -> String {
    let destination: String
    if let url {
      switch classify(url) {
      case .file: destination = "file"
      case .creation: destination = "creation"
      case .dashboard: destination = "dashboard"
      case .auth: destination = "auth"
      case .external: destination = url.absoluteString == "about:blank" ? "blank" : "external"
      }
    } else {
      destination = "none"
    }
    let method = input.map { ["GET", "POST"].contains($0.method) ? $0.method : "other" } ?? "none"
    let frame =
      input.map { $0.targetFrame?.rawValue ?? ($0.mainFrame ? "main" : "subframe") } ?? "none"
    let main = input.map { String($0.mainFrame) } ?? "none"
    let sourceMain = input.map { String($0.sourceMainFrame) } ?? "none"
    return
      "Tab route event=\(event.rawValue) destination=\(destination) kind=\(input?.kind.rawValue ?? -1) method=\(method) main=\(main) target=\(frame) sourceMain=\(sourceMain) download=\(input?.download == true)"
  }

  /// Copy public action metadata, never construct framework navigation/frame instances.
  enum Frame: String { case absent, main, subframe }

  struct Input {
    let destination: URL
    var mainFrame = true
    var targetFrame: Frame?
    var sourceMainFrame = true
    var method = "GET"
    var download = false
    var kind: WKNavigationType = .linkActivated
    var modifiers: UIKeyModifierFlags = []
    var button: UIEvent.ButtonMask = []
  }

  static func action(home: Bool, currentURL: URL?, input: Input) -> Action {
    // Home must intercept ordinary GET location/redirect actions as well as links.
    // Document initial loads, reloads and redirects retain their supplied request.
    guard
      input.kind == .linkActivated
        || (home && [.other, .reload, .backForward].contains(input.kind))
    else { return .allow }
    if input.mainFrame, input.method == "GET", !input.download,
      input.modifiers.contains(.command) || input.button.contains(.init(rawValue: 1 << 2)),
      case .file = classify(input.destination)
    {
      return .openFile
    }
    return navigationAction(
      home: home, currentURL: currentURL, destination: input.destination,
      mainFrame: input.mainFrame, method: input.method, download: input.download)
  }

  static func navigationAction(
    home: Bool, currentURL: URL?, destination: URL,
    mainFrame: Bool, method: String, download: Bool
  ) -> Action {
    guard mainFrame, method == "GET", !download else { return .allow }
    return action(home: home, currentURL: currentURL, destination: destination)
  }

  static func action(home: Bool, currentURL: URL?, destination: URL) -> Action {
    switch classify(destination) {
    case .file(let key):
      if !home, let currentURL, classify(currentURL) == .file(key) { return .allow }
      return .openFile
    case .creation: return .openFile
    case .dashboard: return home ? .allow : .selectHome
    case .auth, .external: return .allow
    }
  }
}
