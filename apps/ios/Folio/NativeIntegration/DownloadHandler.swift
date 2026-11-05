import UIKit
import WebKit

@MainActor
public final class DownloadHandler: NSObject, WKDownloadDelegate, UIDocumentPickerDelegate,
  UIAdaptivePresentationControllerDelegate
{
  weak var presenter: UIViewController?
  var onLog: ((String) -> Void)?
  // Test seam for UIKit detachment that dismisses but omits its completion.
  var dismissController: (UIViewController, @escaping () -> Void) -> Void = {
    controller, completion in
    B3DownloadsPresentation.dismiss(controller, completion: completion)
  }
  var presentController: (UIViewController, UIViewController, @escaping () -> Void) -> Void = {
    host, controller, completion in host.present(controller, animated: true, completion: completion)
  }
  let catalog: DownloadCenterCatalog
  private struct Transfer {
    let download: WKDownload
    let id: UUID
    var destination: URL?
  }
  private var active: [ObjectIdentifier: Transfer] = [:]
  private var ready: [URL] = []
  private var queueProtections: [UUID: UUID] = [:]
  private var exportProtection: (UUID, UUID)?
  private var retiredProtections: [(UUID, UUID)] = []
  private(set) var exporting: URL?
  private(set) var exportID: UUID?
  private(set) var exportPresentation: UIViewController?
  private var isActive = true
  private var isClosed = false
  private var dismissing: UIViewController?
  private var dismissalGeneration = UUID()
  private var dismissalAction: (() -> Void)?
  private var retryGeneration = UUID()
  private var retry: Task<Void, Never>?
  private let presentationOwner = UUID()
  private var center: DownloadCenterController?
  /// Set while Folio download UI is shown; the page gets focus back once it is all gone.
  private var needsFocusRestore = false
  private var centerNavigation: UINavigationController?
  private var pendingCenter = false
  private var centerDismissalRequested = false
  private var transferMonitor: Task<Void, Never>?
  private var attaching: UIViewController?
  private var attachment = B3DownloadsPresentation.Attachment()
  private var requestSourceAncestors: [ObjectIdentifier] = []
  private var sourceContainmentChanged = false
  private var advancingQueue = false
  private var presentationAttempts = 0
  private var foreground = true
  private var lifecycleForeground = false
  private var sceneRecoveryPending = false
  private weak var presentationScene: UIWindowScene?
  private var lifecycleObservers: [NSObjectProtocol] = []
  // A closed tab can release its controller before an asynchronous system sheet
  // detaches. Retain only that retirement, then break the cycle after detachment.
  private var retirementKeepAlive: DownloadHandler?

  #if DEBUG
    private var lastPresentationTrace: String?
    private var presentationTraceCount = 0
    var presentationState: String {
      func state(_ controller: UIViewController?) -> String {
        guard let controller else { return "nil" }
        return "\(type(of: controller)) attached=\(controller.presentingViewController != nil)"
          + " window=\(controller.viewIfLoaded?.window != nil)"
          + " presenting=\(controller.isBeingPresented) dismissing=\(controller.isBeingDismissed)"
          + " transition=\(controller.transitionCoordinator != nil)"
      }
      return
        "handler=\(presentationOwner) source=\((presenter as? FigmaWebViewController)?.tabSession.id.uuidString ?? "nil") export=\(exportID?.uuidString ?? "nil")"
        + " file=\(exporting.flatMap { catalog.id(for: $0) }?.uuidString ?? ready.first.flatMap { catalog.id(for: $0) }?.uuidString ?? "nil")"
        + " catalogOwner=\(catalog.presentationOwner?.uuidString ?? "nil")"
        + " generation=\(dismissalGeneration) active=\(isActive) closed=\(isClosed)"
        + " pendingAction=\(dismissalAction != nil) host=[\(state(presenter))]"
        + " hostModal=[\(state(presenter?.presentedViewController))]"
        + " exportModal=[\(state(exportPresentation))] retiring=[\(state(dismissing))]"
        + " center=[\(state(centerNavigation))] centerClosing=\(centerDismissalRequested)"
        + " centerAction=[\(state(center?.actionController))]"
        + " ancestors=[\(B3DownloadsPresentation.state(presenter))]"
        + " attaching=[\(state(attaching))] queued=\(ready.count) foreground=\(foreground)"
        + " containmentChanged=\(sourceContainmentChanged) sceneRecovery=\(sceneRecoveryPending)"
        + " requests=\(presentationAttempts) observed=\(attachment.observed) acknowledged=\(attachment.completed)"
        + " centerAttachment=[\(center?.actionPresentationState ?? "nil")]"
    }
  #endif

  private func traceOwnership(_ event: String) {
    #if DEBUG
      let state = presentationState
      guard state != lastPresentationTrace, presentationTraceCount < 128 else { return }
      presentationTraceCount += 1
      lastPresentationTrace = state
      onLog?("Download ownership \(event): " + state)
    #endif
  }

  var pendingCount: Int { active.count + ready.count + (exporting == nil ? 0 : 1) }

  public convenience init(presenter: UIViewController) {
    self.init(presenter: presenter, catalog: .shared)
  }

  init(presenter: UIViewController, catalog: DownloadCenterCatalog) {
    self.presenter = presenter
    self.catalog = catalog
    super.init()
    for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
      lifecycleObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] notification in
          let sceneID = (notification.object as? UIScene).map(ObjectIdentifier.init)
          MainActor.assumeIsolated { self?.receiveForeground(false, sceneID: sceneID) }
        })
    }
    for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
      lifecycleObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] notification in
          let sceneID = (notification.object as? UIScene).map(ObjectIdentifier.init)
          MainActor.assumeIsolated { self?.receiveForeground(true, sceneID: sceneID) }
        })
    }
  }

  isolated deinit {
    retry?.cancel()
    transferMonitor?.cancel()
    for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
    for transfer in active.values {
      let catalog = catalog
      let id = transfer.id
      transfer.download.delegate = nil
      transfer.download.cancel { _ in catalog.cancelled(id) }
    }
    for (id, token) in queueProtections { catalog.release(id, token: token) }
    if let (id, token) = exportProtection { catalog.release(id, token: token) }
    for (id, token) in retiredProtections { catalog.release(id, token: token) }
    catalog.releasePresentation(presentationOwner)
  }

  static func filename(_ suggested: String) -> String { DownloadCenterCatalog.filename(suggested) }

  func accept(_ download: WKDownload) {
    guard active[ObjectIdentifier(download)] == nil else { return }
    guard !isClosed, pendingCount < 8, let id = try? catalog.begin() else {
      download.cancel { _ in }
      if !isClosed { onLog?("Download queue full") }
      return
    }
    active[ObjectIdentifier(download)] = Transfer(download: download, id: id)
    catalog.setProgress(download.progress, for: id)
    if let tab = (presenter as? FigmaWebViewController)?.tabSession {
      catalog.setSource(.init(tabID: tab.id, title: tab.displayTitle), for: id)
    }
    catalog.registerCancellation(id: id) { [weak self] in self?.cancelTransfer(id: id) }
    download.delegate = self
    monitorTransfers()
  }

  public func download(
    _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
    completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
  ) {
    let key = ObjectIdentifier(download)
    guard var transfer = active[key], transfer.destination == nil else {
      onLog?("Download no longer active")
      completionHandler(nil)
      return
    }
    do {
      let url = try catalog.destination(
        id: transfer.id, suggested: suggestedFilename,
        expectedBytes: response.expectedContentLength)
      transfer.destination = url
      active[key] = transfer
      completionHandler(url)
      onLog?("Download started")
    } catch {
      completionHandler(nil)
      cancelTransfer(id: transfer.id, failed: true)
      onLog?("Download destination failed")
    }
  }

  public func downloadDidFinish(_ download: WKDownload) {
    guard let transfer = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
    do {
      let url = try catalog.finish(id: transfer.id)
      enqueueCompletedExport(url)
    } catch {
      catalog.fail(id: transfer.id)
      onLog?("Download storage limit or file failure")
    }
  }

  public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    guard let transfer = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
    catalog.fail(id: transfer.id)
    onLog?("Download failed; NSError \((error as NSError).code)")
    // Resume data may contain credentials. Never retain it.
  }

  private func cancelTransfer(id: UUID, failed: Bool = false) {
    guard let key = active.first(where: { $0.value.id == id })?.key,
      let transfer = active.removeValue(forKey: key)
    else { return }
    transfer.download.delegate = nil
    let catalog = catalog
    // Keep the reservation until WebKit acknowledges cancellation; it may still write.
    transfer.download.cancel { _ in
      if failed { catalog.fail(id: id) } else { catalog.cancelled(id) }
    }
    // Remove the current partial file too; the completion cleans any later write.
    catalog.clearPartial(id: id)
  }

  private func monitorTransfers() {
    guard transferMonitor == nil else { return }
    transferMonitor = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let self else { return }
        if self.active.isEmpty {
          self.transferMonitor = nil
          return
        }
        for transfer in Array(self.active.values) {
          let written =
            transfer.destination.flatMap {
              try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
            } ?? 0
          if transfer.download.progress.completedUnitCount > DownloadCenterCatalog.maximumFileBytes
            || Int64(written) > DownloadCenterCatalog.maximumFileBytes
          {
            self.cancelTransfer(id: transfer.id, failed: true)
            self.onLog?("Download storage limit")
          }
        }
      }
    }
  }

  // Deactivation/replacement retains accepted transfers and queues completed files.
  func setActive(_ active: Bool) {
    guard !isClosed else { return }
    guard isActive != active else {
      reconcileDismissal()
      reconcileCenterDismissal()
      presentNext()
      return
    }
    isActive = active
    if active, lifecycleForeground, !foreground { sceneRecoveryPending = true }
    traceOwnership("source")
    invalidateRetry()
    if !active {
      pendingCenter = false
      suspendExport()
      if centerNavigation != nil {
        center?.suspendActions()
        centerDismissalRequested = true
        reconcileCenterDismissal()
      }
    }
    reconcileDismissal()
    presentNext()
  }

  private func receiveForeground(_ active: Bool, sceneID: ObjectIdentifier?) {
    if let sceneID,
      sceneID != presentationScene.map(ObjectIdentifier.init)
        && sceneID != presenter?.viewIfLoaded?.window?.windowScene.map(ObjectIdentifier.init)
    {
      return
    }
    lifecycleForeground = true
    sceneRecoveryPending = false
    applyForeground(active)
  }

  // System activities can complete while an external URL brings the app back.
  // Invalidate their export identity on resignation, before those callbacks can
  // consume the source queue. Foreground and selected-tab ownership are separate.
  func setForeground(_ active: Bool) {
    lifecycleForeground = false
    sceneRecoveryPending = false
    applyForeground(active)
  }

  private func applyForeground(_ active: Bool) {
    guard !isClosed else { return }
    guard foreground != active else {
      // Duplicate foreground delivery is still a wakeup after containment changes.
      presentNext()
      return
    }
    foreground = active
    traceOwnership("foreground")
    invalidateRetry()
    if !active {
      pendingCenter = false
      suspendExport()
      if centerNavigation != nil, center?.savingPhoto != true {
        center?.suspendActions()
        centerDismissalRequested = true
        reconcileCenterDismissal()
      }
    }
    reconcileDismissal()
    presentNext()
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    if exportPresentation != nil || dismissing != nil || centerNavigation != nil || attaching != nil
    {
      retirementKeepAlive = self
    }
    dismissalAction = nil
    isActive = false
    pendingCenter = false
    invalidateRetry()
    retireExportProtection()
    if let exporting { releaseQueuedFile(exporting) }
    exporting = nil
    exportID = nil
    for url in ready { releaseQueuedFile(url) }
    ready.removeAll()
    dismissExportPresentation()
    if centerNavigation != nil {
      center?.suspendActions()
      centerDismissalRequested = true
      reconcileCenterDismissal()
    }
    for transfer in Array(active.values) { cancelTransfer(id: transfer.id) }
    transferMonitor?.cancel()
    transferMonitor = nil
    finishRetirementIfIdle()
  }

  private func finishRetirementIfIdle() {
    guard isClosed, dismissing == nil, attaching == nil, centerNavigation == nil,
      exportPresentation == nil
    else { return }
    catalog.releasePresentation(presentationOwner)
    retirementKeepAlive = nil
  }

  // Also used by local native tests. Production files have a catalog ID; test files
  // retain ephemeral disposition semantics, confined to the service directory.
  func enqueueCompletedExport(_ url: URL) {
    guard
      url.resolvingSymlinksInPath().path.hasPrefix(
        catalog.root.resolvingSymlinksInPath().path + "/")
    else { return }
    guard !isClosed else {
      releaseQueuedFile(url)
      return
    }
    guard !ready.contains(url), exporting != url else { return }
    if let id = catalog.id(for: url), queueProtections[id] == nil {
      queueProtections[id] = catalog.protect(id)
      catalog.registerQueueRemoval(id: id) { [weak self] in
        guard let self else { return }
        self.ready.removeAll { self.catalog.id(for: $0) == id }
        if let token = self.queueProtections.removeValue(forKey: id) {
          self.catalog.release(id, token: token)
        }
      }
    }
    ready.append(url)
    onLog?("Download finished")
    presentNext()
  }

  private func suspendExport() {
    dismissalAction = nil
    retireExportProtection()
    if exporting != nil { onLog?("Export suspended") }
    if let exporting, !ready.contains(exporting) { ready.insert(exporting, at: 0) }
    exporting = nil
    exportID = nil
    dismissExportPresentation()
  }

  private func retireExportProtection() {
    if let protection = exportProtection { retiredProtections.append(protection) }
    exportProtection = nil
  }

  private func dismissExportPresentation() {
    guard let controller = exportPresentation else {
      reconcileDismissal()
      if dismissing == nil {
        for (id, token) in retiredProtections { catalog.release(id, token: token) }
        retiredProtections.removeAll()
      }
      return
    }
    exportPresentation = nil
    beginDismissal(controller)
  }

  private func beginDismissal(_ controller: UIViewController, then: (() -> Void)? = nil) {
    let generation = UUID()
    dismissalGeneration = generation
    dismissing = controller
    dismissalAction = then
    if attaching !== controller {
      dismissController(controller) { [weak self] in
        guard let self, self.dismissalGeneration == generation else { return }
        // UIKit is still unwinding the dismissal here. Reconcile on the next poll.
        self.scheduleNext()
      }
    }
    scheduleNext()
  }

  // UIKit may forward a child's presentation to the window ancestor. Containment
  // removal can omit its dismissal completion. Observe the actual modal relationship,
  // never clear the gate on a timer alone or dismiss an unrelated host modal.
  private func reconcileAttachment() {
    guard let controller = attaching else { return }
    // An external delivery can remove the source while UIKit finishes attaching
    // its ancestor's modal. Completion is advisory; the actual relationship owns
    // the gate. Never clear it merely because a retry deadline elapsed.
    if attachment.resolved(controller) {
      #if DEBUG
        B3DownloadsPresentation.resolved(controller)
      #endif
      attaching = nil
      if B3DownloadsPresentation.detached(controller) {
        // UIKit can decline an attempted presentation during a host transition.
        // Do not leave a consumed queue entry with no visible export choice.
        if controller === exportPresentation {
          if attachment.attached, isActive, foreground, !sourceContainmentChanged,
            let id = exportID
          {
            // User completion may arrive after UIKit has detached the picker.
            // Settle this request, never recreate its URL under another identity.
            complete(id: id)
          } else {
            suspendExport()
          }
        }
        if controller === centerNavigation, !centerDismissalRequested, !isClosed,
          isActive, foreground
        {
          pendingCenter = true
        }
      }
      onLog?("Download attachment reconciled")
    }
  }

  private func reconcileDismissal() {
    if !requestSourceAncestors.isEmpty,
      B3DownloadsPresentation.containmentIDs(presenter) != requestSourceAncestors
    {
      sourceContainmentChanged = true
    }
    // Containment removal is a source suspension even when UIKit omits the
    // activity/appearance callback. Invalidate export callbacks before the old
    // system modal disappears, while retaining its exact request and protection.
    // Parent identities certify source removal; modal retirement still requires
    // actual UIKit detachment. An unacknowledged request remains pending.
    if sourceContainmentChanged, exporting != nil {
      traceOwnership("containment-suspension")
      suspendExport()
    }
    if sourceContainmentChanged, centerNavigation != nil {
      center?.suspendActions()
      centerDismissalRequested = true
    }
    reconcileAttachment()
    if attaching == nil, let modal = exportPresentation, attachment.attached,
      B3DownloadsPresentation.detached(modal), let id = exportID,
      isActive, foreground, !sourceContainmentChanged
    {
      complete(id: id)
    }
    if attaching == nil, dismissing == nil, exportPresentation == nil, centerNavigation == nil {
      // This ancestry belongs to the retired request, not the returning source.
      requestSourceAncestors = []
      sourceContainmentChanged = false
    }
    guard let controller = dismissing else { return }
    if attaching !== controller, B3DownloadsPresentation.detached(controller) {
      dismissing = nil
      for (id, token) in retiredProtections { catalog.release(id, token: token) }
      retiredProtections.removeAll()
      onLog?("Export dismissal reconciled")
      dismissalGeneration = UUID()
      if centerNavigation == nil && exportPresentation == nil && exporting == nil {
        catalog.releasePresentation(presentationOwner)
      }
      // A detached modal does not prove its presenting ancestor is ready yet.
      // Keep the selected action until that host can actually attach its successor.
    } else if attaching !== controller,
      !controller.isBeingPresented && !controller.isBeingDismissed
        && controller.transitionCoordinator == nil
    {
      let generation = dismissalGeneration
      dismissController(controller) { [weak self] in
        guard let self, self.dismissalGeneration == generation else { return }
        self.scheduleNext()
      }
    }
  }

  private func invalidateRetry() {
    retryGeneration = UUID()
    retry?.cancel()
    retry = nil
  }
  private func scheduleNext() {
    guard retry == nil,
      attaching != nil || dismissing != nil || dismissalAction != nil || centerNavigation != nil
        || exportPresentation != nil
        || (isActive && !isClosed && (!ready.isEmpty || pendingCenter))
    else { return }
    let generation = retryGeneration
    retry = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(100))
      guard !Task.isCancelled, let self, self.retryGeneration == generation else { return }
      self.retry = nil
      self.reconcileDismissal()
      self.reconcileCenterDismissal()
      self.presentNext()
    }
  }

  private var presentationHost: UIViewController? {
    guard attaching == nil, let presenter else { return nil }
    // Scene notifications describe transitions. On a real source return, the
    // owning scene's public state settles the foreground gate even if UIKit
    // omitted/reordered the activation notification. Selection alone cannot.
    if sceneRecoveryPending, let scene = presenter.viewIfLoaded?.window?.windowScene,
      scene.activationState == .foregroundActive
    {
      foreground = true
      sceneRecoveryPending = false
    }
    guard foreground else { return nil }
    if let scene = presenter.viewIfLoaded?.window?.windowScene {
      presentationScene = scene
      guard scene.activationState == .foregroundActive else { return nil }
    }
    return B3DownloadsPresentation.host(for: presenter)
  }

  private func attach(_ controller: UIViewController, to host: UIViewController) {
    attaching = controller
    needsFocusRestore = true
    presentationAttempts += 1
    attachment = B3DownloadsPresentation.Attachment()
    requestSourceAncestors = B3DownloadsPresentation.containmentIDs(presenter)
    sourceContainmentChanged = false
    #if DEBUG
      B3DownloadsPresentation.requested(controller, from: host)
    #endif
    presentController(host, controller) { [weak self, weak controller] in
      guard let self, let controller, self.attaching === controller else { return }
      self.attachment.completed = true
      self.attachment.observe(controller)
      // Completion can re-enter browser appearance callbacks. Advance only on
      // the next main-actor turn, retaining modal/file ownership in the meantime.
      self.scheduleNext()
    }
    attachment.observe(controller)
    scheduleNext()
  }

  func presentNext() {
    // Host layout can re-enter through browser appearance. Commit one queue
    // choice per turn, with the same modal ownership across that callback.
    guard !advancingQueue else {
      scheduleNext()
      return
    }
    advancingQueue = true
    defer { advancingQueue = false }
    reconcileDismissal()
    reconcileCenterDismissal()
    traceOwnership("queue")
    finishRetirementIfIdle()
    if dismissing == nil, let action = dismissalAction {
      guard isActive, !isClosed, presentationHost != nil else {
        scheduleNext()
        return
      }
      dismissalAction = nil
      action()
    }
    guard isActive, !isClosed, dismissing == nil, exporting == nil, centerNavigation == nil else {
      scheduleNext()
      return
    }
    guard pendingCenter || !ready.isEmpty else {
      catalog.releasePresentation(presentationOwner)
      if needsFocusRestore, attaching == nil, presenter?.presentedViewController == nil {
        needsFocusRestore = false
        (presenter as? FigmaWebViewController)?.restoreBrowserFocus(reason: .nativeAlertDismissed)
      }
      return
    }
    guard let presenter = presentationHost, isActive, !isClosed, foreground,
      attaching == nil, dismissing == nil, exporting == nil, centerNavigation == nil,
      catalog.claimPresentation(presentationOwner)
    else {
      scheduleNext()
      return
    }
    if pendingCenter {
      pendingCenter = false
      let center = DownloadCenterController(catalog: catalog)
      let navigation = UINavigationController(rootViewController: center)
      navigation.view.accessibilityIdentifier = "folioDownloadCenter"
      navigation.setNavigationBarHidden(true, animated: false)
      DownloadCenterController.presentAsSheet(navigation)
      center.onClose = { [weak self, weak center] in
        guard let self, let center, self.center === center else { return }
        self.centerDismissalRequested = true
        self.scheduleNext()
      }
      FolioEscape.register(navigation) { [weak center] in center?.close() }
      self.center = center
      centerDismissalRequested = false
      centerNavigation = navigation
      attach(navigation, to: presenter)
      navigation.presentationController?.delegate = self
      scheduleNext()
      return
    }
    let url = ready.removeFirst()
    let id = UUID()
    exporting = url
    if let fileID = catalog.id(for: url) {
      exportProtection = (fileID, catalog.protect(fileID, presentation: true))
    }
    exportID = id
    onLog?("Export choice presented")
    let choice = UIAlertController(
      title: "Export ready", message: "Choose where to save or share the downloaded file.",
      preferredStyle: .alert)
    choice.addAction(
      UIAlertAction(title: "Save to Files", style: .default) { [weak self] _ in
        self?.chooseFiles(id: id)
      })
    choice.addAction(
      UIAlertAction(title: "Share", style: .default) { [weak self] _ in self?.chooseShare(id: id) })
    choice.addAction(
      UIAlertAction(title: "Downloads", style: .default) { [weak self] _ in
        self?.showDownloadCenter()
      })
    choice.addAction(
      UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.complete(id: id) })
    exportPresentation = choice
    FolioEscape.register(choice) { [weak self] in self?.complete(id: id) }
    attach(choice, to: presenter)
  }

  /// Selected-tab host entry. Transfers continue; queued automatic choices resume on Close.
  /// Host must retain this handler and call setActive before removing its containment.
  public func showDownloadCenter() {
    guard isActive, !isClosed, centerNavigation == nil else { return }
    pendingCenter = true
    invalidateRetry()
    suspendExport()
    presentNext()
  }

  private func reconcileCenterDismissal() {
    reconcileAttachment()
    guard let navigation = centerNavigation else { return }
    if attaching !== navigation, B3DownloadsPresentation.detached(navigation) {
      // An observed ancestor can disappear without its Done/dismiss callback.
      // Retire the Center's exact action before releasing the shared owner.
      center?.suspendActions()
    }
    if attaching !== navigation, B3DownloadsPresentation.detached(navigation),
      center?.actionController == nil, center?.presentedViewController == nil
    {
      center?.suspendActions()
      center = nil
      centerNavigation = nil
      centerDismissalRequested = false
      catalog.releasePresentation(presentationOwner)
    } else {
      // Never tear down an ancestor while its preview/system sheet is transitioning.
      // The center first retires its protected action; menus detach with the center.
      let modal = navigation.presentedViewController
      if attaching !== navigation, centerDismissalRequested, center?.actionController == nil,
        !navigation.isBeingPresented, !navigation.isBeingDismissed,
        navigation.transitionCoordinator == nil,
        modal?.isBeingPresented != true, modal?.isBeingDismissed != true,
        modal?.transitionCoordinator == nil
      {
        B3DownloadsPresentation.dismiss(navigation) {}
      }
      scheduleNext()
    }
  }

  private func transition(id: UUID, show: @escaping (DownloadHandler, URL) -> Void) {
    guard exportID == id, let url = exporting, let choice = exportPresentation else { return }
    exportPresentation = nil
    beginDismissal(choice) { [weak self] in
      guard let self, self.exportID == id, self.isActive, !self.isClosed else { return }
      show(self, url)
    }
  }

  func chooseFiles(id: UUID) {
    transition(id: id) { handler, url in
      let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
      picker.view.accessibilityIdentifier = "folioExportFiles"
      picker.delegate = handler
      handler.present(picker)
    }
  }
  func chooseShare(id: UUID) {
    transition(id: id) { handler, url in
      guard let host = handler.presentationHost else { return }
      let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      sheet.view.accessibilityIdentifier = "folioExportShare"
      B3DownloadsPresentation.anchor(sheet, to: host)
      sheet.completionWithItemsHandler = { [weak handler] _, _, _, _ in
        Task { @MainActor in handler?.complete(id: id) }
      }
      handler.present(sheet)
    }
  }
  private func present(_ controller: UIViewController) {
    guard let host = presentationHost else { return }
    exportPresentation = controller
    if let id = exportID {
      FolioEscape.register(controller) { [weak self] in self?.complete(id: id) }
    }
    attach(controller, to: host)
    if !(controller is UIAlertController) { controller.presentationController?.delegate = self }
  }
  public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    if presentationController.presentedViewController === centerNavigation {
      reconcileCenterDismissal()
      presentNext()
      return
    }
    guard presentationController.presentedViewController === exportPresentation, let id = exportID
    else { return }
    complete(id: id)
  }
  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard controller === exportPresentation, let id = exportID else { return }
    complete(id: id)
  }
  public func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
    documentPickerWasCancelled(controller)
  }
  func complete(id: UUID) {
    guard exportID == id else { return }
    retireExportProtection()
    if let exporting { releaseQueuedFile(exporting) }
    exporting = nil
    exportID = nil
    invalidateRetry()
    dismissExportPresentation()
    scheduleNext()
  }
  private func releaseQueuedFile(_ url: URL) {
    if let id = catalog.id(for: url) {
      catalog.unregisterQueueRemoval(id: id)
      if let token = queueProtections.removeValue(forKey: id) { catalog.release(id, token: token) }
    } else {
      // Uncataloged local fixtures are still confined to this service directory.
      if url.resolvingSymlinksInPath().path.hasPrefix(
        catalog.root.resolvingSymlinksInPath().path + "/")
      {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }
}
