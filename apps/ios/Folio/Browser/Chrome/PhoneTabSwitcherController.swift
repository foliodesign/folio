import UIKit

/// iPhone (Alpha) tab list: Home, pinned and ordinary tabs as rows instead of a squeezed strip.
/// Reads the shared chrome state and forwards every action to the window controller.
@MainActor
final class PhoneTabSwitcherController: UITableViewController {
  var state: () -> B3BrowserChromeState
  var onSelect: ((UUID) -> Void)?
  var onClose: ((UUID) -> Void)?
  var onPin: ((UUID) -> Void)?
  var onCopy: ((UUID) -> Void)?
  var onReorder: ((UUID, UUID?) -> Void)?
  var onNewFile: (() -> Void)?
  var onReopen: (() -> Void)?
  var onOpenLink: (() -> Void)?

  private var snapshot: B3BrowserChromeState
  private var documents: [B3BrowserChromeState.Tab] { snapshot.tabs.filter { !$0.home } }

  init(state: @escaping () -> B3BrowserChromeState) {
    self.state = state
    snapshot = state()
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError("Use programmatic tab switcher") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Tabs"
    view.accessibilityIdentifier = "phone-tabs"
    tableView.backgroundColor = ChromePalette.bar
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "tab")
    tableView.dragInteractionEnabled = true
    tableView.dragDelegate = self
    tableView.dropDelegate = self
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    updateMenu()
  }

  private func updateMenu() {
    let menu = UIMenu(children: [
      UIAction(title: "Open Link…", image: UIImage(systemName: "link")) { [weak self] _ in
        self?.finish { self?.onOpenLink?() }
      },
      UIAction(
        title: "Reopen Closed Tab", image: UIImage(systemName: "arrow.uturn.backward"),
        attributes: snapshot.canReopenClosedTab ? [] : .disabled
      ) { [weak self] _ in self?.finish { self?.onReopen?() } },
    ])
    navigationItem.leftBarButtonItems = [
      UIBarButtonItem(
        title: "New Design file", image: UIImage(systemName: "plus"),
        primaryAction: UIAction { [weak self] _ in self?.finish { self?.onNewFile?() } }),
      UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu),
    ]
    navigationItem.leftBarButtonItems?.first?.accessibilityIdentifier = "phone-tabs-new"
  }

  /// Dismiss first so the action's tab and focus changes land on the browser, not the sheet.
  private func finish(_ action: @escaping () -> Void) {
    dismiss(animated: true, completion: action)
  }

  private func reload() {
    snapshot = state()
    updateMenu()
    tableView.reloadData()
  }

  private func tab(at indexPath: IndexPath) -> B3BrowserChromeState.Tab {
    indexPath.section == 0 ? snapshot.home : documents[indexPath.row]
  }

  override func numberOfSections(in tableView: UITableView) -> Int { 2 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? 1 : documents.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int)
    -> String?
  {
    section == 1 && !documents.isEmpty ? "Open files" : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell
  {
    let cell = tableView.dequeueReusableCell(withIdentifier: "tab", for: indexPath)
    let tab = tab(at: indexPath)
    let selected = tab.id == snapshot.selectedID
    var content = UIListContentConfiguration.subtitleCell()
    content.text = tab.home ? "Home" : tab.title ?? "Loading…"
    content.secondaryText =
      tab.home
      ? "Recents and files"
      : [tab.pinned ? "Pinned" : nil, tab.discarded ? "Reloads when opened" : nil]
        .compactMap { $0 }.joined(separator: " · ")
    content.textProperties.color = ChromePalette.primaryText
    content.textProperties.numberOfLines = 1
    content.secondaryTextProperties.color = ChromePalette.secondaryText
    content.image = tab.home ? UIImage(systemName: "house") : ChromeFileIcon.image(tab.symbol)
    content.imageProperties.tintColor = selected ? ChromePalette.activeIcon : ChromePalette.icon
    content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
    content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
    cell.contentConfiguration = content
    cell.contentView.alpha = tab.discarded ? 0.6 : 1
    cell.backgroundConfiguration = {
      var background = UIBackgroundConfiguration.listCell()
      background.backgroundColor = selected ? ChromePalette.selectedTab : ChromePalette.inactiveTab
      return background
    }()
    cell.accessoryType = selected ? .checkmark : .none
    cell.tintColor = ChromePalette.activeIcon
    cell.accessibilityIdentifier = "phone-tab-\(tab.home ? 0 : indexPath.row + 1)"
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let id = tab(at: indexPath).id
    finish { [weak self] in self?.onSelect?(id) }
  }

  override func tableView(
    _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    let tab = tab(at: indexPath)
    guard !tab.home, !tab.pinned else { return nil }
    let close = UIContextualAction(style: .destructive, title: "Close") {
      [weak self] _, _, done in
      self?.onClose?(tab.id)
      self?.reload()
      done(true)
    }
    close.image = UIImage(systemName: "xmark")
    return UISwipeActionsConfiguration(actions: [close])
  }

  override func tableView(
    _ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    let tab = tab(at: indexPath)
    guard !tab.home else { return nil }
    let pin = UIContextualAction(style: .normal, title: tab.pinned ? "Unpin" : "Pin") {
      [weak self] _, _, done in
      self?.onPin?(tab.id)
      self?.reload()
      done(true)
    }
    pin.image = UIImage(systemName: tab.pinned ? "pin.slash" : "pin")
    pin.backgroundColor = ChromePalette.activeIcon
    return UISwipeActionsConfiguration(actions: [pin])
  }

  override func tableView(
    _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    let tab = tab(at: indexPath)
    guard !tab.home else { return nil }
    return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
      UIMenu(children: [
        UIAction(
          title: tab.pinned ? "Unpin Tab" : "Pin Tab",
          image: UIImage(systemName: tab.pinned ? "pin.slash" : "pin")
        ) { _ in
          self?.onPin?(tab.id)
          self?.reload()
        },
        UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
          self?.onCopy?(tab.id)
        },
        UIAction(
          title: "Close Tab", image: UIImage(systemName: "xmark"),
          attributes: tab.pinned ? [.disabled] : [.destructive]
        ) { _ in
          self?.onClose?(tab.id)
          self?.reload()
        },
      ])
    })
  }
}

