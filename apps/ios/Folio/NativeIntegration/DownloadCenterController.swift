import QuickLook
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

private final class DownloadCenterEmptyPreviewItem: NSObject, QLPreviewItem {
  var previewItemURL: URL? { nil }
}

/// Compact downloads panel anchored under the ⋯ button, styled like the editor's panels.
/// Present through DownloadHandler to serialize it with automatic export choices and other
/// tabs' native download UI.
@MainActor
final class DownloadCenterController: UIViewController, UITableViewDataSource,
  UITableViewDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate,
  QLPreviewControllerDataSource, @MainActor QLPreviewControllerDelegate
{
  enum Action { case open, share, files, photos }
  typealias Palette = DeveloperToolsController.Palette
  typealias Style = DeveloperToolsController
  static let width: CGFloat = 440
  /// Same size and placement as the Settings sheet (`FigmaWebViewController.showPreferences`).
  static let sheetSize = CGSize(width: 880, height: 720)
  static let rowHeight: CGFloat = 64
  static let headerHeight: CGFloat = 44

  let catalog: DownloadCenterCatalog
  var onClose: (() -> Void)?
  let photos: PhotosExportService
  let tableView = UITableView(frame: .zero, style: .plain)
  private lazy var clearButton = Style.smallButton("Clear finished") { [weak self] in
    self?.clearFinished()
  }
  private let countLabel = UILabel()
  /// Photos save outcome, shown above the list.
  let statusLabel = UILabel()
  private let emptyView = UIStackView()
  private var thumbnails: [UUID: UIImage] = [:]
  private var thumbnailRequests: Set<UUID> = []
  private var progressTimer: Timer?
  private var photoToken: UUID?
  private var photoProtection: (UUID, UUID)?
  private var photoStarting = false
  private var photoGeneration = UUID()
  var savingPhoto: Bool { photoStarting || photoToken != nil }
  private var rows: [DownloadCenterCatalog.Item] = []
  private var observation: UUID?
  private(set) var actionController: UIViewController?
  private(set) var actionItem: UUID?
  private var actionProtection: UUID?
  private var actionGeneration = UUID()
  private var actionURL: URL?
  private(set) var actionPreview: QLPreviewController?
  private var dismissalPoll: Task<Void, Never>?
  private var closing = false
  private var choicePoll: Task<Void, Never>?
  private var choiceGeneration = UUID()
  private var attaching = false
  private var attachment = B3DownloadsPresentation.Attachment()
  private var attachmentID = UUID()
  private var presentationAttempts = 0
  #if DEBUG
    var actionPresentationState: String {
      "requests=\(presentationAttempts) pending=\(attaching)"
        + " observed=\(attachment.observed) acknowledged=\(attachment.completed)"
    }
  #endif
  private var attachmentPoll: Task<Void, Never>?
  var presentController: (UIViewController, UIViewController, @escaping () -> Void) -> Void = {
    host, controller, completion in host.present(controller, animated: true, completion: completion)
  }

  init(catalog: DownloadCenterCatalog, photos: PhotosExportService = .shared) {
    self.catalog = catalog
    self.photos = photos
    super.init(nibName: nil, bundle: nil)
    title = "Downloads"
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Presents `controller` as a centred form sheet the size of Settings.
  static func presentAsSheet(_ controller: UIViewController) {
    controller.modalPresentationStyle = .formSheet
    controller.preferredContentSize = sheetSize
    controller.sheetPresentationController?.preferredCornerRadius = 12
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = Palette.panel
    view.tintColor = Palette.accent
    view.layer.cornerRadius = 12
    view.layer.borderWidth = 1
    view.layer.borderColor = Palette.border.cgColor

    let title = UILabel()
    title.text = "Downloads"
    title.font = Style.font(13, .semibold)
    title.textColor = Palette.text
    countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    countLabel.textColor = Palette.tertiary
    countLabel.accessibilityIdentifier = "folioDownloadsCount"

    clearButton.accessibilityIdentifier = "folioDownloadsClearFinished"

    let closeButton = Style.iconButton("xmark", label: "Close") { [weak self] in self?.close() }
    closeButton.accessibilityIdentifier = "folioDownloadsDone"

    let header = UIStackView(arrangedSubviews: [
      title, countLabel, UIView(), clearButton, closeButton,
    ])
    header.alignment = .center
    header.spacing = 8
    header.setCustomSpacing(6, after: title)
    header.setCustomSpacing(4, after: clearButton)
    header.isLayoutMarginsRelativeArrangement = true
    header.directionalLayoutMargins = .init(
      top: 0, leading: DownloadRowCell.inset, bottom: 0, trailing: 10)

    let divider = UIView()
    divider.backgroundColor = Palette.separator

    statusLabel.font = Style.font(11)
    statusLabel.textColor = Palette.secondary
    statusLabel.numberOfLines = 0
    statusLabel.isHidden = true
    statusLabel.accessibilityIdentifier = "folioPhotosStatus"

    tableView.accessibilityIdentifier = "folioDownloadList"
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    tableView.rowHeight = Self.rowHeight
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(DownloadRowCell.self, forCellReuseIdentifier: DownloadRowCell.reuse)
    tableView.contentInset = .init(top: 4, left: 0, bottom: 4, right: 0)

    buildEmptyState()

    let statusRow = UIStackView(arrangedSubviews: [statusLabel])
    statusRow.isLayoutMarginsRelativeArrangement = true
    statusRow.directionalLayoutMargins = .init(
      top: 0, leading: DownloadRowCell.inset, bottom: 0, trailing: DownloadRowCell.inset)
    let column = UIStackView(arrangedSubviews: [header, divider, statusRow, tableView])
    column.axis = .vertical
    column.setCustomSpacing(8, after: divider)
    column.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(column)
    emptyView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(emptyView)
    NSLayoutConstraint.activate([
      header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
      divider.heightAnchor.constraint(equalToConstant: 1),
      column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      column.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      emptyView.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
      emptyView.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
      emptyView.widthAnchor.constraint(equalToConstant: Self.width - 64),
    ])
    observation = catalog.observe { [weak self] in self?.refresh() }
    refresh()
  }
  isolated deinit {
    progressTimer?.invalidate()
    if let photoToken { photos.cancel(photoToken) }
    if let (id, token) = photoProtection { catalog.release(id, token: token) }
    attachmentPoll?.cancel()
    dismissalPoll?.cancel()
    choicePoll?.cancel()
    if let observation { catalog.removeObserver(observation) }
    if let actionItem, let actionProtection { catalog.release(actionItem, token: actionProtection) }
  }

  private func buildEmptyState() {
    let icon = UIImageView(
      image: UIImage(
        systemName: "arrow.down.to.line",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)))
    icon.tintColor = Palette.secondary
    icon.contentMode = .center
    icon.backgroundColor = Palette.well
    icon.layer.cornerRadius = 20
    icon.layer.borderWidth = 1
    icon.layer.borderColor = Palette.border.cgColor
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 40),
      icon.heightAnchor.constraint(equalToConstant: 40),
    ])
    let title = UILabel()
    title.text = "No exports yet"
    title.font = Style.font(12, .semibold)
    title.textColor = Palette.text
    let body = UILabel()
    body.text =
      "Export from the editor (File › Export, or Export in the right sidebar) and the files land here. Open them, share them, or save them to Files or Photos."
    body.font = Style.font(11)
    body.textColor = Palette.secondary
    let note = UILabel()
    note.text =
      "Folio keeps the latest 32 exports, up to 128 MB, on this \(UIDevice.current.model)."
    note.font = Style.font(11)
    note.textColor = Palette.tertiary
    for label in [body, note] {
      label.numberOfLines = 0
      label.textAlignment = .center
    }
    for view in [icon, title, body, note] { emptyView.addArrangedSubview(view) }
    emptyView.axis = .vertical
    emptyView.alignment = .center
    emptyView.spacing = 4
    emptyView.setCustomSpacing(12, after: icon)
    emptyView.setCustomSpacing(10, after: body)
    emptyView.isHidden = true
  }

  private func refresh() {
    rows = catalog.items.sorted { $0.created > $1.created }
    tableView.reloadData()
    emptyView.isHidden = !rows.isEmpty
    clearButton.isEnabled = rows.contains { isFinished($0) }
    clearButton.isHidden = rows.isEmpty
    countLabel.text = rows.isEmpty ? nil : rows.count == 1 ? "1 file" : "\(rows.count) files"
    for item in rows where item.status == .completed { loadThumbnail(item) }
    let transferring = rows.contains { $0.status == .transferring }
    if transferring, progressTimer == nil {
      progressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateProgress() }
      }
    } else if !transferring {
      progressTimer?.invalidate()
      progressTimer = nil
    }
  }

  private func updateProgress() {
    for case let cell as DownloadRowCell in tableView.visibleCells {
      guard let id = cell.itemID, let item = catalog.item(id), item.status == .transferring
      else { continue }
      cell.showProgress(catalog.fractionCompleted(id))
    }
  }

  private func isFinished(_ item: DownloadCenterCatalog.Item) -> Bool {
    item.status != .transferring && catalog.canDelete(item.id)
  }

  private func clearFinished() {
    for item in rows where isFinished(item) { catalog.delete(item.id) }
  }

  private func loadThumbnail(_ item: DownloadCenterCatalog.Item) {
    guard thumbnails[item.id] == nil, !thumbnailRequests.contains(item.id),
      let url = catalog.completedURL(id: item.id)
    else { return }
    thumbnailRequests.insert(item.id)
    let id = item.id
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: CGSize(width: DownloadRowCell.tileSize, height: DownloadRowCell.tileSize),
      scale: view.window?.screen.scale ?? 2, representationTypes: .thumbnail)
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
      [weak self] representation, _ in
      let image = representation?.uiImage
      Task { @MainActor in
        guard let self, let image else { return }
        self.thumbnails[id] = image
        for case let cell as DownloadRowCell in self.tableView.visibleCells
        where cell.itemID == id {
          cell.setThumbnail(image)
        }
      }
    }
  }

  // MARK: Rows

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    rows.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell
  {
    let item = rows[indexPath.row]
    let cell =
      tableView.dequeueReusableCell(withIdentifier: DownloadRowCell.reuse, for: indexPath)
      as? DownloadRowCell ?? DownloadRowCell()
    cell.accessibilityIdentifier = "download-" + item.id.uuidString
    cell.configure(
      item: item, source: catalog.source(item.id)?.title,
      progress: catalog.fractionCompleted(item.id), thumbnail: thumbnails[item.id],
      buttons: buttons(for: item))
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let item = rows[indexPath.row]
    if item.status == .completed { perform(.open, id: item.id) }
  }

  func tableView(
    _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    let id = rows[indexPath.row].id
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      self?.menu(id: id)
    }
  }

  /// Completed rows keep a slot for Save to Photos so Open and the icons line up across rows.
  private func buttons(for item: DownloadCenterCatalog.Item) -> [UIView] {
    let id = item.id
    switch item.status {
    case .transferring:
      return [
        Style.iconButton("xmark.circle", label: "Cancel download") { [weak self] in
          self?.catalog.cancel(id)
        }
      ]
    case .completed:
      let photos: UIView
      if let url = catalog.completedURL(id: id), PhotosExportService.supports(url) {
        photos = Style.iconButton("photo.badge.arrow.down", label: "Save to Photos") {
          [weak self] in self?.perform(.photos, id: id)
        }
      } else {
        photos = UIView()
        photos.widthAnchor.constraint(equalToConstant: 28).isActive = true
      }
      return [
        Style.smallButton("Open", primary: true) { [weak self] in self?.perform(.open, id: id) },
        photos,
        Style.iconButton("square.and.arrow.up", label: "Share") { [weak self] in
          self?.perform(.share, id: id)
        },
        Style.iconButton("folder", label: "Save to Files") { [weak self] in
          self?.perform(.files, id: id)
        },
        moreButton(id: id),
      ]
    case .failed, .cancelled:
      return [moreButton(id: id)]
    }
  }

  private func moreButton(id: UUID) -> UIButton {
    let button = Style.iconButton("ellipsis", label: "More") {}
    button.menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { [weak self] completion in
        completion(self?.secondaryActions(id: id) ?? [])
      }
    ])
    button.showsMenuAsPrimaryAction = true
    return button
  }

  private func secondaryActions(id: UUID) -> [UIMenuElement] {
    var actions: [UIMenuElement] = []
    if let source = catalog.source(id) {
      actions.append(
        UIAction(title: "Show source tab", image: UIImage(systemName: "macwindow")) {
          [weak self] _ in
          self?.close()
          BrowserWindowController.showTab(source.tabID)
        })
    }
    actions.append(
      UIAction(
        title: "Delete", image: UIImage(systemName: "trash"),
        attributes: catalog.canDelete(id) ? [.destructive] : [.destructive, .disabled]
      ) { [weak self] _ in
        self?.catalog.delete(id)
      })
    return actions
  }

  private func menu(id: UUID) -> UIMenu {
    guard let item = catalog.item(id) else { return UIMenu(children: []) }
    if item.status == .transferring {
      return UIMenu(children: [
        UIAction(title: "Cancel download", attributes: .destructive) { [weak self] _ in
          self?.catalog.cancel(id)
        }
      ])
    }
    var actions: [UIMenuElement] = []
    if item.status == .completed {
      for (title, action) in availableActions(id: id) {
        actions.append(UIAction(title: title) { [weak self] _ in self?.perform(action, id: id) })
      }
    }
    return UIMenu(children: actions + secondaryActions(id: id))
  }

  private func availableActions(id: UUID) -> [(String, Action)] {
    var actions: [(String, Action)] = [
      ("Open", .open), ("Share", .share), ("Save to Files", .files),
    ]
    if let url = catalog.completedURL(id: id), PhotosExportService.supports(url) {
      actions.append(("Save to Photos", .photos))
    }
    return actions
  }

  // MARK: Photos

  private func showPhotoStatus(_ message: String) {
    statusLabel.text = message
    statusLabel.isHidden = false
    UIAccessibility.post(notification: .announcement, argument: message)
  }

  private func savePhoto(id: UUID) {
    guard !savingPhoto else { return }
    let generation = UUID()
    photoGeneration = generation
    let protection = catalog.protect(id, presentation: true)
    releasePhotoProtection()
    photoProtection = (id, protection)
    photoStarting = true
    defer { photoStarting = false }
    showPhotoStatus("Saving to Photos…")
    // Dependencies may complete synchronously in local tests.
    var completed = false
    let token = photos.save(id: id, catalog: catalog) { [weak self] outcome in
      completed = true
      guard let self, !self.closing, self.photoGeneration == generation else { return }
      self.photoToken = nil
      if outcome == .saved { self.releasePhotoProtection() }
      self.showPhotoStatus(outcome.message)
    }
    if !completed {
      photoToken = token
      if token == nil {
        showPhotoStatus("A save could not be started. Try again, or use Files or Share.")
      }
    }
  }

  private func releasePhotoProtection() {
    let protection = photoProtection
    photoProtection = nil
    if let (id, token) = protection { catalog.release(id, token: token) }
  }

  private func cancelPhoto() {
    photoGeneration = UUID()
    if let photoToken { photos.cancel(photoToken) }
    photoToken = nil
    releasePhotoProtection()
  }

  // UIKit can forward a list controller's modal to its navigation ancestor.
  // Present from that ancestor only after its action menu and transition detach.
  private var actionPresentationHost: UIViewController? {
    guard !attaching else { return nil }
    return B3DownloadsPresentation.host(for: self)
  }

  private func deferAction(_ action: Action, id: UUID) {
    guard choicePoll == nil else { return }
    let generation = UUID()
    choiceGeneration = generation
    choicePoll = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, !self.closing, self.choiceGeneration == generation else { return }
        guard self.catalog.completedURL(id: id) != nil else {
          self.choicePoll = nil
          return
        }
        if self.actionPresentationHost != nil {
          self.choicePoll = nil
          self.perform(action, id: id)
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  func perform(_ action: Action, id: UUID) {
    guard !closing, !savingPhoto, actionController == nil,
      let url = catalog.completedURL(id: id)
    else { return }
    guard let host = actionPresentationHost else {
      deferAction(action, id: id)
      return
    }
    if action == .photos {
      savePhoto(id: id)
      return
    }
    actionItem = id
    actionURL = url
    actionProtection = catalog.protect(id, presentation: true)
    releasePhotoProtection()
    let generation = UUID()
    actionGeneration = generation
    let controller: UIViewController
    switch action {
    case .photos: return
    case .open:
      let container = DownloadPreviewController()
      container.title = url.lastPathComponent
      container.preview.dataSource = self
      container.preview.delegate = self
      actionPreview = container.preview
      container.onClose = { [weak self] in self?.finishAction(generation: generation) }
      controller = container
    case .files:
      let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
      picker.delegate = self
      picker.view.accessibilityIdentifier = "folioDownloadFiles"
      controller = picker
    case .share:
      let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      share.view.accessibilityIdentifier = "folioDownloadShare"
      B3DownloadsPresentation.anchor(share, to: host)
      share.completionWithItemsHandler = { [weak self] _, _, _, _ in
        Task { @MainActor in self?.finishAction(generation: generation) }
      }
      controller = share
    }
    actionController = controller
    FolioEscape.register(controller) { [weak self] in self?.finishAction(generation: generation) }
    requestAttachment(controller, to: host, generation: generation)
    controller.presentationController?.delegate = self
    attachmentPoll = Task { [weak self, weak controller] in
      while !Task.isCancelled {
        guard let self, let controller, self.actionController === controller,
          self.actionGeneration == generation
        else { return }
        if self.attachment.resolved(controller) {
          #if DEBUG
            B3DownloadsPresentation.resolved(controller)
          #endif
          let retryAction =
            self.attaching && !self.closing && self.dismissalPoll == nil
            && !self.attachment.observed && B3DownloadsPresentation.detached(controller)
          self.attaching = false
          if !retryAction { self.attachmentPoll = nil }
          if retryAction {
            // Keep the same system controller and its file protection instead of
            // tearing down and recreating its remote service on every retry.
            if let host = self.actionPresentationHost {
              self.requestAttachment(controller, to: host, generation: generation)
            } else {
              // A resolved decline can wait for a usable host, without issuing
              // a second request for a still-pending native presentation.
              self.attaching = true
            }
          } else {
            if self.closing || B3DownloadsPresentation.detached(controller) {
              self.pollDismissal()
            }
            return
          }
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }
  private func requestAttachment(
    _ controller: UIViewController, to host: UIViewController, generation: UUID
  ) {
    attaching = true
    presentationAttempts += 1
    attachment = B3DownloadsPresentation.Attachment()
    let requestID = UUID()
    attachmentID = requestID
    #if DEBUG
      B3DownloadsPresentation.requested(controller, from: host)
    #endif
    presentController(host, controller) { [weak self, weak controller] in
      guard let self, let controller, self.actionController === controller,
        self.actionGeneration == generation, self.attachmentID == requestID
      else { return }
      self.attachment.completed = true
      self.attachment.observe(controller)
      if self.closing { self.pollDismissal() }
    }
    attachment.observe(controller)
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    controller === actionPreview && actionURL != nil ? 1 : 0
  }
  func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
    -> QLPreviewItem
  {
    guard controller === actionPreview, index == 0, let actionURL else {
      return DownloadCenterEmptyPreviewItem()
    }
    return actionURL as NSURL
  }
  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    guard controller === actionPreview else { return }
    finishAction(generation: actionGeneration)
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard controller === actionController else { return }
    finishAction(generation: actionGeneration)
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
  {
    documentPickerWasCancelled(controller)
  }
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard presentationController.presentedViewController === actionController else { return }
    finishAction(generation: actionGeneration)
  }
  private func finishAction(generation: UUID) {
    guard generation == actionGeneration, actionController != nil else { return }
    // Both successful disposition and cancellation keep the catalog file. Only Delete removes it.
    pollDismissal()
  }
  private func pollDismissal() {
    guard dismissalPoll == nil else { return }
    dismissalPoll = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let controller = self.actionController else { return }
        if !self.attaching, B3DownloadsPresentation.detached(controller) {
          if let id = self.actionItem, let token = self.actionProtection {
            self.catalog.release(id, token: token)
          }
          self.actionPreview = nil
          self.actionController = nil
          self.actionItem = nil
          self.actionProtection = nil
          self.actionURL = nil
          self.actionGeneration = UUID()
          self.dismissalPoll = nil
          if self.closing { self.onClose?() }
          return
        }
        if !self.attaching {
          B3DownloadsPresentation.dismiss(controller) {}
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }
  func suspendActions() {
    cancelPhoto()
    closing = true
    choiceGeneration = UUID()
    choicePoll?.cancel()
    choicePoll = nil
    if actionController != nil { pollDismissal() }
  }
  func close() {
    cancelPhoto()
    closing = true
    choiceGeneration = UUID()
    choicePoll?.cancel()
    choicePoll = nil
    if actionController != nil {
      pollDismissal()
    } else {
      onClose?()
    }
  }
}
