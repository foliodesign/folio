import Photos
import QuickLook
import UIKit
import WebKit
import XCTest

@testable import Folio

@MainActor
private final class DownloadLayoutPresenter: UIViewController {
  var onLayout: (() -> Void)?
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    onLayout?()
  }
}

@MainActor
final class DownloadCenterTests: XCTestCase {
  private let presentationProbe = NativeModalCompletionProbe()
  private var fixtureWindows: [UIWindow] = []
  private var windowCleanup: [ObjectIdentifier: () throws -> Void] = [:]

  private func makeHandler(presenter: UIViewController, catalog: DownloadCenterCatalog)
    -> DownloadHandler
  {
    let handler = DownloadHandler(presenter: presenter, catalog: catalog)
    handler.presentController = { [presentationProbe] host, controller, completion in
      if let navigation = controller as? UINavigationController,
        let center = navigation.topViewController as? DownloadCenterController
      {
        center.presentController = { host, controller, completion in
          presentationProbe.present(host, controller, completion, acknowledgeOwner: true)
        }
      }
      presentationProbe.present(host, controller, completion, acknowledgeOwner: true)
    }
    return handler
  }

  private func observedCenter(_ center: DownloadCenterController) -> DownloadCenterController {
    center.presentController = { [presentationProbe] host, controller, completion in
      presentationProbe.present(host, controller, completion, acknowledgeOwner: true)
    }
    return center
  }

  private func closeWindow(_ window: UIWindow) throws {
    let key = ObjectIdentifier(window)
    // Remove before invoking: throwing cleanup must not retain this test through
    // the dictionary. The fixture stays visible if UIKit has not detached.
    let cleanup = windowCleanup.removeValue(forKey: key)
    try cleanup?()
    fixtureWindows.removeAll { $0 === window }
  }

