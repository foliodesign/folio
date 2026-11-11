import UIKit
import WebKit

/// An opener-related child using WebKit's supplied configuration, with no Folio injection.
/// Shown as a sheet over its tab (maintainer, 2026-11-11: like the system's sign-in sheets):
/// Close at the leading edge, the site's host in the middle; a swipe down closes it too. A
/// child that went through Figma's sign-in closes itself once it lands back on Figma's file
/// browser, as Figma's own Add account tab does in Safari.
@MainActor
final class PopupController: UIViewController, WKNavigationDelegate, WKUIDelegate,
  UIAdaptivePresentationControllerDelegate
{
  private(set) var browser: WKWebView?
  private(set) var message: String?
  var onOwnershipTransition: (() -> Void)?
  enum Promotion { case adopted, selectedExisting, declined }
  var onRouteEvidence: ((TabNavigationRouter.Event, URL?) -> Void)?
  var onPromote: ((URL, WKWebView) -> Promotion)?
  #if DEBUG
    var offlinePromotion = false
  #endif
  private var mayPromote: Bool
  var onClose: (() -> Void)?
  /// After `onClose`, when the sheet closed itself because a sign-in finished.
  var onSignInFinished: (() -> Void)?
  private let host = UILabel()
  private let header = UIView()
  private let notice = UILabel()
  /// The main frame has shown a Figma sign-in page (login, sign-up, SSO).
  private var sawSignIn = false
  private var closed = false
  private let localURLs: [URL]
  private let documentOnly: Bool

  init(
    configuration: WKWebViewConfiguration, url: URL?, localURLs: [URL] = [],
    documentOnly: Bool = false, signInRules: WKContentRuleList? = nil
  ) {
    self.localURLs = localURLs
    self.documentOnly = documentOnly
    mayPromote = url?.absoluteString == "about:blank"
    super.init(nibName: nil, bundle: nil)
    // Do not remove handlers/scripts from the inherited controller: it may be the parent's.
    configuration.userContentController = WKUserContentController()
    // CSS hiding only (Google button, "or" line on Figma's sign-in pages); still no script.
    if let signInRules { configuration.userContentController.add(signInRules) }
    // Preserve the child baseline: no automatic windows and no inherited Folio scripts.
    configuration.preferences = WKPreferences()
    browser = WKWebView(frame: .zero, configuration: configuration)
    browser?.navigationDelegate = self
    browser?.uiDelegate = self
    host.text = PopupPolicy.hostLabel(url)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityViewIsModal = true
    view.backgroundColor = .systemBackground
    host.font = .preferredFont(forTextStyle: .headline)
    host.textAlignment = .center
    host.lineBreakMode = .byTruncatingMiddle
    host.accessibilityIdentifier = "popupHost"
    let close = UIButton(type: .system)
    close.setTitle("Close", for: .normal)
    close.titleLabel?.font = .preferredFont(forTextStyle: .body)
    close.accessibilityIdentifier = "popupClose"
    close.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
    for item in [host, close] as [UIView] {
      item.translatesAutoresizingMaskIntoConstraints = false
      header.addSubview(item)
    }
    let divider = UIView()
    divider.backgroundColor = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(divider)
    header.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(header)
    let scale = max(1, traitCollection.displayScale)
    NSLayoutConstraint.activate([
      header.heightAnchor.constraint(equalToConstant: 52),
      close.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      host.centerXAnchor.constraint(equalTo: header.centerXAnchor),
      host.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      host.leadingAnchor.constraint(greaterThanOrEqualTo: close.trailingAnchor, constant: 12),
      host.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
      divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
      divider.heightAnchor.constraint(equalToConstant: 1 / scale),
    ])
    notice.numberOfLines = 0
    notice.font = .preferredFont(forTextStyle: .body)
    notice.accessibilityIdentifier = "popupNotice"
    notice.translatesAutoresizingMaskIntoConstraints = false
    notice.isHidden = true
    view.addSubview(notice)
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      header.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      header.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      notice.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
      notice.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      notice.trailingAnchor.constraint(equalTo: header.trailingAnchor),
    ])
    if let browser {
      browser.translatesAutoresizingMaskIntoConstraints = false
      view.insertSubview(browser, belowSubview: notice)
      NSLayoutConstraint.activate([
        browser.topAnchor.constraint(equalTo: header.bottomAnchor),
        browser.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        browser.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        browser.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      ])
    }
  }

  func showMessage(_ text: String) {
    guard message == nil else { return }
    loadViewIfNeeded()
    message = text
    releaseBrowser()
    notice.text = text
    notice.isHidden = false
    onOwnershipTransition?()
  }

  private func releaseBrowser() {
    browser?.stopLoading()
    browser?.navigationDelegate = nil
    browser?.uiDelegate = nil
    browser?.removeFromSuperview()
    browser = nil
  }

  /// Releases the child and takes the sheet down (`animated` false when the tab itself goes).
  func close(animated: Bool = true) {
    guard !closed else { return }
    closed = true
    releaseBrowser()
    if presentingViewController != nil, !isBeingDismissed {
      presentingViewController?.dismiss(animated: animated)
    }
    let callback = onClose
    onClose = nil
    callback?()
  }

  /// A swipe down closed the sheet: release the child as Close does.
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    close(animated: false)
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    guard webView === browser, let url = webView.url else { return }
    switch TabNavigationRouter.classify(url) {
    case .auth: sawSignIn = true
    // Signed in: Figma heads back to its file browser. Its opener already shows the account.
    case .dashboard where sawSignIn:
      onRouteEvidence?(.signInFinished, url)
      let finished = onSignInFinished
      onSignInFinished = nil
      close()
      finished?()
    default: break
    }
  }

  func webViewDidClose(_ webView: WKWebView) {
    guard webView === browser else { return }
    close()
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard webView === browser else { return }
    showMessage("This window stopped. The cause is unavailable. Close it and try again.")
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    guard webView === browser, message == nil else {
      decisionHandler(.cancel)
      return
    }
    let url = navigationAction.request.url
    if documentOnly, !PopupPolicy.allowsDocumentWindow(url) {
      decisionHandler(.cancel)
      onRouteEvidence?(.automaticChildRejected, url)
      close()
      return
    }
    // Once a blank child enters authentication or an external site it remains an
    // isolated popup, even if that flow later returns an editor URL.
    if navigationAction.targetFrame?.isMainFrame != false,
      let url, url.absoluteString != "about:blank"
    {
      switch TabNavigationRouter.classify(url) {
      case .auth, .external: mayPromote = false
      default: break
      }
    }
    if PopupPolicy.isGoogleOAuth(url) {
      if navigationAction.targetFrame?.isMainFrame != false {
        host.text = PopupPolicy.hostLabel(url)
      }
      decisionHandler(.cancel)
      showMessage(PopupPolicy.googleMessage)
      return
    }
    guard PopupPolicy.allows(url, localURLs: localURLs),
      !navigationAction.shouldPerformDownload
    else {
      decisionHandler(.cancel)
      return
    }
    if mayPromote, navigationAction.targetFrame?.isMainFrame == true,
      (navigationAction.request.httpMethod ?? "GET") == "GET",
      let url, case .file = TabNavigationRouter.classify(url), let onPromote
    {
      onRouteEvidence?(.blankPromotion, url)
      browser = nil
      webView.removeFromSuperview()
      switch onPromote(url, webView) {
      case .adopted:
        close()
        #if DEBUG
          if offlinePromotion {
            decisionHandler(.cancel)
            return
          }
        #endif
        decisionHandler(.allow)
        return
      case .selectedExisting:
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        close()
        decisionHandler(.cancel)
        return
      case .declined: break
      }
      browser = webView
      loadViewIfNeeded()
      view.insertSubview(webView, belowSubview: notice)
      NSLayoutConstraint.activate([
        webView.topAnchor.constraint(equalTo: header.bottomAnchor),
        webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      ])
    }
    if navigationAction.targetFrame?.isMainFrame == true { host.text = PopupPolicy.hostLabel(url) }
    decisionHandler(.allow)
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    decisionHandler(
      webView === browser && message == nil && navigationResponse.canShowMIMEType
        ? .allow : .cancel)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    guard webView === browser, (error as NSError).code != NSURLErrorCancelled else { return }
    showMessage("This window could not load. Close it and try again.")
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
  }

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? { nil }
}
