import UIKit
import WebKit
import XCTest

@testable import Folio

@MainActor
private final class DownloadFixtureWebView: WKWebView {
  // The actual host executes its routing/containment path, with no network request.
  override func load(_ request: URLRequest) -> WKNavigation? { nil }
}

@MainActor
final class DownloadLifecycleTests: XCTestCase {
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

  private func window(presenter: UIViewController) throws -> UIWindow {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = presenter
    window.makeKeyAndVisible()
    fixtureWindows.append(window)
    windowCleanup[ObjectIdentifier(window)] = { [weak self] in
      guard let self else { return }
      do {
        try self.waitUntil {
          let modal = presenter.presentedViewController
          return presenter.transitionCoordinator == nil
            && !presenter.isBeingPresented && !presenter.isBeingDismissed
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

  private func file(catalog: DownloadCenterCatalog) throws -> URL {
    let directory = catalog.root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("private-name.txt")
    try Data("Local export fixture".utf8).write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return url
  }

  private func b3PNG(catalog: DownloadCenterCatalog) throws -> URL {
    let id = try catalog.begin()
    let url = try catalog.destination(
      id: id, suggested: "B3Downloads-fixture.png", expectedBytes: -1)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160))
    let data = try XCTUnwrap(
      renderer.image { context in
        UIColor(red: 23 / 255, green: 105 / 255, blue: 224 / 255, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 160))
        UIColor(red: 1, green: 158 / 255, blue: 36 / 255, alpha: 1).setFill()
        context.fill(CGRect(x: 80, y: 0, width: 80, height: 160))
      }.pngData())
    try data.write(to: url)
    return try catalog.finish(id: id)
  }

  private func fixtureCatalog() -> DownloadCenterCatalog {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return DownloadCenterCatalog(root: root)
  }

  private enum WaitError: Error {
    case timedOut
  }

  // Keep XCTest's entry points synchronous. On iPadOS 27 the async throwing
  // entry points aborted in XCTSwiftErrorObservation / _swift_task_dealloc_specific.
  // XCTWaiter pumps the main run loop so UIKit and the handler's tasks still run.
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
      let settled = XCTestExpectation(description: "Export lifecycle settled")
      let probe = presentationProbe
      let windows = fixtureWindows
      let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
        let finished = MainActor.assumeIsolated {
          condition() || probe.hasPending
            || NativeModalCompletionProbe.hasTransitions(in: windows)
        }
        if finished {
          timer.invalidate()
          settled.fulfill()
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      defer { timer.invalidate() }
      guard XCTWaiter.wait(for: [settled], timeout: 3) == .completed else {
        XCTFail("Export lifecycle did not settle: " + diagnostics(), file: file, line: line)
        throw WaitError.timedOut
      }
    }
  }
  private func runMainLoop(for interval: TimeInterval) throws {
    try presentationProbe.waitForPending()
    try NativeModalCompletionProbe.waitForTransitions(in: fixtureWindows)
    // Deliberate duplicate/stale-callback observation interval after UIKit completion.
    let elapsed = XCTestExpectation(description: "Main run loop advanced")
    DispatchQueue.main.asyncAfter(deadline: .now() + interval) { elapsed.fulfill() }
    guard XCTWaiter.wait(for: [elapsed], timeout: interval + 3) == .completed else {
      throw WaitError.timedOut
    }
  }

