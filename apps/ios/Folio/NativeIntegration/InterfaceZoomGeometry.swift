import UIKit
import WebKit

/// Public native geometry only. Used by first-party integration fixtures, never page inspection.
@MainActor
enum InterfaceZoomGeometry {
  static func describe(_ webView: WKWebView, in container: UIView) -> String {
    let scroll = webView.scrollView
    let parent = webView.superview
    let available = parent.map { $0.safeAreaLayoutGuide.layoutFrame } ?? .zero
    return """
      pageZoom=\(webView.pageZoom)
      frame=\(webView.frame) bounds=\(webView.bounds) transform=\(webView.transform)
      inContainer=\(webView.convert(webView.bounds, to: container))
      parentBounds=\(String(describing: parent?.bounds)) parentSafeArea=\(available)
      safeInsets=\(webView.safeAreaInsets) containerSafeInsets=\(container.safeAreaInsets)
      keyboard=\(container.keyboardLayoutGuide.layoutFrame)
      scrollBounds=\(scroll.bounds) contentSize=\(scroll.contentSize) offset=\(scroll.contentOffset)
      contentInset=\(scroll.contentInset) adjustedInset=\(scroll.adjustedContentInset)
      adjustmentBehavior=\(scroll.contentInsetAdjustmentBehavior.rawValue) scrollZoom=\(scroll.zoomScale)
      """
  }
}