extension PhoneTabSwitcherController: UITableViewDragDelegate, UITableViewDropDelegate {
  func tableView(
    _ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath
  ) -> [UIDragItem] {
    guard indexPath.section == 1 else { return [] }
    // Local reordering only; the item carries no shareable data.
    let item = UIDragItem(itemProvider: NSItemProvider())
    item.localObject = documents[indexPath.row].id
    return [item]
  }

  func tableView(
    _ tableView: UITableView, dropSessionDidUpdate session: UIDropSession,
    withDestinationIndexPath destinationIndexPath: IndexPath?
  ) -> UITableViewDropProposal {
    guard session.localDragSession != nil, destinationIndexPath?.section == 1 else {
      return UITableViewDropProposal(operation: .forbidden)
    }
    return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
  }

  func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator)
  {}

  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    indexPath.section == 1
  }

  override func tableView(
    _ tableView: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath,
    toProposedIndexPath proposed: IndexPath
  ) -> IndexPath {
    proposed.section == 1 ? proposed : IndexPath(row: 0, section: 1)
  }

  override func tableView(
    _ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath
  ) {
    let rows = documents
    let moving = rows[source.row].id
    var rest = rows.map(\.id)
    rest.remove(at: source.row)
    let before = destination.row < rest.count ? rest[destination.row] : nil
    onReorder?(moving, before)
    // The session keeps pinned tabs ahead of the rest; show its actual order.
    DispatchQueue.main.async { [weak self] in self?.reload() }
  }
}
