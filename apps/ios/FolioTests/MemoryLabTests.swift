import UIKit
import WebKit
import XCTest

@testable import Folio

@MainActor
final class MemoryLabTests: XCTestCase {
  private func progress(status: String = "success", successful: Int = 8, attempted: Int = 8)
    -> MemoryProgress
  {
    MemoryProgress(
      runID: UUID().uuidString, kind: "wasm", stepMiB: 2,
      limitMiB: status == "limit" ? successful : 16,
      delayMS: 50, timeoutSeconds: 60, touchPages: true, successfulMiB: successful,
      attemptedMiB: attempted, status: status)
  }

  func testRaisedCapRetainsCheckpointsBeyondFourGiB() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("memory.json")
    let p = MemoryProgress(
      runID: UUID().uuidString, kind: "typed-array", stepMiB: 64, limitMiB: 8192,
      delayMS: 100, timeoutSeconds: 300, touchPages: true, successfulMiB: 4096,
      attemptedMiB: 4160, status: "allocating")
    XCTAssertTrue(p.isValid)
    try MemoryLabStore(url: url).append(event: "Memory lab", availableBytes: 123, progress: p)
    let restored = MemoryLabStore(url: url)
    XCTAssertEqual(restored.runs.last?.progress, p)
    let tooLarge = MemoryProgress(
      runID: p.runID, kind: p.kind, stepMiB: p.stepMiB, limitMiB: 8193,
      delayMS: p.delayMS, timeoutSeconds: p.timeoutSeconds, touchPages: true,
      successfulMiB: p.successfulMiB, attemptedMiB: p.attemptedMiB, status: p.status)
    XCTAssertFalse(tooLarge.isValid)
  }

  func testProgressAndTerminationSurviveStoreRecreation() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("memory.json")
    let store = MemoryLabStore(url: url)
    let p = progress(status: "allocating", successful: 8, attempted: 10)
    try store.append(event: "Memory lab", availableBytes: 123, progress: p)
    try store.setNote("90% / 1800 MiB")
    try store.append(event: "WebContent terminated (reason unavailable)", availableBytes: 120)
    try store.interrupt(status: "webcontent-terminated", availableBytes: 120)
    let restored = MemoryLabStore(url: url)
    XCTAssertEqual(restored.note, "90% / 1800 MiB")
    XCTAssertEqual(restored.records.last?.progress?.successfulMiB, 8)
    XCTAssertEqual(restored.records.last?.progress?.attemptedMiB, 10)
    XCTAssertEqual(restored.records.last?.progress?.status, "webcontent-terminated")
    XCTAssertTrue(restored.report.contains("largest successful=8 MiB attempted=10 MiB"))
    XCTAssertTrue(restored.report.contains("reason unavailable"))
    XCTAssertNotNil(restored.records.last?.timestamp)
    try restored.interrupt(status: "app-restarted", availableBytes: 111)
    XCTAssertEqual(restored.records.count, 3)
  }

  func testMeterRejectsTextAndDiscardsLegacyFreeText() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("memory.json")
    let store = MemoryLabStore(url: url)
    try store.setNote("42%")
    for value in ["private typed text", "token=abc", "https://example.com", "42% private title"] {
      XCTAssertThrowsError(try store.setNote(value))
      XCTAssertEqual(store.note, "42%")
      XCTAssertFalse(store.report.contains(value))
    }
    try Data(#"{"records":[],"runs":[],"note":"private typed text"}"#.utf8).write(to: url)
    let restored = MemoryLabStore(url: url)
    XCTAssertEqual(restored.note, "")
    XCTAssertFalse(restored.report.contains("private typed text"))
    try restored.append(event: "Native memory sample", availableBytes: 1)
    XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("private typed text"))
  }

  func testCompletedRunIsNotMarkedAsTerminated() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = MemoryLabStore(url: folder.appendingPathComponent("memory.json"))
    try store.append(event: "Memory lab", availableBytes: 1, progress: progress(status: "limit"))
    try store.interrupt(status: "webcontent-terminated", availableBytes: 1)
    XCTAssertEqual(store.records.count, 1)
  }

  func testFailedWriteDoesNotAcknowledgeOrUpdateProgress() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: folder)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = MemoryLabStore(url: folder.appendingPathComponent("memory.json"))
    XCTAssertThrowsError(
      try store.append(event: "Memory lab", availableBytes: 1, progress: progress()))
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertNotNil(store.persistenceError)
  }

  func testRunSummarySurvivesSampleRingEviction() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("memory.json")
    let store = MemoryLabStore(url: url)
    try store.append(event: "Memory lab", availableBytes: 1, progress: progress(status: "limit"))
    for _ in 0..<501 { try store.append(event: "Native memory sample", availableBytes: 1) }
    let restored = MemoryLabStore(url: url)
    XCTAssertEqual(restored.records.count, 500)
    XCTAssertEqual(restored.runs.last?.progress?.successfulMiB, 8)
    XCTAssertTrue(restored.report.contains("largest successful=8 MiB"))
  }

  func testMemorySchemaRejectsInvalidAndExtraFields() throws {
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(progress())) as? [String: Any])
    XCTAssertNotNil(MemoryLabBridge.validate(object))
    object["status"] = "arbitrary text"
    XCTAssertNil(MemoryLabBridge.validate(object))
    object["status"] = "success"
    object["limitMiB"] = 999999
    XCTAssertNil(MemoryLabBridge.validate(object))
    object["limitMiB"] = 16
    object["successfulMiB"] = 8
    object["attemptedMiB"] = 10
    XCTAssertNil(MemoryLabBridge.validate(object))  // success must confirm the attempted size
    object["status"] = "allocating"
    XCTAssertNotNil(MemoryLabBridge.validate(object))
    object["attemptedMiB"] = 16
    XCTAssertNil(MemoryLabBridge.validate(object))  // cannot skip the configured step
    object["attemptedMiB"] = 10
    object["status"] = "started"
    XCTAssertNil(MemoryLabBridge.validate(object))
    object["status"] = "limit"
    XCTAssertNil(MemoryLabBridge.validate(object))
    object["status"] = "success"
    object["attemptedMiB"] = 8
    object["token"] = "secret"
    XCTAssertNil(MemoryLabBridge.validate(object))
  }

  func testMemoryReplyBridgeAcceptsOnlyCurrentBundledMainFrame() async throws {
    let bridge = MemoryLabBridge()
    let browser = WKWebView(
      frame: .zero,
      configuration: WebViewConfiguration.make(
        mode: .normal, bridge: ScriptBridge(), memoryBridge: bridge))
    bridge.webView = browser
    var received: [MemoryProgress] = []
    bridge.persist = { received.append($0) }
    defer {
      browser.stopLoading()
      browser.configuration.userContentController.removeAllScriptMessageHandlers()
    }
    let url = try XCTUnwrap(MemoryLabBridge.url)
    let navigationCompletion1 = NativeNavigationCompletionProbe(browser)
    browser.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    try await navigationCompletion1.wait()
    for _ in 0..<100 {
      let ready = try? await browser.evaluateJavaScript(
        "document.readyState === 'complete' && !!document.getElementById('start')",
        in: nil, contentWorld: ScriptBridge.world)
      if ready as? Bool == true { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(browser.url, url)
    let p = progress(status: "started", successful: 0, attempted: 0)
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
    let script = """
      try { return await webkit.messageHandlers.memoryProgress.postMessage(payload); }
      catch { return 'rejected'; }
      """
    let accepted = try await browser.callAsyncJavaScript(
      script, arguments: ["payload": body], in: nil, contentWorld: ScriptBridge.world)
    XCTAssertEqual(accepted as? Bool, true)
    XCTAssertEqual(received, [p])
    // The same isolated-world API must reject a network document, even with a valid payload.
    let navigationCompletion2 = NativeNavigationCompletionProbe(browser)
    browser.loadHTMLString("<p>Network fixture</p>", baseURL: URL(string: "https://example.com"))
    try await navigationCompletion2.wait()
    var networkReady = false
    for _ in 0..<100 {
      let ready = try? await browser.evaluateJavaScript(
        "location.protocol === 'https:' && document.readyState === 'complete'",
        in: nil, contentWorld: ScriptBridge.world)
      if ready as? Bool == true {
        networkReady = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(networkReady)
    let rejected = try await browser.callAsyncJavaScript(
      script, arguments: ["payload": body], in: nil, contentWorld: ScriptBridge.world)
    XCTAssertEqual(rejected as? String, "rejected")
    XCTAssertEqual(received, [p])
    let safe = WebViewConfiguration.make(
      mode: .safe, bridge: ScriptBridge(), memoryBridge: bridge)
    XCTAssertTrue(safe.userContentController.userScripts.isEmpty)
  }

  func testNativeWarningAndRecoveryBannerUsePersistedEvents() {
    let controller = FigmaWebViewController()
    controller.loadViewIfNeeded()
    NotificationCenter.default.post(
      name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    let afterWarning = MemoryLabStore()
    XCTAssertTrue(afterWarning.records.contains { $0.event == "UIApplication memory warning" })
    controller.webViewWebContentProcessDidTerminate(controller.webView)
    // Check native labels through the view tree, without generating a real process death.
    func texts(_ view: UIView) -> [String] {
      var values: [String] = []
      if let label = view as? UILabel, let text = label.text { values.append(text) }
      if let button = view as? UIButton, let text = button.title(for: .normal) {
        values.append(text)
      }
      return values + view.subviews.flatMap(texts)
    }
    // Home recovers quietly until its bounded retry allowance is exhausted.
    XCTAssertEqual(controller.tabSession.kind, .home)
    XCTAssertTrue(controller.tabSession.backgroundRecoveryAllowed)
    XCTAssertNil(controller.recoveryBanner)
    controller.webViewWebContentProcessDidTerminate(controller.webView)
    controller.webViewWebContentProcessDidTerminate(controller.webView)
    XCTAssertTrue(
      texts(controller.view).contains("The page stopped repeatedly. Automatic reload paused."))
    XCTAssertTrue(texts(controller.view).contains("Reload"))
    XCTAssertTrue(texts(controller.view).contains("Safe mode"))
    XCTAssertTrue(
      MemoryLabStore().records.contains { $0.event == "WebContent terminated (reason unavailable)" }
    )
  }

  func testRollingCrashWindowCountsBlockedCrashesAndExactBoundary() {
    var recovery = ProcessRecovery()
    XCTAssertTrue(recovery.shouldReload(now: 0))
    XCTAssertTrue(recovery.shouldReload(now: 10))
    XCTAssertFalse(recovery.shouldReload(now: 119))
    XCTAssertFalse(recovery.shouldReload(now: 120))
    XCTAssertFalse(recovery.shouldReload(now: 130))
    XCTAssertTrue(recovery.shouldReload(now: 251))
  }
}
