import WebKit

/// The Google exception (maintainer, 2026-10-09) inside sign-in sheets (2026-11-11). Related
/// children such as Add account stay script-free, so `hide-google.ts` never runs there; this
/// WebKit content rule list hides the same two things with CSS, applied by WebKit itself:
/// Figma's hollow brand button in the sign-in view (today only "Continue with Google") and the
/// "or" line after it. Figma's login and sign-up pages only. Selectors from the maintainer's
/// annotation of www.figma.com/login, 2026-11-11.
@MainActor
enum SignInRules {
  /// Compiled once per launch; nil until ready or if WebKit rejects the rules.
  private(set) static var list: WKContentRuleList?
  private static var compiling = false

  static let selector =
    "#auth-view-page > button[class*=\"brand_buttons--hollowButton--\"],"
    + "#auth-view-page > p[class*=\"sign_in_and_up--orBlock--\"]"

  /// One rule per path: content-blocker patterns have no alternation.
  static var encoded: String {
    let rules = ["login", "signup", "email_signup", "join"].map { path -> [String: Any] in
      [
        "trigger": ["url-filter": "^https://(www\\.)?figma\\.com/\(path)"],
        "action": ["type": "css-display-none", "selector": selector],
      ]
    }
    let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  /// Compiles the list in the background, early, so it is ready before any sign-in sheet.
  static func prepare() {
    guard list == nil, !compiling, let store = WKContentRuleListStore.default() else { return }
    compiling = true
    store.compileContentRuleList(
      forIdentifier: "folio.sign-in.v1", encodedContentRuleList: encoded
    ) { compiled, _ in
      MainActor.assumeIsolated {
        list = compiled
        compiling = false
      }
    }
  }
}
