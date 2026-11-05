import Foundation
import UIKit

@MainActor
final class TabSession: Identifiable {
  enum Kind { case home, document }
  let id: UUID
  let kind: Kind
  let session: SessionState
  var recovery = ProcessRecovery()
  let strategies: InputStrategies

  // Titles are sanitized before inclusion in the scene archive; snapshots stay memory-only.
  var displayTitle: String?
  var isPinned: Bool = false
  var lastUsed = Date()
  var discarded = false
  var snapshot: UIImage?
  var stoppedInBackground = false
  var backgroundRecoveryAllowed = false

  static func documentTitle(_ title: String?) -> String? {
    guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
    else { return nil }
    for suffix in [" – Figma", " — Figma", " - Figma", " | Figma"] where title.hasSuffix(suffix) {
      title.removeLast(suffix.count)
      break
    }
    title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty || title == "Figma" ? nil : title
  }

  var creatingFile = false
  var routingURL: URL?
  var lastDashboardURL: URL?  // Home only, memory only, never persisted or logged.
  var fileKey: String? {
    guard let url = routingURL, case .file(let key) = TabNavigationRouter.classify(url)
    else { return nil }
    return key
  }
  var recoveryURL: URL { session.lastURL }

  init(id: UUID = UUID(), kind: Kind, url: URL, defaults: UserDefaults = .standard) {
    self.id = id
    self.kind = kind
    isPinned = kind == .home
    routingURL = url
    creatingFile = TabNavigationRouter.classify(url) == .creation
    session = SessionState(tabURL: url, defaults: defaults)
    strategies = InputStrategies(defaults: defaults, isolated: true)
  }
}

/// Per-window membership, selection and sanitized restoration. Live views belong to the host.
@MainActor
final class WindowSession {
  static let restorationKey = "folio.lastSelectedRoute"
  static let schemaKey = "folio.tabs.schema"
  static let schemaVersion = 2

  static func migrate(_ defaults: UserDefaults) {
    guard defaults.integer(forKey: schemaKey) < schemaVersion else { return }
    let raw = defaults.string(forKey: restorationKey) ?? defaults.string(forKey: "folio.lastURL")
    var route = SessionState.startURL
    if let url = raw.flatMap(URL.init(string:)).flatMap(Privacy.recoveryURL),
      case .file = TabNavigationRouter.classify(url)
    {
      route = url
    }
    defaults.set(route.absoluteString, forKey: restorationKey)
    defaults.set(schemaVersion, forKey: schemaKey)
  }

  let id: UUID
  private(set) var tabs: [TabSession]
  private(set) var selectedID: UUID {
    didSet {
      guard selectedID != oldValue else { return }
      if tabs.contains(where: { $0.id == oldValue }) {
        previousSelectedID = oldValue
      } else if previousSelectedID == selectedID {
        previousSelectedID = nil
      }
    }
  }
  // Per-window and memory-only; reselecting the current tab does not change the toggle.
  private(set) var previousSelectedID: UUID?
  private let defaults: UserDefaults
  private let restoresSelection: Bool
  private let sceneID: String?
  private struct ClosedTab {
    let url: URL
    let index: Int
    let pinned: Bool
    let mode: BrowserMode
  }
  // Per-window, bounded and memory-only. Never retain a WebView or replay creation/auth URLs.
  private var closedTabs: [ClosedTab] = []
  var canReopenClosedTab: Bool { !closedTabs.isEmpty }
  var home: TabSession { tabs[0] }
  var selected: TabSession { tabs.first { $0.id == selectedID } ?? home }

