import UIKit
import WebKit

@MainActor
extension FigmaWebViewController {
  static var authLabURL: URL? {
    #if DEBUG
      Bundle.main.url(forResource: "auth-lab", withExtension: "html", subdirectory: "AuthLab")
    #else
      nil
    #endif
  }

  var authLocalURLs: [URL] {
    guard showingAuthLab, let url = Self.authLabURL else { return [] }
    return [url, url.deletingLastPathComponent().appendingPathComponent("auth-child.html")]
  }

  func openPopup(
    configuration: WKWebViewConfiguration, url: URL?, documentOnly: Bool = false
  ) -> WKWebView? {
    guard isTabActive, popup == nil, presentedViewController == nil,
      PopupPolicy.allows(url, localURLs: authLocalURLs)
    else { return nil }
    keyboardFocus.invalidate()
    #if DEBUG
      pinchHarness?.cancel(captureBrowser: false)
    #endif
    let child = PopupController(
      configuration: configuration, url: url, localURLs: authLocalURLs,
      documentOnly: documentOnly,
      signInRules: session.mode != .safe && diagnostics.strategies.hideGoogle
        ? SignInRules.list : nil)
    #if DEBUG
      child.offlinePromotion = fixtureNumber != nil
    #endif
    child.onRouteEvidence = { [weak self] event, url in
      self?.recordRouteEvidence(event, url: url)
    }
    child.onPromote = { [weak self, weak child] url, browser in
      guard let self, self.isTabActive, let child, self.popup === child else { return .declined }
      return self.onAdoptRelatedBrowser?(url, browser) ?? .declined
    }
    child.onClose = { [weak self] in
      self?.popup = nil
      if let self, let url = self.pendingHandoffURL {
        self.pendingHandoffURL = nil
        if self.webView.url == url { _ = self.handoffObservedURL(url) }
      }
      self?.webView.accessibilityElementsHidden = false
      self?.recordKeyboardProbe(phase: "popup-closed")
      if self?.closingPopupForLifecycle == false { self?.restoreBrowserFocus(reason: .popupClosed) }
    }
    child.onSignInFinished = { [weak self] in self?.reloadAfterSignIn() }
    child.onOwnershipTransition = { [weak self] in self?.recordKeyboardProbe(phase: "popup-message")
    }
    popup = child
    // Esc closes the sign-in popup like its Close button.
    FolioEscape.register(child) { [weak child] in child?.close() }
    webView.accessibilityElementsHidden = true
    // A sheet over the tab, like the system's sign-in sheets: centred on iPad, from the bottom
    // on iPhone.
    let regular = traitCollection.horizontalSizeClass == .regular
    child.modalPresentationStyle = regular ? .formSheet : .pageSheet
    if regular { child.preferredContentSize = CGSize(width: 600, height: 780) }
    child.sheetPresentationController?.prefersGrabberVisible = !regular
    child.presentationController?.delegate = child
    present(child, animated: true) { [weak child] in child?.browser?.becomeFirstResponder() }
    recordKeyboardProbe(phase: "popup-opened")
    // WebKit, not Folio, loads the initial request in this returned related web view.
    if PopupPolicy.isGoogleOAuth(url) { child.showMessage(PopupPolicy.googleMessage) }
    return child.browser
  }

  /// A sign-in in the sheet (Add account) finished: the opener's Figma file browser still lists
  /// the old accounts, so reload it (maintainer, 2026-11-11). Files are never reloaded.
  func reloadAfterSignIn() {
    guard let browser = webView, let url = browser.url,
      case .dashboard = TabNavigationRouter.classify(url)
    else { return }
    browser.reload()
  }

  func closePopup() {
    closingPopupForLifecycle = true
    popup?.close(animated: false)
    closingPopupForLifecycle = false
  }

  func webView(
    _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
  ) {
    guard webView === self.webView else {
      download.cancel { _ in }
      return
    }
    downloads.accept(download)
  }
  func webView(
    _ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload
  ) {
    guard webView === self.webView else {
      download.cancel { _ in }
      return
    }
    downloads.accept(download)
  }

  static var nativeLabURL: URL? {
    #if DEBUG
      Bundle.main.url(forResource: "native-lab", withExtension: "html", subdirectory: "NativeLab")
    #else
      nil
    #endif
  }

  func recordExternalLinkDelivery(_ url: URL) {
    diagnostics.lifecycle("External link: \(Privacy.redactedURL(url))")
  }

  func openExternalLink(_ url: URL) {
    guard let url = FolioLink.validated(url) else { return }
    session.lastURL = url
    recordExternalLinkDelivery(url)
    // A cold link is persisted before the view loads. The full URL stays in memory only.
    guard isViewLoaded, webView != nil else {
      pendingExternalURL = url
      return
    }
    interruptMemoryRun()
    showingNativeLab = false
    showingAuthLab = false
    showingLab = false
    showingMemoryLab = false
    showingFocusLab = false
    diagnostics.activeLab = nil
    closePopup()
    webView.load(URLRequest(url: url))
  }
}

/// Browser-standard anchor routing. No page functions/history/prototypes are changed.
/// Weak ownership avoids retaining a closed controller through its script controller.
@MainActor
final class StandardFileLinkHandler: NSObject, WKScriptMessageHandler {
  static let name = "folioStandardFileLink"
  private weak var owner: FigmaWebViewController?
  init(owner: FigmaWebViewController) { self.owner = owner }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.name == Self.name, let raw = message.body as? String, raw.utf8.count <= 8192,
      let url = URL(string: raw), let browser = message.webView
    else { return }
    owner?.routeStandardFileLink(url, from: browser, mainFrame: message.frameInfo.isMainFrame)
  }

  static let script = #"""
    (() => {
      const fileKey = url => {
        if (url.protocol !== 'https:' || !['figma.com','www.figma.com'].includes(url.hostname)
            || url.username || url.password || (url.port && url.port !== '443')
            || url.pathname.toLowerCase().includes('%2f')) return null;
        const match = /^\/(design|file|board|proto|slides|site|make)\/([A-Za-z0-9_-]{1,128})(?:\/|$)/.exec(url.pathname);
        return match?.[2] ?? null;
      };
      const dashboard = url => {
        if (url.protocol !== 'https:' || !['figma.com','www.figma.com'].includes(url.hostname)
            || url.username || url.password || (url.port && url.port !== '443')) return false;
        return /^\/(?:files|projects|project|settings|search|teams|team)(?:\/|$)/.test(url.pathname)
          || url.pathname === '/';
      };
      // Document-start can precede the final document URL. Validate the source at click time.
      window.addEventListener('click', event => {
        if (!event.isTrusted || event.defaultPrevented || event.button !== 0
            || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
        const source = new URL(location.href);
        if (!fileKey(source) && !dashboard(source)) return;
        const anchor = event.composedPath().find(node => node instanceof HTMLAnchorElement);
        if (!anchor || anchor.hasAttribute('download') || (anchor.target && anchor.target !== '_self')) return;
        let destination; try { destination = new URL(anchor.href); } catch { return; }
        const key = fileKey(destination);
        if (!key || key === fileKey(source) || new TextEncoder().encode(destination.href).length > 8192) return;
        // Own this standard link once, before an SPA handler can consume the same click.
        event.preventDefault(); event.stopImmediatePropagation();
        window.webkit.messageHandlers.folioStandardFileLink.postMessage(destination.href);
      }, true);
    })();
    """#
}
