import Combine
import UIKit
import WebKit

@MainActor
final class InterfaceZoomContainerController: UIViewController {
  typealias MainViewFactory = (WKWebViewConfiguration) -> WKWebView
  let browser: BrowserWindowController
  let store: InterfaceZoomStore
  private var observation: AnyCancellable?
  private var deliveredLinkID: UUID?
  init(
    store: InterfaceZoomStore,
    makeBrowser: (@escaping MainViewFactory) -> BrowserWindowController = { factory in
      BrowserWindowController(makeWebView: factory)
    }
  ) {
    self.store = store
    browser = makeBrowser { configuration in store.makeMainWebView(configuration: configuration) }
    super.init(nibName: nil, bundle: nil)
    browser.onCompactLayout = { [weak store] compact in store?.setCompact(compact) }
    browser.onInterfaceZoom = { [weak store] action in store?.send(action) }
    browser.onAdoptMainWebView = { [weak store] view in store?.registerMainWebView(view) }
  }

  required init?(coder: NSCoder) { fatalError("Use injected interface zoom store") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = ChromePalette.bar
    addChild(browser)
    browser.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(browser.view)
    NSLayoutConstraint.activate([
      browser.view.topAnchor.constraint(equalTo: view.topAnchor),
      browser.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      browser.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      browser.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    browser.didMove(toParent: self)
    // Interface zoom lives in the browser's ⋯ menu.
    observation = store.$state.sink { [weak browser] state in browser?.setInterfaceZoom(state) }
  }

  /// Called for both cold and warm delivery. Seed the host before loading the container view.
  func deliver(_ url: URL, id: UUID) {
    guard deliveredLinkID != id else { return }
    deliveredLinkID = id
    browser.openExternalLink(url)
  }
}
