import Foundation

@MainActor
enum EditorFocusPolicy {
  static func allows(_ url: URL?) -> Bool {
    guard let url else { return false }
    if url == ScriptBridge.focusLabURL { return true }
    guard url.scheme == "https", let host = url.host?.lowercased(),
      ["figma.com", "www.figma.com"].contains(host),
      url.user == nil, url.password == nil, url.port == nil || url.port == 443
    else { return false }
    let path = url.path.split(separator: "/")
    return path.count >= 2 && ["design", "file"].contains(String(path[0]))
  }
}