  init(
    id: UUID = UUID(), defaults: UserDefaults = .standard, migrateLegacy: Bool = true,
    sceneID: String? = nil, restorationData: Data? = nil
  ) {
    self.sceneID = sceneID
    self.id = id
    self.defaults = defaults
    restoresSelection = migrateLegacy
    // The old seed can outlive route migration and a full scene archive. Clean it
    // on read even when that archive wins; tab writes never update this value.
    if migrateLegacy { _ = SessionState(defaults: defaults).lastURL }
    let home = TabSession(kind: .home, url: SessionState.startURL, defaults: defaults)
    tabs = [home]
    selectedID = home.id
    let preferences = FolioPreferences(defaults: defaults)
    let storedData = defaults.data(forKey: archiveKey)
    let archive = [storedData, restorationData].compactMap { data -> Archive? in
      guard let data, data.count <= 1_048_576,
        let archive = try? JSONDecoder().decode(Archive.self, from: data),
        (1...2).contains(archive.version)
      else { return nil }
      return archive
    }.first
    if preferences.restoreTabs, let archive {
      if let record = archive.tabs.first(where: { $0.id == archive.home }) {
        home.session.lastURL =
          URL(string: record.url).flatMap(Privacy.recoveryURL)
          ?? SessionState.startURL
      }
      for record in archive.tabs where record.id != archive.home {
        guard let url = URL(string: record.url).flatMap(Privacy.recoveryURL),
          case .file = TabNavigationRouter.classify(url),
          !tabs.contains(where: { $0.id == record.id })
        else { continue }
        let tab = TabSession(id: record.id, kind: .document, url: url, defaults: defaults)
        tab.isPinned = record.pinned
        tab.displayTitle = Self.savedTitle(record.title)
        if let mode = record.mode.flatMap(BrowserMode.init(rawValue:)) {
          tab.session.mode = mode
        }
        tabs.append(tab)
        observeNavigation(tab)
      }
      tabs =
        [home] + tabs.dropFirst().filter(\.isPinned)
        + tabs.dropFirst().filter { !$0.isPinned }
      observeNavigation(home)
      selectedID =
        preferences.startAtHome || archive.selected == archive.home
        ? home.id : tabs.first(where: { $0.id == archive.selected })?.id ?? home.id
      saveArchive()
      return
    }
    observeNavigation(home)
    // Migrate the old single-route checkpoint only when no full archive exists.
    // A present checkpoint wins over the legacy seed, including Home/corrupt values.
    if migrateLegacy && preferences.restoreTabs {
      Self.migrate(defaults)
      let safe: URL
      if defaults.object(forKey: Self.restorationKey) != nil {
        safe =
          defaults.string(forKey: Self.restorationKey)
          .flatMap(URL.init(string:)).flatMap(Privacy.recoveryURL) ?? SessionState.startURL
      } else {
        safe = SessionState(defaults: defaults).lastURL
      }
      // Never replay a creation request from an old recovery checkpoint.
      if case .file = TabNavigationRouter.classify(safe) {
        add(url: safe)
      }
      if preferences.startAtHome { selectedID = home.id }
      persistSelection()
    }
  }

  @discardableResult
  func add(url: URL, selecting: Bool = true) -> TabSession {
    let tab = TabSession(kind: .document, url: url, defaults: defaults)
    tabs.append(tab)
    observeNavigation(tab)
    if selecting { selectedID = tab.id }
    persistSelection()
    return tab
  }

  @discardableResult
  func openFile(url: URL, selecting: Bool = true) -> TabSession {
    switch TabNavigationRouter.classify(url) {
    case .file(let key):
      if let existing = tabs.first(where: { $0.kind == .document && $0.fileKey == key }) {
        if selecting { select(existing.id) }
        return existing
      }
      return add(url: url, selecting: selecting)
    case .creation:
      return add(url: url, selecting: selecting)
    default:
      select(home.id)
      return home
    }
  }

  /// A creation intent has no file key until WebKit reports a real editor route.
  /// Returns a duplicate to retire; never reloads the already open document.
  func resolveCreation(_ id: UUID, url: URL) -> UUID? {
    guard let tab = tabs.first(where: { $0.id == id }), tab.creatingFile,
      case .file(let key) = TabNavigationRouter.classify(url)
    else { return nil }
    tab.creatingFile = false
    tab.routingURL = url
    guard
      let existing = tabs.first(where: {
        $0.id != id && $0.kind == .document
          && $0.fileKey == key
      })
    else { return nil }
    let wasSelected = selectedID == id
    _ = close(id, remember: false)
    if wasSelected { select(existing.id) }
    return id
  }