  func testSuspensionPreservesFileAndRejectsStaleCompletion() throws {
    let presenter = UIViewController()
    _ = try window(presenter: presenter)
    let handler = makeHandler(presenter: presenter, catalog: fixtureCatalog())
    defer {
      handler.close()
    }
    let url = try file(catalog: handler.catalog)
    handler.enqueueCompletedExport(url)
    try waitUntil { presenter.presentedViewController != nil }
    let oldID = try XCTUnwrap(handler.exportID)
    handler.setActive(false)
    try waitUntil { presenter.presentedViewController == nil }
    XCTAssertNil(handler.exportID)
    XCTAssertEqual(handler.pendingCount, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    handler.setActive(true)
    try waitUntil { handler.exportID != nil }
    let newID = try XCTUnwrap(handler.exportID)
    XCTAssertNotEqual(oldID, newID)
    handler.complete(id: oldID)
    handler.chooseFiles(id: oldID)
    XCTAssertEqual(handler.exportID, newID)
    XCTAssertEqual(handler.pendingCount, 1)
    handler.close()
    handler.complete(id: newID)
    XCTAssertEqual(handler.pendingCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testFilesAndShareDismissalCannotCompleteResumedExport() throws {
    for files in [true, false] {
      let presenter = UIViewController()
      let window = try window(presenter: presenter)
      let handler = makeHandler(presenter: presenter, catalog: fixtureCatalog())
      let probe = NativeModalCompletionProbe()
      handler.presentController = { host, controller, completion in
        probe.present(host, controller, completion, acknowledgeOwner: true)
      }
      defer {
        handler.close()
        try? waitUntil(diagnostics: handler.presentationState) {
          presenter.presentedViewController == nil && presenter.transitionCoordinator == nil
        }
        try? closeWindow(window)
      }
      let url = try file(catalog: handler.catalog)
      handler.enqueueCompletedExport(url)
      try waitUntil { presenter.presentedViewController != nil }
      // Let the initial UIKit presentation finish before exercising its dismissal.
      try runMainLoop(for: 0.4)
      let oldID = try XCTUnwrap(handler.exportID)
      print("Before choice: " + handler.presentationState)
      if files { handler.chooseFiles(id: oldID) } else { handler.chooseShare(id: oldID) }
      print("After choice: " + handler.presentationState)
      try waitUntil(diagnostics: handler.presentationState) {
        files
          ? handler.exportPresentation is UIDocumentPickerViewController
          : handler.exportPresentation is UIActivityViewController
      }
      let oldSheet = try XCTUnwrap(handler.exportPresentation)
      try probe.wait(for: oldSheet)
      try waitUntil(diagnostics: handler.presentationState) {
        oldSheet.presentingViewController != nil && oldSheet.viewIfLoaded?.window === window
          && !oldSheet.isBeingPresented && oldSheet.transitionCoordinator == nil
      }
      print("System sheet attached: " + handler.presentationState)
      handler.setActive(false)
      try waitUntil { presenter.presentedViewController == nil }
      handler.setActive(true)
      try waitUntil { handler.exportID != nil }
      let newID = try XCTUnwrap(handler.exportID)
      XCTAssertNotEqual(oldID, newID)
      if let picker = oldSheet as? UIDocumentPickerViewController {
        handler.documentPickerWasCancelled(picker)
        handler.documentPicker(picker, didPickDocumentsAt: [])
      } else if let share = oldSheet as? UIActivityViewController {
        share.completionWithItemsHandler?(nil, false, nil, nil)
        try runMainLoop(for: 0.1)
      }
      handler.complete(id: oldID)
      XCTAssertEqual(handler.exportID, newID)
      XCTAssertEqual(handler.pendingCount, 1)
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
      // Finish UIKit dismissal before destroying the key window or starting Share.
      handler.close()
      try waitUntil(diagnostics: handler.presentationState) {
        presenter.presentedViewController == nil && presenter.transitionCoordinator == nil
      }
    }
  }

  func testUserDismissalCompletesOnceAndAdvancesQueue() throws {
    let presenter = UIViewController()
    _ = try window(presenter: presenter)
    let handler = makeHandler(presenter: presenter, catalog: fixtureCatalog())
    let probe = NativeModalCompletionProbe()
    handler.presentController = { host, controller, completion in
      probe.present(host, controller, completion, acknowledgeOwner: true)
    }
    defer {
      handler.close()
    }
    let first = try file(catalog: handler.catalog)
    let second = try file(catalog: handler.catalog)
    handler.enqueueCompletedExport(first)
    handler.enqueueCompletedExport(second)
    try waitUntil { handler.exportID != nil }
    try runMainLoop(for: 0.4)
    let firstID = try XCTUnwrap(handler.exportID)
    handler.chooseFiles(id: firstID)
    try waitUntil { handler.exportPresentation is UIDocumentPickerViewController }
    let picker = try XCTUnwrap(handler.exportPresentation as? UIDocumentPickerViewController)
    try probe.wait(for: picker)
    let presentation = try XCTUnwrap(picker.presentationController)
    try waitUntil(diagnostics: handler.presentationState) {
      B3DownloadsPresentation.attachedAndSettled(picker)
    }
    picker.dismiss(animated: false)
    try waitUntil(diagnostics: handler.presentationState) {
      B3DownloadsPresentation.detached(picker)
    }
    handler.presentationControllerDidDismiss(presentation)
    try waitUntil { handler.exportID != nil && handler.exportID != firstID }
    let secondID = try XCTUnwrap(handler.exportID)
    handler.documentPickerWasCancelled(picker)
    handler.presentationControllerDidDismiss(presentation)
    handler.complete(id: firstID)
    XCTAssertEqual(handler.exportID, secondID)
    XCTAssertEqual(handler.exporting, second)
    XCTAssertEqual(handler.pendingCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
  }

  func testDelayedFilesCancellationAfterObservedDetachmentCannotRequeueFirstIdentity() throws {
    let presenter = UIViewController()
    _ = try window(presenter: presenter)
    let handler = makeHandler(presenter: presenter, catalog: fixtureCatalog())
    defer { handler.close() }
    let first = try file(catalog: handler.catalog)
    let second = try file(catalog: handler.catalog)
    handler.enqueueCompletedExport(first)
    handler.enqueueCompletedExport(second)
    try waitUntil {
      handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
    }
    let firstID = try XCTUnwrap(handler.exportID)
    let probe = NativeModalCompletionProbe()
    var acknowledgement: (() -> Void)?
    handler.presentController = { host, controller, completion in
      acknowledgement = completion
      probe.present(host, controller, completion, acknowledgeOwner: false)
    }
    handler.chooseFiles(id: firstID)
    try waitUntil { handler.exportPresentation is UIDocumentPickerViewController }
    let picker = try XCTUnwrap(handler.exportPresentation as? UIDocumentPickerViewController)
    // UIKit readiness is separate from the owner acknowledgement deliberately
    // withheld below. System Files presentation can exceed the state deadline.
    try probe.wait(for: picker)
    let pickerAcknowledgement = try XCTUnwrap(acknowledgement)
    let presentation = try XCTUnwrap(picker.presentationController)
    try waitUntil(diagnostics: handler.presentationState) {
      B3DownloadsPresentation.attachedAndSettled(picker)
    }
    picker.dismiss(animated: false)
    try waitUntil { B3DownloadsPresentation.detached(picker) }
    // Run the attachment/dismissal observer before any user delegate delivery.
    handler.presentNext()
    try waitUntil(diagnostics: handler.presentationState) {
      handler.exporting == second && handler.exportID != firstID
        && handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
    }
    let secondID = try XCTUnwrap(handler.exportID)
    // Queue advancement invokes the seam again. Keep the first picker's callback
    // rather than accidentally acknowledging the successor choice.
    pickerAcknowledgement()
    handler.documentPickerWasCancelled(picker)
    handler.presentationControllerDidDismiss(presentation)
    handler.documentPicker(picker, didPickDocumentsAt: [])
    handler.complete(id: firstID)
    try runMainLoop(for: 0.2)
    XCTAssertEqual(handler.exportID, secondID)
    XCTAssertEqual(handler.exporting, second)
    XCTAssertEqual(handler.pendingCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
  }

  func testSwitchDuringChoiceDismissalResumesWithoutOpeningStalePicker() throws {
    let presenter = UIViewController()
    _ = try window(presenter: presenter)
    let handler = makeHandler(presenter: presenter, catalog: fixtureCatalog())
    defer {
      handler.close()
    }
    let url = try file(catalog: handler.catalog)
    handler.enqueueCompletedExport(url)
    try waitUntil { presenter.presentedViewController != nil }
    try runMainLoop(for: 0.4)
    let oldID = try XCTUnwrap(handler.exportID)
    handler.chooseFiles(id: oldID)
    handler.setActive(false)
    handler.setActive(true)
    try waitUntil { handler.exportID != nil && handler.exportID != oldID }
    XCTAssertTrue(handler.exportPresentation is UIAlertController)
    XCTAssertEqual(handler.pendingCount, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  func testControllerSwitchRebuildAndCloseNotifyDownloadOwner() throws {
    let previousCatalog = DownloadCenterCatalog.fixtureOverride
    DownloadCenterCatalog.fixtureOverride = fixtureCatalog()
    defer { DownloadCenterCatalog.fixtureOverride = previousCatalog }
    let controller = FigmaWebViewController(fixtureNumber: 0)
    _ = try window(presenter: controller)
    defer {
      controller.closeTab()
    }
    let url = try file(catalog: controller.downloads.catalog)
    controller.downloads.enqueueCompletedExport(url)
    try waitUntil { controller.downloads.exportID != nil }
    try runMainLoop(for: 0.4)
    let firstID = try XCTUnwrap(controller.downloads.exportID)
    controller.setTabActive(false)
    try waitUntil { controller.presentedViewController == nil }
    XCTAssertNil(controller.downloads.exportID)
    XCTAssertEqual(controller.downloads.pendingCount, 1)
    controller.setTabActive(true)
    try waitUntil { controller.downloads.exportID != nil }
    try runMainLoop(for: 0.4)
    let secondID = try XCTUnwrap(controller.downloads.exportID)
    XCTAssertNotEqual(firstID, secondID)
    let oldWebView = controller.webView
    controller.rebuildWebView()
    XCTAssertFalse(oldWebView === controller.webView)
    try waitUntil {
      controller.downloads.exportID != nil && controller.downloads.exportID != secondID
    }
    XCTAssertEqual(controller.downloads.pendingCount, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    controller.closeTab()
    try waitUntil { controller.presentedViewController == nil }
    XCTAssertEqual(controller.downloads.pendingCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertTrue(controller.isViewLoaded)
    XCTAssertNil(controller.webView)
    // A retired controller can still receive input cleanup and transport callbacks.
    controller.releaseTouchShortcuts()
    var scriptCompletions = 0
    controller.runScriptWithCompletion("void 0") { scriptCompletions += 1 }
    XCTAssertEqual(scriptCompletions, 1)
    controller.closeTab()
    XCTAssertNil(controller.webView)
    XCTAssertEqual(controller.downloads.pendingCount, 0)
  }

  func testCloseCancelsActiveDownloadAndIgnoresLateCallbacks() throws {
    let browser = WKWebView()
    let url = try XCTUnwrap(URL(string: "data:text/plain;base64,Rm9saW8="))
    let started = XCTestExpectation(description: "WebKit download started")
    var receivedDownload: WKDownload?
    browser.startDownload(using: URLRequest(url: url)) { download in
      receivedDownload = download
      started.fulfill()
    }
    guard XCTWaiter.wait(for: [started], timeout: 3) == .completed else {
      throw WaitError.timedOut
    }
    let download = try XCTUnwrap(receivedDownload)
    let presenter = UIViewController()
    let handler = makeHandler(presenter: presenter, catalog: fixtureCatalog())
    var logs: [String] = []
    handler.onLog = { logs.append($0) }
    handler.accept(download)
    handler.setActive(false)
    XCTAssertEqual(handler.pendingCount, 1, "Deactivation must retain active transfers")
    var destination: URL?
    handler.download(
      download, decideDestinationUsing: URLResponse(), suggestedFilename: "private-name.txt"
    ) { destination = $0 }
    let target = try XCTUnwrap(destination)
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path))
    handler.close()
    handler.close()
    XCTAssertNil(download.delegate)
    XCTAssertEqual(handler.pendingCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path))
    handler.downloadDidFinish(download)
    handler.download(
      download, didFailWithError: NSError(domain: "test", code: 1), resumeData: Data())
    handler.accept(download)
    handler.setActive(true)
    XCTAssertEqual(handler.pendingCount, 0)
    XCTAssertNil(handler.exportPresentation)
    XCTAssertEqual(logs.filter { !$0.hasPrefix("Download ownership ") }, ["Download started"])
    XCTAssertFalse(logs.joined().contains("private-name.txt"))
    XCTAssertFalse(logs.joined().contains(handler.catalog.root.path))
  }

  func testCloseRemovesInactiveQueueAndRejectsFutureFiles() throws {
    let presenter = UIViewController()
    let handler = makeHandler(presenter: presenter, catalog: fixtureCatalog())
    handler.setActive(false)
    let first = try file(catalog: handler.catalog)
    handler.enqueueCompletedExport(first)
    handler.close()
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    let late = try file(catalog: handler.catalog)
    handler.enqueueCompletedExport(late)
    XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
    XCTAssertEqual(handler.pendingCount, 0)
  }
  func testActualHostDetachmentWithMissingDismissalCompletionResumesEverySheet() throws {
    try actualHostSourceReturn(
      lifecycleNotification: false, completionProbe: NativeModalCompletionProbe())
  }

  func testExternalDeliveryReturnsExactSourceAfterSceneActivationNotificationIsOmitted() throws {
    try actualHostSourceReturn(
      lifecycleNotification: true, completionProbe: NativeModalCompletionProbe())
  }

  func testExactSourceReturnAtBothInterfaceZoomExtremes() throws {
    for preset in [InterfaceZoomPreset.half, .double] {
      try actualHostSourceReturn(
        lifecycleNotification: true, preset: preset, completionProbe: NativeModalCompletionProbe())
    }
  }

  private func actualHostSourceReturn(
    lifecycleNotification: Bool, preset: InterfaceZoomPreset = .actual,
    completionProbe: NativeModalCompletionProbe? = nil
  ) throws {
    let previousCatalog = DownloadCenterCatalog.fixtureOverride
    DownloadCenterCatalog.fixtureOverride = fixtureCatalog()
    defer { DownloadCenterCatalog.fixtureOverride = previousCatalog }
    for state in ["choice", "files", "share", "preview"] {
      let suite = "DownloadHost-" + UUID().uuidString
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let host = BrowserWindowController(
        useFixture: true, defaults: defaults,
        makeWebView: {
          DownloadFixtureWebView(frame: .zero, configuration: $0)
        })
      // Mirror the production presentation ancestry, including the app zoom
      // container. A bare BrowserWindowController cannot catch forwarding bugs.
      let zoom = InterfaceZoomStore(defaults: defaults)
      zoom.send(.preset(preset))
      let container = InterfaceZoomContainerController(
        store: zoom, makeBrowser: { _ in host })
      let window = try window(presenter: container)
      let source = try XCTUnwrap(host.children.compactMap { $0 as? FigmaWebViewController }.first)
      let sourceID = host.session.selectedID
      zoom.registerMainWebView(source.webView)
      XCTAssertEqual(source.webView.transform.a, preset.rawValue)
      let handler = source.downloads
      var choices = 0
      handler.onLog = { if $0 == "Export choice presented" { choices += 1 } }
      // Real presentation, deliberately no completion. Every state must recover
      // using its UIKit attachment rather than a callback from the removed source.
      handler.presentController = { host, controller, completion in
        if let completionProbe {
          completionProbe.present(host, controller, completion, acknowledgeOwner: false)
        } else {
          self.presentationProbe.present(host, controller, {}, acknowledgeOwner: false)
        }
      }
      defer {
        source.closeTab()
        try? waitUntil(diagnostics: handler.presentationState) {
          container.presentedViewController == nil && container.transitionCoordinator == nil
        }
        try? closeWindow(window)
      }
      let url = try b3PNG(catalog: handler.catalog)
      handler.enqueueCompletedExport(url)
      try waitUntil { handler.exportID != nil }
      if let completionProbe {
        try completionProbe.wait(for: try XCTUnwrap(handler.exportPresentation))
        try waitUntil {
          handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
        }
      } else {
        try runMainLoop(for: 0.4)
      }
      let oldID = try XCTUnwrap(handler.exportID)
      let deliveryCompletion: XCTestExpectation?
      if state == "files" {
        deliveryCompletion = completionProbe?.expectPresentation(
          of: UIDocumentPickerViewController.self)
      } else if state == "share" {
        deliveryCompletion = completionProbe?.expectPresentation(of: UIActivityViewController.self)
      } else {
        deliveryCompletion = nil
      }
      if state == "files" { handler.chooseFiles(id: oldID) }
      if state == "share" { handler.chooseShare(id: oldID) }
      if state == "files" || state == "share" {
        if let completionProbe, let deliveryCompletion {
          try completionProbe.wait(for: deliveryCompletion)
        }
        try waitUntil {
          state == "files"
            ? handler.exportPresentation is UIDocumentPickerViewController
            : handler.exportPresentation is UIActivityViewController
        }
        if let completionProbe {
          try completionProbe.wait(for: try XCTUnwrap(handler.exportPresentation))
        } else {
          try runMainLoop(for: 0.4)
        }
      }
      var oldCenter: DownloadCenterController?
      var oldNavigation: UINavigationController?
      if state == "preview" {
        handler.showDownloadCenter()
        if let completionProbe {
          try waitUntil { container.presentedViewController is UINavigationController }
          try completionProbe.wait(for: try XCTUnwrap(container.presentedViewController))
        }
        try waitUntil(diagnostics: handler.presentationState) {
          container.presentedViewController is UINavigationController
            && container.presentedViewController?.transitionCoordinator == nil
        }
        let navigation = try XCTUnwrap(container.presentedViewController as? UINavigationController)
        let center = try XCTUnwrap(navigation.topViewController as? DownloadCenterController)
        center.presentController = { host, controller, completion in
          if let completionProbe {
            completionProbe.present(host, controller, completion, acknowledgeOwner: false)
          } else {
            self.presentationProbe.present(host, controller, {}, acknowledgeOwner: false)
          }
        }
        center.perform(.open, id: try XCTUnwrap(handler.catalog.id(for: url)))
        if let completionProbe {
          try completionProbe.wait(for: try XCTUnwrap(center.actionController))
        }
        try waitUntil {
          center.actionController?.viewIfLoaded?.window === window
            && center.actionController?.isBeingPresented == false
            && center.actionController?.transitionCoordinator == nil
        }
        oldCenter = center
        oldNavigation = navigation
      }
      let oldModal = try XCTUnwrap(oldCenter?.actionController ?? handler.exportPresentation)
      try waitUntil(diagnostics: handler.presentationState) {
        oldModal.presentingViewController != nil && oldModal.viewIfLoaded?.window === window
          && !oldModal.isBeingPresented && oldModal.transitionCoordinator == nil
      }
      let fileID = try XCTUnwrap(handler.catalog.id(for: url))
      XCTAssertTrue(handler.catalog.isProtected(fileID))
      // Real UIKit dismissal with deliberately withheld completion. The production
      // modal relationship must unblock resumption even when that callback is absent.
      handler.dismissController = { controller, _ in controller.dismiss(animated: false) }
      if lifecycleNotification {
        NotificationCenter.default.post(
          name: UIScene.willDeactivateNotification, object: window.windowScene)
      } else {
        handler.setForeground(false)
      }
      // Dashboard links select Home. Use a document route to exercise source detachment.
      host.openExternalLink(
        try XCTUnwrap(URL(string: "https://www.figma.com/design/DownloadDestination")))
      let destination = try XCTUnwrap(
        host.children.compactMap { $0 as? FigmaWebViewController }.first)
      defer { destination.closeTab() }
      XCTAssertNotEqual(host.session.selectedID, sourceID)
      XCTAssertEqual(host.session.selected.kind, .document)
      XCTAssertFalse(source.parent === host)
      XCTAssertNil(handler.exportID)
      XCTAssertEqual(handler.pendingCount, 1)
      XCTAssertNil(destination.downloads.exportID)
      if !lifecycleNotification { handler.setForeground(true) }
      XCTAssertNil(handler.exportID, "Foreground must not select the source")
      try waitUntil(diagnostics: handler.presentationState) {
        B3DownloadsPresentation.detached(oldModal)
          && oldNavigation.map(B3DownloadsPresentation.detached) != false
          && container.presentedViewController == nil
          && handler.catalog.presentationOwner == nil
      }
      XCTAssertTrue(handler.catalog.isProtected(fileID), "Source queue protects the retained file")
      XCTAssertNotNil(handler.catalog.completedURL(id: fileID))
      let choicesBeforeReturn = choices
      host.session.select(sourceID)
      host.showSelectedTab(ownerSelection: true)
      XCTAssertEqual(host.session.selectedID, sourceID)
      XCTAssertTrue(source.parent === host)
      XCTAssertTrue(source.downloads === handler)
      if let completionProbe {
        try waitUntil {
          handler.exportPresentation is UIAlertController && handler.exportID != oldID
        }
        try completionProbe.wait(for: try XCTUnwrap(handler.exportPresentation))
      }
      try waitUntil(diagnostics: handler.presentationState) {
        handler.exportPresentation is UIAlertController && handler.exportID != oldID
          && handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
      }
      let resumedID = try XCTUnwrap(handler.exportID)
      XCTAssertEqual(choices, choicesBeforeReturn + 1)
      XCTAssertEqual(handler.exporting, url)
      XCTAssertEqual(handler.pendingCount, 1)
      handler.complete(id: oldID)
      if let picker = oldModal as? UIDocumentPickerViewController {
        handler.documentPickerWasCancelled(picker)
      }
      if let share = oldModal as? UIActivityViewController {
        share.completionWithItemsHandler?(nil, false, nil, nil)
      }
      if let preview = oldModal as? DownloadPreviewController { preview.onClose?() }
      oldCenter?.onClose?()  // A retired list must not close a successor Center.
      try runMainLoop(for: 0.1)
      XCTAssertEqual(handler.exportID, resumedID)
      XCTAssertEqual(choices, choicesBeforeReturn + 1)
      XCTAssertTrue(handler.catalog.isProtected(fileID))
      XCTAssertFalse(handler.catalog.delete(fileID))
      handler.complete(id: resumedID)
      if let oldCenter {
        handler.showDownloadCenter()
        if let completionProbe {
          try waitUntil { container.presentedViewController is UINavigationController }
          try completionProbe.wait(for: try XCTUnwrap(container.presentedViewController))
        }
        try waitUntil(diagnostics: handler.presentationState) {
          container.presentedViewController is UINavigationController
            && container.presentedViewController?.transitionCoordinator == nil
        }
        let currentNavigation = try XCTUnwrap(
          container.presentedViewController as? UINavigationController)
        let currentCenter = try XCTUnwrap(
          currentNavigation.topViewController as? DownloadCenterController)
        oldCenter.onClose?()
        try runMainLoop(for: 0.2)
        XCTAssertTrue(container.presentedViewController === currentNavigation)
        currentCenter.onClose?()
        try waitUntil { handler.catalog.presentationOwner == nil }
      }
      let second = try file(catalog: handler.catalog)
      handler.enqueueCompletedExport(second)
      if let completionProbe {
        try waitUntil {
          handler.exporting == second && handler.exportPresentation is UIAlertController
        }
        try completionProbe.wait(for: try XCTUnwrap(handler.exportPresentation))
      }
      try waitUntil {
        handler.exporting == second && handler.exportPresentation is UIAlertController
          && handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
      }
      XCTAssertEqual(handler.pendingCount, 1)
      handler.complete(id: try XCTUnwrap(handler.exportID))
      try waitUntil { handler.pendingCount == 0 && handler.catalog.presentationOwner == nil }
      XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }
  }

  func testChoiceDismissalCompletionCannotPresentInsideUIKitCallback() throws {
    let presenter = UIViewController()
    _ = try window(presenter: presenter)
    let handler = makeHandler(presenter: presenter, catalog: fixtureCatalog())
    defer {
      handler.close()
    }
    let probe = NativeModalCompletionProbe()
    handler.presentController = { host, controller, completion in
      probe.present(host, controller, completion, acknowledgeOwner: true)
    }
    handler.enqueueCompletedExport(try file(catalog: handler.catalog))
    try waitUntil { handler.exportPresentation is UIAlertController }
    try probe.wait(for: try XCTUnwrap(handler.exportPresentation))
    try waitUntil {
      handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
    }
    var staleCompletion: (() -> Void)?
    handler.dismissController = { [weak handler] controller, completion in
      controller.dismiss(animated: false) {
        staleCompletion = completion
        completion()
        XCTAssertNil(
          handler?.exportPresentation, "Do not attach a successor inside dismiss completion")
      }
    }
    handler.chooseFiles(id: try XCTUnwrap(handler.exportID))
    try waitUntil(diagnostics: handler.presentationState) {
      handler.exportPresentation is UIDocumentPickerViewController
    }
    let pendingPicker = try XCTUnwrap(handler.exportPresentation)
    handler.setActive(false)
    handler.setActive(true)
    try probe.wait(for: pendingPicker)
    try waitUntil { handler.exportPresentation is UIAlertController }
    try probe.wait(for: try XCTUnwrap(handler.exportPresentation))
    let current = handler.exportID
    staleCompletion?()
    XCTAssertEqual(handler.exportID, current)
    XCTAssertTrue(handler.exportPresentation is UIAlertController)
  }

  func testDuplicateQueueAndRapidActivationRejectOldRetryAndCompletion() throws {
    let presenter = UIViewController()
    _ = try window(presenter: presenter)
    let handler = makeHandler(presenter: presenter, catalog: fixtureCatalog())
    defer {
      handler.close()
    }
    handler.setActive(false)
    let url = try file(catalog: handler.catalog)
    handler.enqueueCompletedExport(url)
    handler.enqueueCompletedExport(url)
    XCTAssertEqual(handler.pendingCount, 1)
    handler.setActive(true)
    try waitUntil { handler.exportID != nil }
    try runMainLoop(for: 0.4)
    let stale = try XCTUnwrap(handler.exportID)
    for _ in 0..<5 {
      handler.setActive(false)
      handler.setActive(true)
    }
    try waitUntil { handler.exportID != nil && handler.exportID != stale }
    let current = handler.exportID
    handler.complete(id: stale)
    handler.chooseShare(id: stale)
    try runMainLoop(for: 0.4)
    XCTAssertEqual(handler.exportID, current)
    XCTAssertEqual(handler.pendingCount, 1)
    handler.close()
    handler.close()
    handler.setActive(true)
    try runMainLoop(for: 0.2)
    XCTAssertNil(handler.exportID)
    XCTAssertEqual(handler.pendingCount, 0)
  }

  func testB3ForegroundSuspensionBeforeExternalRouteRejectsSystemCompletion() throws {
    let presenter = UIViewController()
    let window = try window(presenter: presenter)
    let catalog = fixtureCatalog()
    let handler = makeHandler(presenter: presenter, catalog: catalog)
    let probe = NativeModalCompletionProbe()
    handler.presentController = { host, controller, completion in
      probe.present(host, controller, completion, acknowledgeOwner: true)
    }
    defer {
      handler.close()
      try? waitUntil(diagnostics: handler.presentationState) { catalog.presentationOwner == nil }
      try? closeWindow(window)
    }
    let url = try b3PNG(catalog: catalog)
    let fileID = try XCTUnwrap(catalog.id(for: url))
    handler.enqueueCompletedExport(url)
    try waitUntil {
      handler.exportPresentation?.transitionCoordinator == nil && handler.exportID != nil
    }
    let oldID = try XCTUnwrap(handler.exportID)
    let shareCompletion = probe.expectPresentation(of: UIActivityViewController.self)
    handler.chooseShare(id: oldID)
    try probe.wait(for: shareCompletion)
    try waitUntil(diagnostics: handler.presentationState) {
      handler.exportPresentation is UIActivityViewController
        && handler.exportPresentation?.viewIfLoaded?.window === window
        && handler.exportPresentation?.transitionCoordinator == nil
    }
    let share = try XCTUnwrap(handler.exportPresentation as? UIActivityViewController)
    NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
    handler.setActive(true)  // Browser appearance must not undo foreground suspension.
    share.completionWithItemsHandler?(nil, false, nil, nil)
    try waitUntil { B3DownloadsPresentation.detached(share) }
    XCTAssertNil(handler.exportID)
    XCTAssertEqual(handler.pendingCount, 1)
    XCTAssertTrue(catalog.isProtected(fileID))
    handler.setActive(false)  // External destination takes selected-tab ownership.
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    try runMainLoop(for: 0.2)
    XCTAssertNil(handler.exportID)
    handler.setActive(true)
    try waitUntil(diagnostics: handler.presentationState) {
      handler.exportPresentation is UIAlertController
    }
    let resumed = try XCTUnwrap(handler.exportID)
    XCTAssertNotEqual(oldID, resumed)
    handler.complete(id: oldID)
    share.completionWithItemsHandler?(nil, false, nil, nil)
    try runMainLoop(for: 0.1)
    XCTAssertEqual(handler.exportID, resumed)
    XCTAssertEqual(handler.pendingCount, 1)
    XCTAssertFalse(catalog.delete(fileID))
  }

  func testDelayedSystemAttachmentKeepsOwnershipThroughSuspensionAndClose() throws {
    for files in [true, false] {
      for closeBeforeAttachment in [false, true] {
        let presenter = UIViewController()
        let root = UIViewController()
        root.addChild(presenter)
        root.view.addSubview(presenter.view)
        presenter.view.frame = root.view.bounds
        presenter.didMove(toParent: root)
        let window = try window(presenter: root)
        presenter.view.frame = root.view.bounds
        let catalog = fixtureCatalog()
        let handler = makeHandler(presenter: presenter, catalog: catalog)
        defer {
          handler.close()
          try? closeWindow(window)
        }
        let url = try b3PNG(catalog: catalog)
        let fileID = try XCTUnwrap(catalog.id(for: url))
        handler.enqueueCompletedExport(url)
        try waitUntil {
          handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
        }
        let oldID = try XCTUnwrap(handler.exportID)
        var requests = 0
        var delayed: UIViewController?
        var delayedHost: UIViewController?
        handler.presentController = { host, controller, _ in
          requests += 1
          delayed = controller
          delayedHost = host
        }
        if files { handler.chooseFiles(id: oldID) } else { handler.chooseShare(id: oldID) }
        try waitUntil { delayed != nil }
        let modal = try XCTUnwrap(delayed)
        XCTAssertTrue(
          files ? modal is UIDocumentPickerViewController : modal is UIActivityViewController)
        try runMainLoop(for: 0.45)  // Several former 100 ms duplicate-request deadlines.
        XCTAssertTrue(handler.exportPresentation === modal)
        XCTAssertEqual(handler.exportID, oldID)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(B3DownloadsPresentation.hasPendingAttachment(in: window))
        XCTAssertTrue(catalog.isProtected(fileID))
        if closeBeforeAttachment { handler.close() } else { handler.setActive(false) }
        presenter.willMove(toParent: nil)
        presenter.view.removeFromSuperview()
        presenter.removeFromParent()
        XCTAssertNil(presenter.parent)
        try runMainLoop(for: 0.3)
        XCTAssertNotNil(catalog.presentationOwner)
        XCTAssertTrue(catalog.isProtected(fileID))
        XCTAssertEqual(handler.pendingCount, closeBeforeAttachment ? 0 : 1)
        self.presentationProbe.present(
          try XCTUnwrap(delayedHost), modal, {}, acknowledgeOwner: false)
        try presentationProbe.wait(for: modal)
        try waitUntil(diagnostics: handler.presentationState) {
          B3DownloadsPresentation.detached(modal) && catalog.presentationOwner == nil
        }
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(B3DownloadsPresentation.hasPendingAttachment(in: window))
        if closeBeforeAttachment {
          XCTAssertFalse(catalog.isProtected(fileID))
          continue
        }
        handler.presentController = { host, controller, completion in
          self.presentationProbe.present(host, controller, completion, acknowledgeOwner: true)
        }
        root.addChild(presenter)
        root.view.addSubview(presenter.view)
        presenter.view.frame = root.view.bounds
        presenter.didMove(toParent: root)
        handler.setActive(true)
        try waitUntil {
          handler.exportPresentation is UIAlertController
            && handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
        }
        let resumed = try XCTUnwrap(handler.exportID)
        XCTAssertNotEqual(resumed, oldID)
        handler.complete(id: oldID)
        if let picker = modal as? UIDocumentPickerViewController {
          handler.documentPickerWasCancelled(picker)
        }
        if let share = modal as? UIActivityViewController {
          share.completionWithItemsHandler?(nil, false, nil, nil)
        }
        try runMainLoop(for: 0.1)
        XCTAssertEqual(handler.exportID, resumed)
        XCTAssertEqual(handler.exporting, url)
        XCTAssertEqual(handler.pendingCount, 1)
        handler.complete(id: resumed)
        let second = try file(catalog: catalog)
        handler.enqueueCompletedExport(second)
        try waitUntil {
          handler.exporting == second
            && handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
        }
        XCTAssertEqual(handler.pendingCount, 1)
      }
    }
  }

  func testDeclinedChoicePresentationRequeuesOnceAndSecondExportWorks() throws {
    let root = UIViewController()
    let window = try window(presenter: root)
    let catalog = fixtureCatalog()
    let handler = makeHandler(presenter: root, catalog: catalog)
    defer {
      handler.close()
      try? waitUntil(diagnostics: handler.presentationState) { catalog.presentationOwner == nil }
      try? closeWindow(window)
    }
    var attempts = 0
    handler.presentController = { host, controller, completion in
      attempts += 1
      if attempts == 1 {
        completion()
        return
      }
      self.presentationProbe.present(host, controller, {}, acknowledgeOwner: false)
    }
    let first = try b3PNG(catalog: catalog)
    handler.enqueueCompletedExport(first)
    let staleID = try XCTUnwrap(handler.exportID)
    try waitUntil(diagnostics: handler.presentationState) {
      handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
    }
    let resumedID = try XCTUnwrap(handler.exportID)
    XCTAssertNotEqual(staleID, resumedID)
    XCTAssertEqual(handler.exporting, first)
    XCTAssertEqual(handler.pendingCount, 1)
    handler.complete(id: staleID)
    XCTAssertEqual(handler.exportID, resumedID)
    handler.complete(id: resumedID)
    let second = try file(catalog: catalog)
    handler.enqueueCompletedExport(second)
    try waitUntil(diagnostics: handler.presentationState) {
      handler.exporting == second
        && handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
    }
    XCTAssertEqual(handler.pendingCount, 1)
    XCTAssertEqual(attempts, 3)
    XCTAssertNotNil(catalog.completedURL(id: try XCTUnwrap(catalog.id(for: first))))
  }

  func testB3ClosedHandlerKeepsRetirementAliveUntilItsModalDetaches() throws {
    let presenter = UIViewController()
    let window = try window(presenter: presenter)
    let catalog = fixtureCatalog()
    let url = try b3PNG(catalog: catalog)
    let fileID = try XCTUnwrap(catalog.id(for: url))
    var handler: DownloadHandler? = makeHandler(presenter: presenter, catalog: catalog)
    weak let retiredHandler = handler
    handler?.enqueueCompletedExport(url)
    let modal = try XCTUnwrap(handler?.exportPresentation)
    XCTAssertNotNil(modal.presentingViewController)
    // Close during presentation and release the tab's last strong reference.
    // The retirement, not the removed browser, must own the file/presentation.
    handler?.close()
    handler = nil
    if !B3DownloadsPresentation.detached(modal) {
      XCTAssertNotNil(retiredHandler)
      XCTAssertTrue(catalog.isProtected(fileID))
      XCTAssertFalse(catalog.delete(fileID))
    }
    try waitUntil {
      B3DownloadsPresentation.detached(modal) && catalog.presentationOwner == nil
        && retiredHandler == nil
    }
    XCTAssertFalse(catalog.isProtected(fileID))
    XCTAssertNotNil(catalog.completedURL(id: fileID))
    let unrelated = UIViewController()
    presenter.present(unrelated, animated: false)
    try waitUntil {
      unrelated.presentingViewController != nil && unrelated.viewIfLoaded?.window === window
    }
    XCTAssertTrue(presenter.presentedViewController === unrelated)
    try closeWindow(window)
  }

  func testB4ChoiceSourceContainmentReturn() throws {
    try b4SourceContainmentReturn(state: "choice")
  }

  func testB4ShareSourceContainmentReturn() throws {
    try b4SourceContainmentReturn(state: "share")
  }

  func testB4FilesSourceContainmentReturn() throws {
    try b4SourceContainmentReturn(state: "files", completionProbe: NativeModalCompletionProbe())
  }

  func testB4QuickLookSourceContainmentReturn() throws {
    try b4SourceContainmentReturn(state: "preview")
  }

  private func b4SourceContainmentReturn(
    state: String, completionProbe: NativeModalCompletionProbe? = nil
  ) throws {
    // Run the real child/ancestor presentation path both with normal suspension
    // and with ancestor detachment that omits the source activity/dismiss callback.
    // The latter is a separate production regression, not a test readiness change.
    for notifySource in [true, false] {
      let root = UIViewController()
      let ancestor = UIViewController()
      let source = UIViewController()
      let destination = UIViewController()
      root.addChild(ancestor)
      root.view.addSubview(ancestor.view)
      ancestor.view.frame = root.view.bounds
      ancestor.didMove(toParent: root)
      ancestor.addChild(source)
      ancestor.view.addSubview(source.view)
      source.view.frame = ancestor.view.bounds
      source.didMove(toParent: ancestor)
      let window = try window(presenter: root)
      root.view.layoutIfNeeded()
      ancestor.view.frame = root.view.bounds
      source.view.frame = ancestor.view.bounds
      let catalog = fixtureCatalog()
      let handler = makeHandler(presenter: source, catalog: catalog)
      defer {
        handler.close()
        try? waitUntil(diagnostics: handler.presentationState) {
          catalog.presentationOwner == nil
        }
        try? closeWindow(window)
      }
      // Native presentations, no completion acknowledgement. Real relationships
      // must certify attachment and retirement, including the forwarded root.
      handler.presentController = { host, controller, completion in
        if let completionProbe {
          completionProbe.present(host, controller, completion, acknowledgeOwner: false)
        } else {
          self.presentationProbe.present(host, controller, {}, acknowledgeOwner: false)
        }
      }
      let url = try b3PNG(catalog: catalog)
      let fileID = try XCTUnwrap(catalog.id(for: url))
      handler.enqueueCompletedExport(url)
      if let completionProbe {
        try waitUntil { handler.exportPresentation is UIAlertController }
        try completionProbe.wait(for: try XCTUnwrap(handler.exportPresentation))
      }
      try waitUntil(diagnostics: handler.presentationState) {
        handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
      }
      let oldID = try XCTUnwrap(handler.exportID)
      let filesCompletion = completionProbe?.expectPresentation(
        of: UIDocumentPickerViewController.self)
      if state == "share" { handler.chooseShare(id: oldID) }
      if state == "files" { handler.chooseFiles(id: oldID) }
      var oldCenter: DownloadCenterController?
      var oldNavigation: UINavigationController?
      if state == "preview" {
        handler.showDownloadCenter()
        try waitUntil {
          root.presentedViewController is UINavigationController
            && root.presentedViewController.map(B3DownloadsPresentation.attachedAndSettled) == true
        }
        let navigation = try XCTUnwrap(root.presentedViewController as? UINavigationController)
        let center = try XCTUnwrap(navigation.topViewController as? DownloadCenterController)
        center.presentController = { host, controller, _ in
          self.presentationProbe.present(host, controller, {}, acknowledgeOwner: false)
        }
        center.perform(.open, id: fileID)
        oldCenter = center
        oldNavigation = navigation
      }
      if let completionProbe, let filesCompletion {
        try completionProbe.wait(for: filesCompletion)
        try waitUntil { handler.exportPresentation is UIDocumentPickerViewController }
        try completionProbe.wait(for: try XCTUnwrap(handler.exportPresentation))
      }
      try waitUntil(diagnostics: handler.presentationState) {
        let modal = oldCenter?.actionController ?? handler.exportPresentation
        let expected: Bool
        switch state {
        case "share": expected = modal is UIActivityViewController
        case "files": expected = modal is UIDocumentPickerViewController
        case "preview": expected = modal is DownloadPreviewController
        default: expected = modal is UIAlertController
        }
        return expected && modal.map(B3DownloadsPresentation.attachedAndSettled) == true
      }
      let oldModal = try XCTUnwrap(oldCenter?.actionController ?? handler.exportPresentation)
      XCTAssertTrue(root.presentedViewController === (oldNavigation ?? oldModal))
      XCTAssertTrue(catalog.isProtected(fileID))
      XCTAssertFalse(catalog.delete(fileID))
      let owner = try XCTUnwrap(catalog.presentationOwner)
      if notifySource {
        handler.setForeground(false)
        handler.setActive(false)
      }
      source.willMove(toParent: nil)
      source.view.removeFromSuperview()
      source.removeFromParent()
      ancestor.addChild(destination)
      ancestor.view.addSubview(destination.view)
      destination.view.frame = ancestor.view.bounds
      destination.didMove(toParent: ancestor)
      XCTAssertNil(source.parent)
      XCTAssertTrue(destination.parent === ancestor)
      XCTAssertFalse(source === destination)
      // Observe containment loss while the owned modal is still attached. Removing
      // a child does not itself certify modal detachment or release file protection.
      try runMainLoop(for: 0.2)
      if !B3DownloadsPresentation.detached(oldModal) {
        XCTAssertEqual(catalog.presentationOwner, owner)
        XCTAssertTrue(catalog.isProtected(fileID))
      }
      if !notifySource {
        // UIKit ancestor retirement, without DownloadHandler's completion/delegate.
        // The exact observed modal must be retired rather than treated as pending.
        root.dismiss(animated: false)
      }
      try waitUntil(diagnostics: handler.presentationState) {
        B3DownloadsPresentation.detached(oldModal)
          && oldNavigation.map(B3DownloadsPresentation.detached) != false
          && root.presentedViewController == nil && catalog.presentationOwner == nil
      }
      XCTAssertNil(handler.exportID)
      XCTAssertEqual(handler.pendingCount, 1)
      XCTAssertEqual(catalog.completedURL(id: fileID), url)
      XCTAssertTrue(catalog.isProtected(fileID))
      let unrelated = UIViewController()
      unrelated.modalPresentationStyle = .pageSheet
      root.present(unrelated, animated: false)
      try waitUntil { B3DownloadsPresentation.attachedAndSettled(unrelated) }
      destination.willMove(toParent: nil)
      destination.view.removeFromSuperview()
      destination.removeFromParent()
      ancestor.addChild(source)
      ancestor.view.addSubview(source.view)
      source.view.frame = ancestor.view.bounds
      source.didMove(toParent: ancestor)
      handler.setActive(true)
      if notifySource {
        try runMainLoop(for: 0.2)
        XCTAssertNil(handler.exportID, "Selection must not override scene suspension")
        handler.setForeground(true)
        handler.setForeground(true)  // Same-state wakeup must not double consume.
      }
      try runMainLoop(for: 0.2)
      XCTAssertTrue(root.presentedViewController === unrelated)
      XCTAssertNil(handler.exportID, "The source queue cannot dismiss an unrelated modal")
      XCTAssertEqual(handler.pendingCount, 1)
      unrelated.dismiss(animated: false)
      try waitUntil { B3DownloadsPresentation.detached(unrelated) }
      if let completionProbe {
        try waitUntil { handler.exportPresentation is UIAlertController }
        try completionProbe.wait(for: try XCTUnwrap(handler.exportPresentation))
      }
      try waitUntil(diagnostics: handler.presentationState) {
        handler.exportPresentation is UIAlertController
          && handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
      }
      let resumedID = try XCTUnwrap(handler.exportID)
      let resumedChoice = try XCTUnwrap(handler.exportPresentation)
      XCTAssertNotEqual(resumedID, oldID)
      XCTAssertEqual(handler.exporting, url)
      XCTAssertEqual(handler.pendingCount, 1)
      XCTAssertTrue(root.presentedViewController === resumedChoice)
      handler.complete(id: oldID)
      handler.chooseFiles(id: oldID)
      if let picker = oldModal as? UIDocumentPickerViewController {
        handler.documentPickerWasCancelled(picker)
      }
      if let share = oldModal as? UIActivityViewController {
        share.completionWithItemsHandler?(nil, false, nil, nil)
      }
      (oldModal as? DownloadPreviewController)?.onClose?()
      oldCenter?.onClose?()
      try runMainLoop(for: 0.2)
      XCTAssertEqual(handler.exportID, resumedID)
      XCTAssertTrue(handler.exportPresentation === resumedChoice)
      XCTAssertFalse(catalog.delete(fileID))
      handler.complete(id: resumedID)  // Cancellation keeps the retained PNG.
      try waitUntil { B3DownloadsPresentation.detached(resumedChoice) }
      XCTAssertEqual(catalog.completedURL(id: fileID), url)
      let second = try b3PNG(catalog: catalog)
      handler.enqueueCompletedExport(second)
      if let completionProbe {
        try waitUntil { handler.exporting == second && handler.exportPresentation != nil }
        try completionProbe.wait(for: try XCTUnwrap(handler.exportPresentation))
      }
      try waitUntil(diagnostics: handler.presentationState) {
        handler.exporting == second
          && handler.exportPresentation.map(B3DownloadsPresentation.attachedAndSettled) == true
      }
      XCTAssertEqual(handler.pendingCount, 1)
      handler.complete(id: try XCTUnwrap(handler.exportID))
      try waitUntil { catalog.presentationOwner == nil }
      XCTAssertEqual(handler.pendingCount, 0)
      try closeWindow(window)
    }
  }

}
