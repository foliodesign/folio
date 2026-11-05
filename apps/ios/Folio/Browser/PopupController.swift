import UIKit
import WebKit

/// An opener-related child using WebKit's supplied configuration, with no Folio injection.
@MainActor
final class PopupController: UIViewController, WKNavigationDelegate, WKUIDelegate {
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
  private let host = UILabel()
  private let notice = UILabel()
  private let localURLs: [URL]
  private let documentOnly: Bool

  init(
    configuration: WKWebViewConfiguration, url: URL?, localURLs: [URL] = [],
    documentOnly: Bool = false
  ) {
    self.localURLs = localURLs
    self.documentOnly = documentOnly
    mayPromote = url?.absoluteString == "about:blank"
    super.init(nibName: nil, bundle: nil)
    // Do not remove handlers/scripts from the inherited controller: it may be the parent's.
    configuration.userContentController = WKUserContentController()
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
    host.accessibilityIdentifier = "popupHost"
    let close = UIButton(type: .system)
    close.setTitle("Close window", for: .normal)
    close.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
    let header = UIStackView(arrangedSubviews: [host, close])
    header.spacing = 16
    header.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(header)
    notice.numberOfLines = 0
    notice.font = .preferredFont(forTextStyle: .body)
    notice.accessibilityIdentifier = "popupNotice"
    notice.translatesAutoresizingMaskIntoConstraints = false
    notice.isHidden = true
    view.addSubview(notice)
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
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
        browser.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
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

  func close() {
    releaseBrowser()
    willMove(toParent: nil)
    viewIfLoaded?.removeFromSuperview()
    removeFromParent()
    let callback = onClose
    onClose = nil
    callback?()
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
        webView.topAnchor.constraint(equalTo: host.bottomAnchor, constant: 12),
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