  func testThrowingWindowCleanupRemovesOwnershipBeforeCallingClosure() throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let key = ObjectIdentifier(window)
    var calls = 0
    windowCleanup[key] = {
      calls += 1
      XCTAssertNil(self.windowCleanup[key])
      throw NSError(domain: "Fixture cleanup failure", code: 1)
    }
    XCTAssertThrowsError(try closeWindow(window))
    XCTAssertTrue(windowCleanup.isEmpty)
    try closeWindow(window)
    XCTAssertEqual(calls, 1)
  }

  private func waitForPresentation(
    _ controller: UIViewController, in window: UIWindow,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    try waitUntil(
      file: file, line: line,
      diagnostics: String(describing: type(of: controller))
        + " window=\(controller.viewIfLoaded?.window === window)"
        + " presenter=[\(B3DownloadsPresentation.state(controller.presentingViewController))]"
        + " presenting=\(controller.isBeingPresented) dismissing=\(controller.isBeingDismissed)"
        + " transition=\(controller.transitionCoordinator != nil)"
    ) {
      controller.presentingViewController != nil && controller.viewIfLoaded?.window === window
        && !controller.isBeingPresented && !controller.isBeingDismissed
        && controller.transitionCoordinator == nil
    }
  }
  private func catalog() throws -> DownloadCenterCatalog {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = parent.appendingPathComponent("Downloads", isDirectory: true)
    let catalog = DownloadCenterCatalog(root: root)
    addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
    return catalog
  }
  private func completed(
    _ catalog: DownloadCenterCatalog, name: String = "fixture.txt", size: UInt64 = 18
  ) throws -> UUID {
    let id = try catalog.begin()
    let url = try catalog.destination(id: id, suggested: name, expectedBytes: Int64(size))
    try Data("Local blob fixture".utf8).write(to: url)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: size)
    try handle.close()
    _ = try catalog.finish(id: id)
    return id
  }
  private func photoFixture(_ catalog: DownloadCenterCatalog) throws -> UUID {
    let id = try catalog.begin()
    let url = try catalog.destination(id: id, suggested: "photo.png", expectedBytes: 128)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
    try XCTUnwrap(image.pngData()).write(to: url)
    _ = try catalog.finish(id: id)
    return id
  }

  func testPhotosCenterOutcomeIsVisibleAndAllowsAnotherExplicitSave() throws {
    for status in [PHAuthorizationStatus.authorized, .denied, .restricted] {
      let catalog = try catalog()
      let id = try photoFixture(catalog)
      var requests = 0
      let photos = PhotosExportService(
        permission: {
          requests += 1
          $0(status)
        }, write: { _, done in done(true) })
      let center = observedCenter(DownloadCenterController(catalog: catalog, photos: photos))
      let navigation = UINavigationController(rootViewController: center)
      let window = try window(navigation)
      defer { try? closeWindow(window) }
      XCTAssertEqual(requests, 0, "Opening Center must not request Photos access")
      center.perform(.photos, id: id)
      let label = center.statusLabel
      let expected: PhotosExportService.Outcome =
        status == .authorized ? .saved : status == .denied ? .denied : .restricted
      XCTAssertEqual(label.text, expected.message)
      XCTAssertFalse(center.savingPhoto)
      XCTAssertNil(center.actionController)
      XCTAssertNotNil(catalog.completedURL(id: id))
      XCTAssertEqual(catalog.isProtected(id), status != .authorized)
      if status != .authorized { XCTAssertFalse(catalog.delete(id)) }
      center.perform(.photos, id: id)
      XCTAssertEqual(requests, 2)
      center.suspendActions()
      XCTAssertFalse(catalog.isProtected(id))
    }
  }

  func testPhotosWriteFailureKeepsFileProtectedThroughFilesFallbackAndCancellation() throws {
    let catalog = try catalog()
    let id = try photoFixture(catalog)
    let url = try XCTUnwrap(catalog.completedURL(id: id))
    let photos = PhotosExportService(
      permission: { $0(.authorized) }, write: { _, done in done(false) })
    let center = observedCenter(DownloadCenterController(catalog: catalog, photos: photos))
    let window = try window(UINavigationController(rootViewController: center))
    defer {
      center.suspendActions()
      try? closeWindow(window)
    }
    center.perform(.photos, id: id)
    XCTAssertEqual(
      center.statusLabel.text,
      PhotosExportService.Outcome.failed.message)
    XCTAssertFalse(center.savingPhoto)
    XCTAssertTrue(catalog.isProtected(id))
    XCTAssertFalse(catalog.delete(id))
    center.perform(.files, id: id)
    let picker = try XCTUnwrap(center.actionController as? UIDocumentPickerViewController)
    try waitForPresentation(picker, in: window)
    XCTAssertTrue(catalog.isProtected(id))
    center.documentPickerWasCancelled(picker)
    try waitUntil { B3DownloadsPresentation.detached(picker) && center.actionController == nil }
    XCTAssertFalse(catalog.isProtected(id))
    XCTAssertEqual(catalog.completedURL(id: id), url)
  }

  func testPhotosCenterSuspensionCancelsPermissionAndIgnoresLateGrant() throws {
    let catalog = try catalog()
    let id = try photoFixture(catalog)
    var permission: (@MainActor @Sendable (PHAuthorizationStatus) -> Void)?
    var writes = 0
    let photos = PhotosExportService(
      permission: { permission = $0 }, write: { _, _ in writes += 1 })
    let center = observedCenter(DownloadCenterController(catalog: catalog, photos: photos))
    let window = try window(UINavigationController(rootViewController: center))
    defer { try? closeWindow(window) }
    center.perform(.photos, id: id)
    XCTAssertTrue(center.savingPhoto)
    XCTAssertFalse(catalog.delete(id))
    center.perform(.photos, id: id)
    center.suspendActions()
    permission?(.authorized)
    XCTAssertEqual(writes, 0)
    XCTAssertFalse(center.savingPhoto)
    XCTAssertFalse(catalog.isProtected(id))
    XCTAssertNotNil(catalog.completedURL(id: id))
  }

  private func window(_ presenter: UIViewController) throws -> UIWindow {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = presenter
    window.makeKeyAndVisible()
    fixtureWindows.append(window)
    presenter.view.layoutIfNeeded()
    windowCleanup[ObjectIdentifier(window)] = { [weak self] in
      guard let self else { return }
      do {
        try self.waitUntil {
          let modal = presenter.presentedViewController
          return !presenter.isBeingPresented && !presenter.isBeingDismissed
            && presenter.transitionCoordinator == nil
            && modal?.isBeingPresented != true && modal?.isBeingDismissed != true
            && modal?.transitionCoordinator == nil
            && !B3DownloadsPresentation.hasPendingAttachment(in: window)
        }
        presenter.dismiss(animated: false)
        try self.waitUntil {
          presenter.presentedViewController == nil && presenter.transitionCoordinator == nil
        }
        window.isHidden = true
        window.rootViewController = nil
        if previousKeyWindow?.isHidden == false { previousKeyWindow?.makeKey() }
        XCTAssertFalse(window.isKeyWindow)
      } catch {
        // Preserve the failure. Retain only the window retirement, never XCTest,
        // and let UIKit finish before hiding the fixture or restoring key focus.
        Task { @MainActor [window, presenter, previousKeyWindow] in
          // Observe only. The handler owns dismissal of its exact controller,
          // including delayed child requests not yet visible in UIKit's tree.
          while B3DownloadsPresentation.hasPendingAttachment(in: window)
            || presenter.presentedViewController != nil
            || presenter.transitionCoordinator != nil
            || presenter.isBeingPresented || presenter.isBeingDismissed
          {
            try? await Task.sleep(for: .milliseconds(100))
          }
          window.isHidden = true
          window.rootViewController = nil
          if previousKeyWindow?.isHidden == false { previousKeyWindow?.makeKey() }
        }
        throw error
      }
    }
    addTeardownBlock { @MainActor in try self.closeWindow(window) }
    return window
  }
  private enum WaitError: Error { case timeout }
  private func waitUntil(
    file: StaticString = #filePath, line: UInt = #line,
    diagnostics: @autoclosure @escaping @MainActor () -> String = "",
    _ condition: @escaping @MainActor () -> Bool
  ) throws {
    // A newly issued UIKit request ends the state phase and returns to its
    // completion signal. The original three-second state watchdog is unchanged.
    while true {
      try presentationProbe.waitForPending(file: file, line: line)
      try NativeModalCompletionProbe.waitForTransitions(in: fixtureWindows, file: file, line: line)
      if condition() { return }
      let expectation = XCTestExpectation(description: "Download Center settled")
      let probe = presentationProbe
      let windows = fixtureWindows
      let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
        if MainActor.assumeIsolated({
          condition() || probe.hasPending
            || NativeModalCompletionProbe.hasTransitions(in: windows)
        }) {
          timer.invalidate()
          expectation.fulfill()
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      defer { timer.invalidate() }
      guard XCTWaiter.wait(for: [expectation], timeout: 3) == .completed else {
        XCTFail("Download Center did not settle: " + diagnostics(), file: file, line: line)
        throw WaitError.timeout
      }
    }
  }
  private func settle() throws {
    try presentationProbe.waitForPending()
    try NativeModalCompletionProbe.waitForTransitions(in: fixtureWindows)
    // Deliberate observation interval for duplicate/stale callbacks, not readiness.
    let expectation = XCTestExpectation(description: "No duplicate action observation interval")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { expectation.fulfill() }
    guard XCTWaiter.wait(for: [expectation], timeout: 3) == .completed else {
      throw WaitError.timeout
    }
  }

  func testUnattachedRequestNeedsAcknowledgementBeforeItCanResolveAsDetached() {
    let controller = UIViewController()
    var attachment = B3DownloadsPresentation.Attachment()
    XCTAssertTrue(B3DownloadsPresentation.detached(controller))
    for _ in 0..<5 { XCTAssertFalse(attachment.resolved(controller)) }
    attachment.completed = true
    XCTAssertTrue(attachment.resolved(controller))
    var previouslyAttached = B3DownloadsPresentation.Attachment()
    previouslyAttached.observed = true
    XCTAssertTrue(previouslyAttached.resolved(controller))
  }

  func testFilenameKeepsExtensionAndBoundsUTF8WithoutPathOrControlCharacters() {
    XCTAssertEqual(DownloadHandler.filename("../../report.pdf"), "report.pdf")
    XCTAssertEqual(DownloadHandler.filename(".."), "export")
    XCTAssertEqual(DownloadHandler.filename("bad\\name\u{0}.txt"), "badname.txt")
    XCTAssertEqual(DownloadHandler.filename("\u{202E}file\n.txt"), "file.txt")
    let long = DownloadHandler.filename(String(repeating: "界", count: 180) + ".svg")
    XCTAssertLessThanOrEqual(long.utf8.count, 180)
    XCTAssertTrue(long.hasSuffix(".svg"))
    XCTAssertEqual(DownloadHandler.filename("   "), "export")
  }

  func testLocalCatalogRoundTripAndNoSourceOrPreviewMetadata() throws {
    let catalog = try catalog()
    let id = try completed(catalog, name: "../../safe.pdf")
    let url = try XCTUnwrap(catalog.completedURL(id: id))
    let reloaded = DownloadCenterCatalog(root: catalog.root)
    XCTAssertEqual(reloaded.items, catalog.items)
    XCTAssertEqual(
      reloaded.completedURL(id: id)?.resolvingSymlinksInPath(), url.resolvingSymlinksInPath())
    XCTAssertEqual(reloaded.item(id)?.basename, "safe.pdf")
    let data = try Data(contentsOf: catalog.root.appendingPathComponent("catalog.json"))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: NSObject])
    XCTAssertEqual(Set(json.keys), ["version", "items"])
    let records = try XCTUnwrap(json["items"] as? [[String: NSObject]])
    XCTAssertEqual(
      Set(try XCTUnwrap(records.first).keys),
      ["id", "basename", "type", "status", "size", "created", "updated"])
    let text = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(text.contains("Local blob fixture"))
    XCTAssertFalse(text.contains("figma.com"))
    XCTAssertFalse(text.contains("resume"))
  }

  func testCorruptAndUnknownCatalogRemoveOnlyOwnOrphans() throws {
    for raw in ["broken json", "{\"version\":999,\"items\":[]}"] {
      let catalog = try catalog()
      let id = try completed(catalog)
      let outside = catalog.root.deletingLastPathComponent().appendingPathComponent("outside.txt")
      try Data("Outside".utf8).write(to: outside)
      let link = catalog.root.appendingPathComponent("orphan-link")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
      try Data(raw.utf8).write(to: catalog.root.appendingPathComponent("catalog.json"))
      let reloaded = DownloadCenterCatalog(root: catalog.root)
      XCTAssertTrue(reloaded.items.isEmpty)
      XCTAssertFalse(FileManager.default.fileExists(atPath: catalog.fileURL(id: id)!.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
    }
  }

  func testOrphanMissingFileAndInterruptedTransferRepairOnRelaunch() throws {
    let catalog = try catalog()
    let retained = try completed(catalog)
    let missing = try completed(catalog)
    try FileManager.default.removeItem(at: try XCTUnwrap(catalog.completedURL(id: missing)))
    let interrupted = try catalog.begin()
    let partial = try catalog.destination(
      id: interrupted, suggested: "partial.txt", expectedBytes: -1)
    try Data("Partial local fixture".utf8).write(to: partial)
    let orphan = catalog.root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
    let reloaded = DownloadCenterCatalog(root: catalog.root)
    XCTAssertNotNil(reloaded.completedURL(id: retained))
    XCTAssertNil(reloaded.item(missing))
    XCTAssertEqual(reloaded.item(interrupted)?.status, .failed)
    XCTAssertEqual(reloaded.item(interrupted)?.size, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
  }

  func testInvalidRecordFilenameAndSymlinkFileNeverOpenOrDeleteOutsideRoot() throws {
    let catalog = try catalog()
    let id = try completed(catalog)
    let file = try XCTUnwrap(catalog.completedURL(id: id))
    let outside = catalog.root.deletingLastPathComponent().appendingPathComponent("outside.txt")
    try Data("Outside".utf8).write(to: outside)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
    XCTAssertNil(catalog.completedURL(id: id))
    let reloaded = DownloadCenterCatalog(root: catalog.root)
    XCTAssertNil(reloaded.item(id))
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    let good = try completed(reloaded)
    let archive = reloaded.root.appendingPathComponent("catalog.json")
    let data = try Data(contentsOf: archive)
    let altered = String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "fixture.txt", with: "../outside.txt")
    try Data(altered.utf8).write(to: archive)
    let invalid = DownloadCenterCatalog(root: catalog.root)
    XCTAssertNil(invalid.item(good))
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
  }

  func testRootSymlinkIsUnavailableAndDoesNotCleanTarget() throws {
    let catalog = try catalog()
    let outside = catalog.root.deletingLastPathComponent().appendingPathComponent("Outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let marker = outside.appendingPathComponent("marker.txt")
    try Data("Outside".utf8).write(to: marker)
    let link = catalog.root.deletingLastPathComponent().appendingPathComponent("Linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let linked = DownloadCenterCatalog(root: link)
    XCTAssertThrowsError(try linked.begin())
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
  }

  func testHardCountEvictsOldestUnprotectedAndRejectsFullyProtectedCatalog() throws {
    let catalog = try catalog()
    var ids: [UUID] = []
    var tokens: [UUID: UUID] = [:]
    for _ in 0..<DownloadCenterCatalog.maximumCount {
      let id = try completed(catalog)
      ids.append(id)
      tokens[id] = catalog.protect(id)
    }
    XCTAssertEqual(catalog.items.count, 32)
    XCTAssertThrowsError(try catalog.begin())
    let first = try XCTUnwrap(ids.first)
    catalog.release(first, token: try XCTUnwrap(tokens[first]))
    let transfer = try catalog.begin()
    XCTAssertNil(catalog.item(first))
    XCTAssertEqual(catalog.items.count, 32)
    catalog.cancelled(transfer)
    for id in ids.dropFirst() { XCTAssertNotNil(catalog.item(id)) }
  }

  func testHardByteReservationAndPerFileLimitProtectTransfersAndPresentedFiles() throws {
    let catalog = try catalog()
    let active = try (0..<4).map { _ in try catalog.begin() }
    XCTAssertEqual(catalog.reservedBytes, DownloadCenterCatalog.maximumBytes)
    XCTAssertThrowsError(try catalog.begin())
    XCTAssertThrowsError(
      try catalog.destination(
        id: active[0], suggested: "huge.zip",
        expectedBytes: DownloadCenterCatalog.maximumFileBytes + 1))
    for id in active {
      XCTAssertFalse(catalog.delete(id))
      catalog.cancelled(id)
    }
    var files: [UUID] = []
    var pins: [UUID: UUID] = [:]
    for _ in 0..<4 {
      let id = try completed(catalog, size: UInt64(DownloadCenterCatalog.maximumFileBytes))
      files.append(id)
      pins[id] = catalog.protect(id, presentation: true)
    }
    XCTAssertEqual(catalog.reservedBytes, DownloadCenterCatalog.maximumBytes)
    XCTAssertThrowsError(try catalog.begin())
    XCTAssertFalse(catalog.delete(files[0]))
    catalog.release(files[0], token: try XCTUnwrap(pins[files[0]]))
    _ = try catalog.begin()
    XCTAssertNil(catalog.item(files[0]))
    XCTAssertLessThanOrEqual(catalog.reservedBytes, DownloadCenterCatalog.maximumBytes)
  }

  func testOversizeUnknownLengthFinishIsRejectedAndFailureIdempotent() throws {
    let catalog = try catalog()
    let id = try catalog.begin()
    let url = try catalog.destination(id: id, suggested: "large.zip", expectedBytes: -1)
    try Data().write(to: url)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(DownloadCenterCatalog.maximumFileBytes + 1))
    try handle.close()
    XCTAssertThrowsError(try catalog.finish(id: id))
    catalog.fail(id: id)
    catalog.fail(id: id)
    XCTAssertEqual(catalog.item(id)?.status, .failed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertTrue(catalog.delete(id))
    XCTAssertFalse(catalog.delete(id))
  }

  func testExplicitDeleteClearsQueueButTabClosePreservesCompletedCatalogFiles() throws {
    let catalog = try catalog()
    let presenter = UIViewController()
    let handler = makeHandler(presenter: presenter, catalog: catalog)
    handler.setActive(false)
    let id = try completed(catalog)
    handler.enqueueCompletedExport(try XCTUnwrap(catalog.completedURL(id: id)))
    XCTAssertEqual(handler.pendingCount, 1)
    XCTAssertTrue(catalog.delete(id))
    XCTAssertEqual(handler.pendingCount, 0)
    let kept = try completed(catalog)
    handler.enqueueCompletedExport(try XCTUnwrap(catalog.completedURL(id: kept)))
    handler.close()
    handler.close()
    XCTAssertEqual(handler.pendingCount, 0)
    XCTAssertNotNil(catalog.completedURL(id: kept))
    XCTAssertFalse(catalog.isProtected(kept))
    XCTAssertNotNil(DownloadCenterCatalog(root: catalog.root).completedURL(id: kept))
  }

  func testCatalogCancellationUsesOnlyOwningCallbackAndRetainsReservationUntilAcknowledged() throws
  {
    let catalog = try catalog()
    let first = try catalog.begin()
    let second = try catalog.begin()
    var firstCalls = 0
    var secondCalls = 0
    catalog.registerCancellation(id: first) { firstCalls += 1 }
    catalog.registerCancellation(id: second) { secondCalls += 1 }
    catalog.cancel(first)
    catalog.cancel(first)
    XCTAssertEqual(firstCalls, 1)
    XCTAssertEqual(secondCalls, 0)
    XCTAssertFalse(catalog.delete(first))
    XCTAssertEqual(catalog.items.count, 2)
    catalog.cancelled(first)
    catalog.cancelled(first)
    XCTAssertEqual(catalog.item(first)?.status, .cancelled, "Cancelled downloads stay listed")
    XCTAssertEqual(catalog.item(first)?.size, 0)
    XCTAssertTrue(catalog.delete(first))
    XCTAssertNotNil(catalog.item(second))
  }

  func testCenterBlocksOtherHandlerAndResumesAutomaticChoiceAfterClose() throws {
    let catalog = try catalog()
    let presenter = UIViewController()
    let window = try window(presenter)
    let handler = makeHandler(presenter: presenter, catalog: catalog)
    let otherPresenter = UIViewController()
    let otherWindow = try self.window(otherPresenter)
    let other = makeHandler(presenter: otherPresenter, catalog: catalog)
    defer {
      handler.close()
      other.close()
      try? closeWindow(otherWindow)
      try? closeWindow(window)
    }
    handler.showDownloadCenter()
    try waitUntil(diagnostics: handler.presentationState) {
      presenter.presentedViewController is UINavigationController
    }
    let navigation = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
    try waitForPresentation(navigation, in: window)
    let center = try XCTUnwrap(navigation.topViewController as? DownloadCenterController)
    let first = try completed(catalog)
    handler.enqueueCompletedExport(try XCTUnwrap(catalog.completedURL(id: first)))
    let second = try completed(catalog)
    other.enqueueCompletedExport(try XCTUnwrap(catalog.completedURL(id: second)))
    XCTAssertNil(handler.exportID)
    XCTAssertNil(other.exportID)
    XCTAssertEqual(handler.pendingCount, 1)
    center.onClose?()
    try waitUntil { handler.exportPresentation is UIAlertController }
    XCTAssertEqual(handler.exporting, catalog.completedURL(id: first))
    XCTAssertFalse(catalog.delete(first), "A presented file must stay protected")
    XCTAssertNil(other.exportID)
    handler.complete(id: try XCTUnwrap(handler.exportID))
    try waitUntil { presenter.presentedViewController == nil }
    XCTAssertNotNil(catalog.completedURL(id: first))
    try waitUntil { other.exportID != nil }
    XCTAssertEqual(other.exporting, catalog.completedURL(id: second))
  }

  func testPresentationHostRechecksSourceAfterLayoutDetachesIt() throws {
    let root = DownloadLayoutPresenter()
    let window = try window(root)
    defer { try? closeWindow(window) }
    let source = UIViewController()
    root.addChild(source)
    source.view.frame = root.view.bounds
    root.view.addSubview(source.view)
    source.didMove(toParent: root)
    XCTAssertTrue(source.view.window === window)
    root.onLayout = { [weak source] in
      source?.willMove(toParent: nil)
      source?.view.removeFromSuperview()
      source?.removeFromParent()
    }
    root.view.setNeedsLayout()
    XCTAssertNil(B3DownloadsPresentation.host(for: source))
    XCTAssertNil(source.view.window)
    XCTAssertNil(root.presentedViewController)
  }

  func testLayoutReentryCommitsOnlyOneExportChoice() throws {
    let root = DownloadLayoutPresenter()
    let window = try window(root)
    let catalog = try catalog()
    let handler = makeHandler(presenter: root, catalog: catalog)
    defer {
      handler.close()
      try? closeWindow(window)
    }
    handler.setActive(false)
    let first = try completed(catalog)
    let second = try completed(catalog)
    handler.enqueueCompletedExport(try XCTUnwrap(catalog.completedURL(id: first)))
    handler.enqueueCompletedExport(try XCTUnwrap(catalog.completedURL(id: second)))
    root.onLayout = { [weak handler] in handler?.presentNext() }
    root.view.setNeedsLayout()
    handler.setActive(true)
    try waitUntil {
      handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
    }
    XCTAssertEqual(handler.exporting, catalog.completedURL(id: first))
    XCTAssertEqual(handler.pendingCount, 2)
    handler.complete(id: try XCTUnwrap(handler.exportID))
    try waitUntil {
      handler.exporting == catalog.completedURL(id: second)
        && handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
    }
    XCTAssertEqual(handler.pendingCount, 1)
  }

  func testDelayedFilesPresentationIsRequestedOnceAndRetiredBeforeCenterCloses() throws {
    let catalog = try catalog()
    let id = try completed(catalog)
    let root = UIViewController()
    let window = try window(root)
    let handler = makeHandler(presenter: root, catalog: catalog)
    defer {
      handler.close()
      try? closeWindow(window)
    }
    handler.showDownloadCenter()
    try waitUntil { root.presentedViewController is UINavigationController }
    let navigation = try XCTUnwrap(root.presentedViewController as? UINavigationController)
    try waitForPresentation(navigation, in: window)
    let center = try XCTUnwrap(navigation.topViewController as? DownloadCenterController)
    var attempts = 0
    var delayed: UIViewController?
    center.presentController = { host, controller, _ in
      XCTAssertTrue(host === navigation)
      attempts += 1
      delayed = controller
    }
    center.perform(.files, id: id)
    let picker = try XCTUnwrap(delayed as? UIDocumentPickerViewController)
    try settle()
    XCTAssertEqual(attempts, 1, "A pending request is not a declined presentation")
    XCTAssertTrue(center.actionController === picker)
    XCTAssertTrue(B3DownloadsPresentation.hasPendingAttachment(in: window))
    XCTAssertTrue(catalog.isProtected(id))
    handler.setActive(false)
    handler.setActive(true)
    try settle()
    XCTAssertTrue(root.presentedViewController === navigation)
    XCTAssertTrue(center.actionController === picker)
    XCTAssertNotNil(catalog.presentationOwner)
    XCTAssertFalse(catalog.delete(id))
    self.presentationProbe.present(navigation, picker, {}, acknowledgeOwner: false)
    try presentationProbe.wait(for: picker)
    try waitUntil(diagnostics: handler.presentationState) {
      center.actionController == nil && B3DownloadsPresentation.detached(picker)
        && B3DownloadsPresentation.detached(navigation) && catalog.presentationOwner == nil
    }
    XCTAssertEqual(attempts, 1)
    XCTAssertFalse(B3DownloadsPresentation.hasPendingAttachment(in: window))
    XCTAssertFalse(catalog.isProtected(id))
    XCTAssertNotNil(catalog.completedURL(id: id))
    handler.enqueueCompletedExport(try XCTUnwrap(catalog.completedURL(id: id)))
    try waitUntil {
      handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
    }
    XCTAssertEqual(handler.pendingCount, 1)
  }

  func testFilesRetriesDeclinedPresentationWithoutLosingProtectionOrChoice() throws {
    let probe = NativeModalCompletionProbe()
    let catalog = try catalog()
    let id = try completed(catalog)
    let root = UIViewController()
    let window = try window(root)
    let handler = makeHandler(presenter: root, catalog: catalog)
    defer {
      handler.close()
      try? waitUntil(diagnostics: handler.presentationState) { catalog.presentationOwner == nil }
      try? closeWindow(window)
    }
    handler.presentController = { host, controller, completion in
      probe.present(host, controller, completion, acknowledgeOwner: true)
    }
    handler.showDownloadCenter()
    try waitUntil { root.presentedViewController is UINavigationController }
    let navigation = try XCTUnwrap(root.presentedViewController as? UINavigationController)
    try probe.wait(for: navigation)
    try waitForPresentation(navigation, in: window)
    let center = try XCTUnwrap(navigation.topViewController as? DownloadCenterController)
    var attempts = 0
    var firstPicker: UIViewController?
    center.presentController = { host, controller, completion in
      attempts += 1
      XCTAssertTrue(host === navigation)
      XCTAssertTrue(controller is UIDocumentPickerViewController)
      XCTAssertTrue(catalog.isProtected(id))
      if attempts == 1 {
        firstPicker = controller
        completion()  // Explicit terminal decline, not a delayed request.
        return
      }
      XCTAssertTrue(controller === firstPicker, "Retry retains the same system controller")
      probe.present(host, controller, completion, acknowledgeOwner: false)
    }
    center.perform(.files, id: id)
    try waitUntil { attempts == 2 }
    try probe.wait(for: try XCTUnwrap(firstPicker))
    try waitUntil(diagnostics: handler.presentationState) {
      attempts == 2
        && center.actionController.map(B3DownloadsPresentation.attachedAndSettled) == true
    }
    let picker = try XCTUnwrap(center.actionController as? UIDocumentPickerViewController)
    try waitForPresentation(picker, in: window)
    XCTAssertFalse(catalog.delete(id))
    center.documentPickerWasCancelled(picker)
    try waitUntil { center.actionController == nil && B3DownloadsPresentation.detached(picker) }
    XCTAssertNotNil(catalog.completedURL(id: id))
    XCTAssertFalse(catalog.isProtected(id))
    XCTAssertEqual(attempts, 2)
  }

  func testCenterOpenShareFilesCancellationKeepFileAndRejectStaleCallbacks() throws {
    let probe = NativeModalCompletionProbe()
    for action in [DownloadCenterController.Action.open, .share, .files] {
      let catalog = try catalog()
      let id = try completed(catalog)
      let presenter = UIViewController()
      let window = try window(presenter)
      let handler = makeHandler(presenter: presenter, catalog: catalog)
      defer {
        handler.close()
        try? waitUntil { catalog.presentationOwner == nil }
        try? closeWindow(window)
      }
      handler.presentController = { host, controller, completion in
        probe.present(host, controller, completion, acknowledgeOwner: true)
      }
      handler.showDownloadCenter()
      try waitUntil(diagnostics: handler.presentationState) {
        presenter.presentedViewController is UINavigationController
      }
      let navigation = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
      try probe.wait(for: navigation)
      try waitForPresentation(navigation, in: window)
      let center = try XCTUnwrap(navigation.topViewController as? DownloadCenterController)
      center.presentController = { host, controller, completion in
        // System presentation really runs, but attachment completion is withheld.
        XCTAssertTrue(host === navigation, "Center must call its attached navigation host")
        XCTAssertTrue(window.isKeyWindow, "Files must use the current fixture window")
        probe.present(host, controller, completion, acknowledgeOwner: false)
      }
      center.perform(action, id: id)
      try waitUntil(diagnostics: handler.presentationState) { center.actionController != nil }
      let old = try XCTUnwrap(center.actionController)
      try probe.wait(for: old)
      try waitForPresentation(old, in: window)
      XCTAssertTrue(old.presentingViewController === navigation)
      switch action {
      case .photos: XCTFail("Photos is not a modal action")
      case .open: XCTAssertTrue(old is DownloadPreviewController)
      case .share: XCTAssertTrue(old is UIActivityViewController)
      case .files: XCTAssertTrue(old is UIDocumentPickerViewController)
      }
      let oldPreview = center.actionPreview
      XCTAssertTrue(catalog.isProtected(id))
      XCTAssertFalse(catalog.delete(id))
      if let picker = old as? UIDocumentPickerViewController {
        center.documentPickerWasCancelled(picker)
      } else if let share = old as? UIActivityViewController {
        share.completionWithItemsHandler?(nil, false, nil, nil)
      } else if let preview = oldPreview {
        center.previewControllerDidDismiss(preview)
      }
      try waitUntil(diagnostics: handler.presentationState) {
        center.actionController == nil && B3DownloadsPresentation.detached(old)
          && navigation.presentedViewController == nil && navigation.transitionCoordinator == nil
      }
      XCTAssertTrue(window.isKeyWindow, "Fixture stays alive across disposition")
      XCTAssertNotNil(catalog.completedURL(id: id))
      XCTAssertFalse(catalog.isProtected(id))
      center.perform(.files, id: id)
      try waitUntil { center.actionController is UIDocumentPickerViewController }
      let current = try XCTUnwrap(center.actionController)
      try probe.wait(for: current)
      try waitForPresentation(current, in: window)
      if let picker = old as? UIDocumentPickerViewController {
        center.documentPickerWasCancelled(picker)
      }
      if let share = old as? UIActivityViewController {
        share.completionWithItemsHandler?(nil, false, nil, nil)
      }
      if let container = old as? DownloadPreviewController { container.onClose?() }
      if let preview = oldPreview {
        center.previewControllerDidDismiss(preview)
        XCTAssertEqual(center.numberOfPreviewItems(in: preview), 0)
        XCTAssertNil(center.previewController(preview, previewItemAt: 0).previewItemURL)
      }
      try settle()
      XCTAssertTrue(center.actionController === current)
      handler.setActive(false)
      try waitUntil(diagnostics: handler.presentationState) {
        presenter.presentedViewController == nil && B3DownloadsPresentation.detached(current)
          && B3DownloadsPresentation.detached(navigation) && catalog.presentationOwner == nil
      }
      XCTAssertNotNil(catalog.completedURL(id: id))
    }
  }
  func testPNGActionWaitsForNavigationHostAndSuspensionCancelsDeferredAction() throws {
    let catalog = try catalog()
    let id = try catalog.begin()
    let url = try catalog.destination(id: id, suggested: "fixture.png", expectedBytes: -1)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
    try XCTUnwrap(
      renderer.image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
      }.pngData()
    ).write(to: url)
    _ = try catalog.finish(id: id)
    let root = UIViewController()
    let window = try window(root)
    let handler = makeHandler(presenter: root, catalog: catalog)
    defer {
      handler.close()
      try? waitUntil { catalog.presentationOwner == nil }
      try? closeWindow(window)
    }
    handler.showDownloadCenter()
    try waitUntil(diagnostics: handler.presentationState) {
      root.presentedViewController is UINavigationController
    }
    let navigation = try XCTUnwrap(root.presentedViewController as? UINavigationController)
    try waitForPresentation(navigation, in: window)
    let center = try XCTUnwrap(navigation.topViewController as? DownloadCenterController)
    let choice = UIAlertController(title: "Local fixture", message: nil, preferredStyle: .alert)
    self.presentationProbe.present(navigation, choice, {}, acknowledgeOwner: false)
    try waitForPresentation(choice, in: window)
    center.perform(.open, id: id)
    XCTAssertNil(center.actionController, "A busy navigation host defers the action")
    XCTAssertFalse(catalog.isProtected(id))
    B3DownloadsPresentation.dismiss(choice) {}
    try waitUntil { B3DownloadsPresentation.detached(choice) }
    try waitUntil {
      center.actionController is DownloadPreviewController
        && center.actionController?.presentingViewController === navigation
        && center.actionController?.isBeingPresented == false
    }
    let preview = try XCTUnwrap(center.actionPreview)
    XCTAssertEqual(center.numberOfPreviewItems(in: preview), 1)
    let previewURL = try XCTUnwrap(
      center.previewController(preview, previewItemAt: 0).previewItemURL)
    XCTAssertEqual(previewURL.resolvingSymlinksInPath(), url.resolvingSymlinksInPath())
    XCTAssertNotNil(UIImage(contentsOfFile: previewURL.path))
    let container = try XCTUnwrap(center.actionController as? DownloadPreviewController)
    XCTAssertTrue(container.preview === preview)
    XCTAssertTrue(catalog.isProtected(id))
    XCTAssertFalse(catalog.delete(id))
    XCTAssertNotNil(
      preview.navigationController, "QuickLook receives a public navigation context")
    XCTAssertTrue(preview.navigationController?.parent === container)
    XCTAssertTrue(container.closeButton.window === window)
    XCTAssertFalse(container.closeButton.isHidden)
    XCTAssertTrue(container.closeButton.isEnabled)
    container.closeButton.sendActions(for: .touchUpInside)
    try waitUntil { center.actionController == nil && navigation.presentedViewController == nil }
    XCTAssertNil(container.viewIfLoaded?.window)
    XCTAssertFalse(catalog.isProtected(id))
    let staleChoice = UIAlertController(
      title: "Stale fixture", message: nil, preferredStyle: .alert)
    self.presentationProbe.present(navigation, staleChoice, {}, acknowledgeOwner: false)
    try waitForPresentation(staleChoice, in: window)
    center.perform(.open, id: id)
    XCTAssertNil(center.actionController, "The second busy-host action is still deferred")
    handler.setActive(false)
    handler.setActive(true)
    try waitUntil { root.presentedViewController == nil && catalog.presentationOwner == nil }
    XCTAssertNil(center.actionController)
    XCTAssertFalse(catalog.isProtected(id))
    handler.showDownloadCenter()
    try waitUntil(diagnostics: handler.presentationState) {
      root.presentedViewController is UINavigationController
    }
    try waitForPresentation(try XCTUnwrap(root.presentedViewController), in: window)
    let resumed = try XCTUnwrap(
      (root.presentedViewController as? UINavigationController)?.topViewController
        as? DownloadCenterController)
    resumed.perform(.open, id: id)
    try waitUntil { resumed.actionController is DownloadPreviewController }
    XCTAssertNotNil(catalog.completedURL(id: id))
  }

  func testSuspensionDuringCenterAndPreviewPresentationWaitsForDetachment() throws {
    let catalog = try catalog()
    let id = try completed(catalog)
    for previewInFlight in [false, true, true] {
      let presenter = UIViewController()
      let scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
      let window = try window(presenter)
      let handler = makeHandler(presenter: presenter, catalog: catalog)
      defer {
        handler.close()
        try? waitUntil { catalog.presentationOwner == nil }
        try? closeWindow(window)
      }
      handler.showDownloadCenter()
      let navigation = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
      var preview: UIViewController?
      if previewInFlight {
        try waitForPresentation(navigation, in: window)
        let center = try XCTUnwrap(navigation.topViewController as? DownloadCenterController)
        center.perform(.open, id: id)
        preview = try XCTUnwrap(center.actionController)
        XCTAssertNotNil(preview?.presentingViewController)
        XCTAssertTrue(catalog.isProtected(id))
        XCTAssertFalse(catalog.delete(id))
      }
      // Deliberately do not wait for the new modal's presentation transition.
      handler.setActive(false)
      handler.setActive(true)
      try waitUntil {
        presenter.presentedViewController == nil && navigation.transitionCoordinator == nil
          && preview?.presentingViewController == nil && preview?.viewIfLoaded?.window == nil
          && catalog.presentationOwner == nil
      }
      XCTAssertFalse(catalog.isProtected(id))
      XCTAssertNotNil(catalog.completedURL(id: id))
      handler.close()
      try closeWindow(window)
      XCTAssertNil(window.rootViewController)
      XCTAssertTrue(window.isHidden)
      if let previousKeyWindow, !previousKeyWindow.isHidden {
        XCTAssertTrue(previousKeyWindow.isKeyWindow)
      }
    }
  }

  func testStartupReenforcesByteBoundOnValidOversizedArchive() throws {
    let catalog = try catalog()
    for _ in 0..<4 {
      _ = try completed(catalog, size: UInt64(DownloadCenterCatalog.maximumFileBytes))
    }
    let path = catalog.root.appendingPathComponent("catalog.json")
    var archive = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: NSObject])
    var records = try XCTUnwrap(archive["items"] as? [[String: NSObject]])
    var extra = try XCTUnwrap(records.last)
    let id = UUID()
    extra["id"] = id.uuidString as NSString
    let directory = catalog.root.appendingPathComponent(id.uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let file = directory.appendingPathComponent("fixture.txt")
    try Data().write(to: file)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(DownloadCenterCatalog.maximumFileBytes))
    try handle.close()
    records.append(extra)
    archive["items"] = records as NSArray
    try JSONSerialization.data(withJSONObject: archive).write(to: path)
    let repaired = DownloadCenterCatalog(root: catalog.root)
    XCTAssertEqual(repaired.items.count, 4)
    XCTAssertLessThanOrEqual(repaired.reservedBytes, DownloadCenterCatalog.maximumBytes)
    let files = try FileManager.default.contentsOfDirectory(
      at: repaired.root, includingPropertiesForKeys: nil)
    XCTAssertEqual(files.filter { $0.lastPathComponent != "catalog.json" }.count, 4)
  }

  func testCenterObservesInProgressFailureAndCompletionWithoutStrandingChoice() throws {
    let catalog = try catalog()
    let presenter = UIViewController()
    let window = try window(presenter)
    let handler = makeHandler(presenter: presenter, catalog: catalog)
    defer {
      handler.close()
      try? waitUntil { catalog.presentationOwner == nil }
      try? closeWindow(window)
    }
    handler.showDownloadCenter()
    try waitUntil(diagnostics: handler.presentationState) {
      presenter.presentedViewController is UINavigationController
    }
    let navigation = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
    try waitForPresentation(navigation, in: window)
    let center = try XCTUnwrap(navigation.topViewController as? DownloadCenterController)
    let transferring = try catalog.begin()
    let url = try catalog.destination(id: transferring, suggested: "fixture.txt", expectedBytes: -1)
    XCTAssertEqual(center.tableView.numberOfRows(inSection: 0), 1)
    XCTAssertEqual(
      (center.tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? DownloadRowCell)?
        .detailText,
      "Downloading…")
    let failed = try catalog.begin()
    catalog.fail(id: failed)
    XCTAssertEqual(center.tableView.numberOfRows(inSection: 0), 2)
    try Data("Local fixture".utf8).write(to: url)
    _ = try catalog.finish(id: transferring)
    handler.enqueueCompletedExport(url)
    XCTAssertNil(handler.exportID)
    XCTAssertEqual(handler.pendingCount, 1)
    XCTAssertEqual(catalog.item(transferring)?.status, .completed)
    center.onClose?()
    try waitUntil { handler.exportPresentation is UIAlertController }
    XCTAssertEqual(handler.exporting, url)
  }

  func testConcurrentSameBasenameKeepsSeparateFilesAndCatalogDisposition() throws {
    let catalog = try catalog()
    let first = try completed(catalog, name: "same.png")
    let second = try completed(catalog, name: "same.png")
    let firstURL = try XCTUnwrap(catalog.completedURL(id: first))
    let secondURL = try XCTUnwrap(catalog.completedURL(id: second))
    XCTAssertNotEqual(firstURL, secondURL)
    XCTAssertEqual(firstURL.lastPathComponent, "same.png")
    XCTAssertEqual(secondURL.lastPathComponent, "same.png")
    let presenter = UIViewController()
    let window = try window(presenter)
    let handler = makeHandler(presenter: presenter, catalog: catalog)
    var logs: [String] = []
    handler.onLog = { logs.append($0) }
    defer {
      handler.close()
      try? waitUntil { catalog.presentationOwner == nil }
      try? closeWindow(window)
    }
    handler.enqueueCompletedExport(firstURL)
    handler.enqueueCompletedExport(secondURL)
    try waitUntil { handler.exportID != nil }
    try settle()
    let id = try XCTUnwrap(handler.exportID)
    handler.complete(id: id)
    handler.complete(id: id)
    try waitUntil { handler.exporting == secondURL }
    XCTAssertNotNil(catalog.completedURL(id: first))
    XCTAssertNotNil(catalog.completedURL(id: second))
    XCTAssertEqual(handler.pendingCount, 1)
    handler.close()
    try waitUntil { presenter.presentedViewController == nil }
    XCTAssertTrue(catalog.delete(first))
    XCTAssertNotNil(catalog.completedURL(id: second))
    XCTAssertFalse(logs.joined().contains("same.png"))
    XCTAssertFalse(logs.joined().contains("Local blob fixture"))
    XCTAssertFalse(logs.joined().contains(catalog.root.path))
  }

  func testUnreadableCatalogKeepsExistingFilesAndBlocksAdmission() throws {
    let catalog = try catalog()
    let id = try completed(catalog)
    let file = try XCTUnwrap(catalog.completedURL(id: id))
    let archive = catalog.root.appendingPathComponent("catalog.json")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: archive.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
    }
    let unavailable = DownloadCenterCatalog(root: catalog.root)
    XCTAssertThrowsError(try unavailable.begin())
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
    let readable = DownloadCenterCatalog(root: catalog.root)
    XCTAssertNotNil(readable.completedURL(id: id))
  }

  func testB3CenterActionWaitsForUnrelatedModalWithoutDismissingIt() throws {
    let probe = NativeModalCompletionProbe()
    let catalog = try catalog()
    let id = try completed(catalog)
    let root = UIViewController()
    let window = try window(root)
    let handler = makeHandler(presenter: root, catalog: catalog)
    defer {
      handler.close()
      try? waitUntil { catalog.presentationOwner == nil }
      try? closeWindow(window)
    }
    handler.presentController = { host, controller, completion in
      probe.present(host, controller, completion, acknowledgeOwner: true)
    }
    handler.showDownloadCenter()
    try waitUntil { root.presentedViewController is UINavigationController }
    let navigation = try XCTUnwrap(root.presentedViewController as? UINavigationController)
    try probe.wait(for: navigation)
    try waitForPresentation(navigation, in: window)
    let center = try XCTUnwrap(navigation.topViewController as? DownloadCenterController)
    center.presentController = { host, controller, completion in
      probe.present(host, controller, completion, acknowledgeOwner: true)
    }
    let unrelated = UIViewController()
    navigation.present(unrelated, animated: true, completion: probe.completion(for: unrelated))
    try probe.wait(for: unrelated)
    try waitForPresentation(unrelated, in: window)
    center.perform(.share, id: id)
    try settle()
    XCTAssertTrue(navigation.presentedViewController === unrelated)
    XCTAssertNil(center.actionController)
    let shareCompletion = probe.expectPresentation(of: UIActivityViewController.self)
    unrelated.dismiss(animated: false)
    try probe.wait(for: shareCompletion)
    try waitUntil { center.actionController is UIActivityViewController }
    let share = try XCTUnwrap(center.actionController as? UIActivityViewController)
    try probe.wait(for: share)
    try waitForPresentation(share, in: window)
    XCTAssertTrue(share.presentingViewController === navigation)
    XCTAssertTrue(share.popoverPresentationController?.sourceView === navigation.view)
    XCTAssertTrue(catalog.isProtected(id))
    handler.setActive(false)
    try waitUntil { B3DownloadsPresentation.detached(share) && catalog.presentationOwner == nil }
    XCTAssertNotNil(catalog.completedURL(id: id))
  }

  func testB4ObservedDetachedActionIsRetiredInsteadOfRetriedAsDecline() throws {
    let probe = NativeModalCompletionProbe()
    for action in [DownloadCenterController.Action.files, .share, .open] {
      let catalog = try catalog()
      let id = try completed(catalog)
      let center = DownloadCenterController(catalog: catalog)
      let navigation = UINavigationController(rootViewController: center)
      let root = UIViewController()
      let window = try window(root)
      defer { try? closeWindow(window) }
      root.present(navigation, animated: false, completion: probe.completion(for: navigation))
      try probe.wait(for: navigation)
      try waitForPresentation(navigation, in: window)
      var requests = 0
      var oldModal: UIViewController?
      center.presentController = { host, controller, completion in
        requests += 1
        oldModal = controller
        let completed = probe.completion(for: controller)
        host.present(controller, animated: false) {
          // UIKit completion can precede transition cleanup. Prove actual
          // attachment here; production polling owns the settled-state gate.
          XCTAssertTrue(controller.presentingViewController === host)
          XCTAssertTrue(controller.viewIfLoaded?.window === window)
          XCTAssertTrue(catalog.isProtected(id))
          XCTAssertFalse(catalog.delete(id))
          // Acknowledge a real attachment, then remove it before the poll. This
          // differs from an acknowledged decline that never attached to UIKit.
          completion()
          controller.dismiss(animated: false)
          completed()
        }
      }
      center.perform(action, id: id)
      let modal = try XCTUnwrap(oldModal)
      try probe.wait(for: modal)
      try waitUntil(diagnostics: center.actionPresentationState) {
        B3DownloadsPresentation.detached(modal) && center.actionController == nil
      }
      XCTAssertEqual(requests, 1, "An observed modal must not retry as a rejected request")
      XCTAssertFalse(catalog.isProtected(id))
      XCTAssertNotNil(catalog.completedURL(id: id))
      center.presentController = { host, controller, completion in
        probe.present(host, controller, completion, acknowledgeOwner: false)
      }
      center.perform(.files, id: id)
      let next = try XCTUnwrap(center.actionController as? UIDocumentPickerViewController)
      try probe.wait(for: next)
      try waitForPresentation(next, in: window)
      if let picker = modal as? UIDocumentPickerViewController {
        center.documentPickerWasCancelled(picker)
      }
      (modal as? UIActivityViewController)?.completionWithItemsHandler?(nil, false, nil, nil)
      (modal as? DownloadPreviewController)?.onClose?()
      XCTAssertTrue(center.actionController === next)
      XCTAssertTrue(catalog.isProtected(id))
      center.documentPickerWasCancelled(next)
      try waitUntil { center.actionController == nil && B3DownloadsPresentation.detached(next) }
      XCTAssertFalse(catalog.isProtected(id))
      center.suspendActions()
      navigation.dismiss(animated: false)
      try waitUntil { B3DownloadsPresentation.detached(navigation) }
      try closeWindow(window)
    }
  }

}
