import UIKit
import WebKit

/// Tier 1: resize the actual layout viewport before scaling its presentation.
/// No page styles, viewport metadata, scripts or WebKit internals are changed.
@MainActor
final class InterfaceZoomViewport: UIView {
  private let browser: WKWebView
  private var observers: [NSObjectProtocol] = []
  private var refreshTask: Task<Void, Never>?
  private var loadRefreshTask: Task<Void, Never>?
  private var hadSize = false
  private var lastSize = CGSize.zero
  private let loadingIndicator = UIActivityIndicatorView(style: .medium)
  private var loadingTask: Task<Void, Never>?
  private var loading = false
  /// iPhone "Canvas beside panels": extra layout width (CSS px) left and right of the visible
  /// region. The web view grows by both and shifts left, so its left part lies off-screen and
  /// clipped; hit testing stays correct because the geometry is real.
  private(set) var overscan: (left: CGFloat, right: CGFloat) = (0, 0)

  /// Snapshot covering an animated overscan change.
  private var transition: UIView?

  /// Active phone layouts use actual bounds changes without artificial refresh resizes.
  var preservesPhoneGeometry = false

  init(browser: WKWebView) {
    self.browser = browser
    super.init(frame: .zero)
    clipsToBounds = true
    // Any gap WebKit leaves under the page shows the chrome color, never white.
    backgroundColor = ChromePalette.bar
    browser.isOpaque = false
    updateLoadingColors()
    // The viewport already fills the window edge to edge. Automatic adjustment would
    // turn the home-indicator safe area and keyboard bars into WebKit obscured insets,
    // which shrink the page's visible area and leave a strip below it.
    browser.scrollView.contentInsetAdjustmentBehavior = .never
    browser.translatesAutoresizingMaskIntoConstraints = true
    browser.autoresizingMask = []
    addSubview(browser)
    loadingIndicator.isUserInteractionEnabled = false
    loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
    addSubview(loadingIndicator)
    NSLayoutConstraint.activate([
      loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
      loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
      (view: InterfaceZoomViewport, _: UITraitCollection) in view.updateLoadingColors()
    }
    let center = NotificationCenter.default
    for name in [
      UIResponder.keyboardDidHideNotification, UIResponder.keyboardDidChangeFrameNotification,
      UIScene.didActivateNotification, UIScene.willEnterForegroundNotification,
    ] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
    }
    registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) {
      (view: InterfaceZoomViewport, _: UITraitCollection) in view.scheduleRefresh()
    }
  }

  required init?(coder: NSCoder) { fatalError("Use injected browser") }

  isolated deinit {
    refreshTask?.cancel()
    loadRefreshTask?.cancel()
    loadingTask?.cancel()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  private func updateLoadingColors() {
    let background = ChromePalette.bar.resolvedColor(with: traitCollection)
    backgroundColor = background
    browser.backgroundColor = background
    browser.scrollView.backgroundColor = background
    browser.underPageBackgroundColor = background
    loadingIndicator.color = ChromePalette.secondaryText.resolvedColor(with: traitCollection)
  }

  func beginLoading() {
    loading = true
    loadingTask?.cancel()
    loadingIndicator.layer.removeAllAnimations()
    loadingIndicator.stopAnimating()
    loadingIndicator.alpha = 0
    loadingTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled, let self, self.loading else { return }
      self.loadingIndicator.alpha = 1
      self.loadingIndicator.startAnimating()
    }
  }

  func finishLoading() {
    loading = false
    loadingTask?.cancel()
    loadingTask = nil
    guard loadingIndicator.isAnimating else { return }
    UIView.animate(withDuration: 0.2) {
      self.loadingIndicator.alpha = 0
    } completion: { [weak self] _ in
      guard let self, !self.loading else { return }
      self.loadingIndicator.stopAnimating()
    }
  }

  /// `animated`: iPhone landscape side panels. The frame changes once (one WebKit resize, no
  /// per-frame resizing); a still snapshot of the old picture covers Figma's re-layout and the
  /// page's one compensating canvas pan (phone-layout.ts), then dissolves, so the canvas stays
  /// in place and the panel fades in on either side.
  func setOverscan(left: CGFloat, right: CGFloat, animated: Bool = false) {
    let left = max(0, left.rounded())
    let right = max(0, right.rounded())
    guard overscan.left != left || overscan.right != right else { return }
    if animated, window != nil, bounds.width > 0,
      let snapshot = snapshotView(afterScreenUpdates: false)
    {
      transition?.removeFromSuperview()
      snapshot.frame = bounds
      snapshot.isUserInteractionEnabled = false
      insertSubview(snapshot, aboveSubview: browser)
      transition = snapshot
      // Opaque while WebKit and Figma lay out the new width and pan back, then dissolve.
      UIView.animate(
        withDuration: 0.15, delay: 0.15, options: [.curveEaseOut, .allowUserInteraction]
      ) {
        snapshot.alpha = 0
      } completion: { [weak self, weak snapshot] _ in
        snapshot?.removeFromSuperview()
        if let self, self.transition === snapshot { self.transition = nil }
      }
    }
    overscan = (left, right)
    setNeedsLayout()
  }

  /// Layout size in CSS px and on-screen center for the current zoom scale and overscan.
  private func browserGeometry(scale: CGFloat) -> (size: CGSize, center: CGPoint) {
    let size = CGSize(
      width: bounds.width / scale + overscan.left + overscan.right,
      height: bounds.height / scale)
    let center = CGPoint(
      x: bounds.midX + (overscan.right - overscan.left) * scale / 2, y: bounds.midY)
    return (size, center)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let scale = browser.transform.a
    guard scale > 0, bounds.width > 0, bounds.height > 0 else { return }
    let (size, center) = browserGeometry(scale: scale)
    // Set bounds and center rather than frame, which is undefined under a transform.
    // WebKit sees this new layout size and delivers its normal DOM resize event.
    if browser.bounds.size != size { browser.bounds.size = size }
    browser.center = center
    if !hadSize {
      // First real size after a zero-frame creation: WebKit may have fixed its
      // viewport before this. Re-send once the view is settled in its window.
      hadSize = true
      scheduleRefresh()
    } else if bounds.size != lastSize {
      // Rotation keeps the regular size classes on iPad, so no trait change fires. WebKit's
      // animated resize can leave the page with the old visible height; re-send once the
      // new size has settled.
      scheduleRefresh()
    }
    lastSize = bounds.size
  }

  /// A file opening in a new tab or a navigation can leave WebKit with the visible size
  /// it measured mid-load. Re-send the final size shortly after, and once more after the
  /// page has had time to build its UI. The resulting DOM `resize` is WebKit's own.
  func refreshAfterLoad() {
    scheduleRefresh()
    loadRefreshTask?.cancel()
    loadRefreshTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1500))
      guard !Task.isCancelled else { return }
      self?.refreshWebKitGeometry()
    }
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    scheduleRefresh()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      updateLoadingColors()
      scheduleRefresh()
    }
  }

  /// Coalesce bursts of safe-area, keyboard, trait and scene changes into one refresh.
  private func scheduleRefresh() {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      self?.refreshWebKitGeometry()
    }
  }

  /// WebKit can keep a stale visible-content height (home-indicator safe area or a
  /// hardware-keyboard bar) while the native size is unchanged, so `layoutSubviews`
  /// sends nothing. A one-point bounds change and back makes WebKit recompute, the same
  /// path that a window resize or interface-zoom change takes.
  private func refreshWebKitGeometry() {
    guard window != nil else { return }
    setNeedsLayout()
    layoutIfNeeded()
    // Phone popovers close on resize. Actual layout changes already reach WebKit;
    // never add the artificial one-point refresh while phone presentation is active.
    guard !preservesPhoneGeometry else { return }
    let size = browser.bounds.size
    guard size.width > 1, size.height > 1 else { return }
    browser.bounds.size = CGSize(width: size.width, height: size.height - 1)
    browser.bounds.size = size
    let scale = browser.transform.a
    if scale > 0 { browser.center = browserGeometry(scale: scale).center }
  }
}