  func select(_ id: UUID) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    selectedID = id
    persistSelection()
  }

  @discardableResult
  func close(_ id: UUID, remember: Bool = true) -> Bool {
    guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].kind != .home,
      !tabs[index].isPinned || !remember
    else { return false }
    let tab = tabs[index]
    if remember, !tab.creatingFile, let url = Privacy.recoveryURL(tab.recoveryURL),
      case .file = TabNavigationRouter.classify(url)
    {
      closedTabs.append(.init(url: url, index: index, pinned: tab.isPinned, mode: tab.session.mode))
      if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
    }
    tabs[index].session.onRecoveryURLChange = nil
    tabs.remove(at: index)
    if previousSelectedID == id { previousSelectedID = nil }
    if selectedID == id {
      selectedID = tabs[min(index, tabs.count - 1)].id
    }
    if tabs.count == 1 { selectedID = home.id }
    persistSelection()
    return true
  }

  @discardableResult
  func reopenClosedTab() -> TabSession? {
    guard let record = closedTabs.popLast() else { return nil }
    if case .file(let key) = TabNavigationRouter.classify(record.url),
      let existing = tabs.first(where: { $0.kind == .document && $0.fileKey == key })
    {
      select(existing.id)
      return existing
    }
    let tab = add(url: record.url)
    tab.isPinned = record.pinned
    tab.session.mode = record.mode
    let target = tabs.indices.contains(record.index) ? tabs[record.index].id : nil
    reorder(tab.id, before: target)
    return tab
  }

  func togglePin(_ id: UUID) {
    guard let tab = tabs.first(where: { $0.id == id }), tab.kind != .home else { return }
    tab.isPinned.toggle()
    tabs.removeAll { $0 === tab }
    let boundary = tabs.firstIndex { $0.kind != .home && !$0.isPinned } ?? tabs.count
    tabs.insert(tab, at: boundary)
    persistSelection()
  }

  @discardableResult
  func closeOthers(keeping id: UUID) -> [UUID] {
    guard tabs.contains(where: { $0.id == id }) else { return [] }
    let closed = tabs.filter { $0.kind != .home && !$0.isPinned && $0.id != id }.map(\.id)
    for id in closed { _ = close(id) }
    select(id)
    return closed
  }

  func reorder(_ id: UUID, before target: UUID?) {
    guard let index = tabs.firstIndex(where: { $0.id == id && $0.kind != .home }), id != target
    else { return }
    let tab = tabs.remove(at: index)
    let destination =
      target.flatMap { target in tabs.firstIndex(where: { $0.id == target }) } ?? tabs.count
    let boundary = tabs.firstIndex { $0.kind != .home && !$0.isPinned } ?? tabs.count
    let insertion = tab.isPinned ? min(max(1, destination), boundary) : max(boundary, destination)
    tabs.insert(tab, at: insertion)
    persistSelection()
  }

  private struct Archive: Codable {
    struct Record: Codable {
      let id: UUID
      let url: String
      let pinned: Bool
      let mode: String?
      let title: String?
    }
    let version: Int
    let selected: UUID
    let home: UUID?
    let tabs: [Record]
  }

  static func removeArchive(_ sceneID: String) {
    UserDefaults.standard.removeObject(forKey: "folio.scene." + sceneID)
  }

  private var archiveKey: String { "folio.scene." + (sceneID ?? "legacy") }

  private static func savedTitle(_ title: String?) -> String? {
    guard let title = TabSession.documentTitle(title) else { return nil }
    return String(Privacy.sanitize(title).prefix(256))
  }

  func restorationData() -> Data? {
    guard FolioPreferences(defaults: defaults).restoreTabs else { return nil }
    let records = tabs.filter { !$0.creatingFile }.compactMap {
      tab -> Archive.Record? in
      guard let url = Privacy.recoveryURL(tab.recoveryURL) else { return nil }
      if tab.kind != .home {
        guard case .file = TabNavigationRouter.classify(url) else { return nil }
      }
      return .init(
        id: tab.id, url: url.absoluteString, pinned: tab.isPinned, mode: nil,
        title: tab.kind == .home ? nil : Self.savedTitle(tab.displayTitle))
    }
    let archive = Archive(version: 2, selected: selectedID, home: home.id, tabs: records)
    return try? JSONEncoder().encode(archive)
  }

  func saveArchive() {
    if let data = restorationData() {
      defaults.set(data, forKey: archiveKey)
    } else {
      defaults.removeObject(forKey: archiveKey)
    }
  }

  private func observeNavigation(_ tab: TabSession) {
    tab.session.onRecoveryURLChange = { [weak self, weak tab] in
      guard let self, let tab,
        self.tabs.contains(where: { $0 === tab })
      else { return }
      self.persistSelection()
    }
  }

  private func persistSelection() {
    saveArchive()
    if sceneID != nil { return }
    guard restoresSelection, FolioPreferences(defaults: defaults).restoreTabs else { return }
    let route = selected.creatingFile ? SessionState.startURL : selected.recoveryURL
    let safe = Privacy.recoveryURL(route) ?? SessionState.startURL
    defaults.set(safe.absoluteString, forKey: Self.restorationKey)
  }
}
