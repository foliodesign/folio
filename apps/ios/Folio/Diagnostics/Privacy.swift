import Foundation

enum Privacy {
  static let fileRoutes: Set<String> = [
    "file", "design", "proto", "board", "slides", "site", "make",
  ]

  // Restore only a file key; anything else falls back to the file browser. Never persist OAuth paths, query values or fragments.
  static func recoveryURL(_ url: URL) -> URL? {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme == "https", let host = parts.host?.lowercased(),
      ["figma.com", "www.figma.com"].contains(host), parts.port == nil || parts.port == 443
    else { return nil }
    let path = parts.percentEncodedPath.split(separator: "/").map(String.init)
    var result = URLComponents()
    result.scheme = "https"
    result.host = "www.figma.com"
    if path.count >= 2, fileRoutes.contains(path[0]),
      path[1].range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
    {
      result.percentEncodedPath = "/" + path[0] + "/" + path[1]
    } else {
      result.path = "/files"
    }
    return result.url
  }

  static func redactedURL(_ url: URL?) -> String {
    guard let url, let host = url.host else { return "unavailable" }
    guard ["figma.com", "www.figma.com"].contains(host.lowercased()) else {
      return "<external>"
    }
    let parts = url.path.split(separator: "/").map(String.init)
    guard let route = parts.first?.lowercased() else { return host + "/" }
    if fileRoutes.contains(route) { return host + "/" + route + "/<file>" }
    if parts.count == 1 && ["login", "signup", "files"].contains(route) {
      return host + "/" + route
    }
    return host + "/<path>"
  }

  static func sanitize(_ value: String) -> String {
    var result = value
    let patterns = [
      #"https?://[^\s]+"#,
      #"(?i)(?:bearer\s+)[a-z0-9._~+/=-]+"#,
      #"(?i)(?:token|password|secret|authorization|cookie|code)\s*[:=]\s*[^\s,;]+"#,
      #"\beyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\b"#,
    ]
    for pattern in patterns {
      result = result.replacingOccurrences(
        of: pattern, with: "<redacted>", options: .regularExpression)
    }
    return String(result.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" })
  }
}
