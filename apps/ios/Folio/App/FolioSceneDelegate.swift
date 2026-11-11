import UIKit
import WebKit

/// A local capability, never a file title, URL, cookie or document payload.
@MainActor
final class TabTransfer {
  let token = UUID()
  let tabID: UUID
  weak var source: BrowserWindowController?
  var accepted = false

  init(tabID: UUID, source: BrowserWindowController) {
    self.tabID = tabID
    self.source = source
  }

  var activity: NSUserActivity {
    let activity = NSUserActivity(activityType: FolioWindows.activityType)
    activity.title = "Open Folio tab"
    activity.userInfo = ["transfer": token.uuidString]
    activity.isEligibleForHandoff = false
    activity.isEligibleForSearch = false
    activity.isEligibleForPublicIndexing = false
    return activity
  }
}

@MainActor
enum FolioWindows {
  static let activityType = "app.foliodesign.folio.tab"
  static let store = WKWebsiteDataStore.default()
  static let zoom =
    DebugLabConfiguration.offline && !DebugLabConfiguration.usesExistingZoomFixture
    ? InterfaceZoomStore(defaults: DebugLabConfiguration.defaults) : InterfaceZoomStore.appStore()
  static var transfers: [UUID: TabTransfer] = [:]

  static func begin(_ id: UUID, source: BrowserWindowController) -> TabTransfer? {
    guard let tab = source.session.tabs.first(where: { $0.id == id }), tab.kind != .home,
      !tab.creatingFile, case .file = TabNavigationRouter.classify(tab.recoveryURL)
    else { return nil }
    let transfer = TabTransfer(tabID: id, source: source)
    transfers[transfer.token] = transfer
    return transfer
  }

  static func accept(
    _ transfer: TabTransfer, into destination: BrowserWindowController, before: UUID? = nil
  ) -> Bool {
    guard transfers[transfer.token] === transfer, !transfer.accepted,
      let source = transfer.source,
      let tab = source.session.tabs.first(where: { $0.id == transfer.tabID }), tab.kind != .home
    else { return false }
    if source === destination {
      destination.session.reorder(tab.id, before: before)
      destination.showSelectedTab()
    } else {
      // Controllers capture their window's routing, export and memory owners. Reopen
      // rather than attach one with stale ownership; source closes only after admission.
      let admitted = destination.session.add(url: tab.routingURL ?? tab.recoveryURL)
      admitted.displayTitle = tab.displayTitle
      admitted.isPinned = tab.isPinned
      admitted.session.mode = tab.session.mode
      destination.session.reorder(admitted.id, before: before)
      destination.showSelectedTab(ownerSelection: true)
      destination.session.saveArchive()
      source.closeTab(tab.id, remember: false)
    }
    transfer.accepted = true
    transfers.removeValue(forKey: transfer.token)
    return true
  }

  static func accept(_ activity: NSUserActivity, into destination: BrowserWindowController) -> Bool
  {
    guard activity.activityType == activityType,
      let raw = activity.userInfo?["transfer"] as? String, let token = UUID(uuidString: raw),
      let transfer = transfers[token]
    else { return false }
    return accept(transfer, into: destination)
  }

  static func newWindow(from scene: UIWindowScene?, transfer: TabTransfer? = nil) {
    // Regular iPhones have one window; window commands are hidden there.
    guard UIApplication.shared.supportsMultipleScenes else { return }
    let options = UIScene.ActivationRequestOptions()
    options.requestingScene = scene
    UIApplication.shared.requestSceneSessionActivation(
      nil, userActivity: transfer?.activity, options: options
    ) { _ in
      // A rejected request never removes source membership.
    }
  }
}

@MainActor
final class FolioSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var container: InterfaceZoomContainerController?

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions
  ) {
    guard let scene = scene as? UIWindowScene else { return }
    let defaults = DebugLabConfiguration.defaults
    // Existing scene archives disable route migration, but the obsolete seed
    // must still be sanitized. Offline fixtures never touch the owner's defaults.
    if !DebugLabConfiguration.offline { _ = SessionState(defaults: defaults).lastURL }
    let migrate =
      !defaults.bool(forKey: "folio.sceneMigrationComplete") && !DebugLabConfiguration.offline
    let tabs = WindowSession(
      defaults: defaults, migrateLegacy: migrate, sceneID: session.persistentIdentifier,
      restorationData: DebugLabConfiguration.sceneRestorationData(
        session.stateRestorationActivity?.userInfo?["tabs"] as? Data))
    defaults.set(true, forKey: "folio.sceneMigrationComplete")
    // iPhone: each scene owns its zoom so folding or unfolding one window rescales only it.
    let zoom =
      PhoneExperiencePolicy.isPhone
      ? InterfaceZoomStore(defaults: FolioWindows.zoom.defaults) : FolioWindows.zoom
    let container = InterfaceZoomContainerController(store: zoom) { factory in
      BrowserWindowController(
        session: tabs, websiteDataStore: FolioWindows.store, makeWebView: factory)
    }
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--interface-zoom-lab") {
        self.container = InterfaceZoomFixture.makeContainer(store: FolioWindows.zoom)
      } else {
        self.container = container
      }
    #else
      self.container = container
    #endif
    let window = FolioWindow(windowScene: scene)
    window.rootViewController = self.container
    self.window = window
    for activity in options.userActivities { receive(activity) }
    for context in options.urlContexts { open(context.url) }
    window.makeKeyAndVisible()
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) { receive(userActivity) }
  func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    for context in contexts { open(context.url) }
  }
  func sceneDidBecomeActive(_ scene: UIScene) {
    LocalFontService.shared.setActive(scene.session.persistentIdentifier, true)
    guard DebugLabConfiguration.acceptsScheme, let url = DebugLabConfiguration.inbox?.take() else {
      return
    }
    container?.deliver(url, id: UUID())
  }
  func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
    guard !DebugLabConfiguration.offline else { return nil }
    container?.browser.session.saveArchive()
    let activity = NSUserActivity(activityType: "app.foliodesign.folio.window")
    if let data = container?.browser.session.restorationData() {
      activity.userInfo = ["tabs": data]
    }
    activity.isEligibleForHandoff = false
    activity.isEligibleForSearch = false
    activity.isEligibleForPublicIndexing = false
    return activity
  }

  func sceneWillResignActive(_ scene: UIScene) {
    LocalFontService.shared.setActive(scene.session.persistentIdentifier, false)
  }

  func sceneDidEnterBackground(_ scene: UIScene) { container?.browser.session.saveArchive() }
  func sceneDidDisconnect(_ scene: UIScene) {
    LocalFontService.shared.setActive(scene.session.persistentIdentifier, false)
    container?.browser.session.saveArchive()
    // Disconnect may be temporary. Only didDiscardSceneSessions removes the archive.
    container = nil
    window = nil
  }
  private func open(_ url: URL) {
    guard DebugLabConfiguration.acceptsScheme, let destination = FolioLink.decode(url) else {
      return
    }
    _ = DebugLabConfiguration.inbox?.take()
    container?.deliver(destination, id: UUID())
  }
  private func receive(_ activity: NSUserActivity) {
    guard activity.activityType == FolioWindows.activityType, let browser = container?.browser
    else { return }
    if !FolioWindows.accept(activity, into: browser) {
      browser.selectHome()
      let alert = UIAlertController(
        title: "Tab is still in its original window",
        message: "Open the original Folio window and drag the tab again.", preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      DispatchQueue.main.async { [weak browser] in browser?.present(alert, animated: true) }
    }
  }
}
