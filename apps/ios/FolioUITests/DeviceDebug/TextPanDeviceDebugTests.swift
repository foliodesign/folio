import XCTest

// Explicit local device-debug sequence. Never activates an unknown owner page.
@MainActor
final class TextPanDeviceDebugTests: XCTestCase {
  override func setUpWithError() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["FOLIO_DEVICE_DEBUG"] == "1",
      "Requires TEST_RUNNER_FOLIO_DEVICE_DEBUG=1 and a cabled iPad")
    continueAfterFailure = false
  }

  func testB2InputLocalFocusObservationSequence() {
    let app = XCUIApplication(bundleIdentifier: "app.foliodesign.folio")
    app.launchArguments = ["--focus-lab", "--focus-logging"]
    app.launch()
    defer { app.terminate() }
    let field = app.textFields["Small focus field"]
    XCTAssertTrue(field.waitForExistence(timeout: 20))
    app.buttons["Open diagnostics"].tap()
    let reset = app.buttons["Reset focus switches"]
    for _ in 0..<6 {
      if reset.isHittable { break }
      app.scrollViews["b2InputDiagnosticsScroll"].swipeUp()
    }
    XCTAssertTrue(reset.isHittable)
    reset.tap()
    app.buttons["Close"].tap()
    b2InputWait(app.staticTexts["Folio diagnostics"], "exists == false")
    b2InputWait(field, "exists == true AND hittable == true")
    b2InputAttachGeometry(app, name: "before-local-focus")
    field.tap()
    field.typeText("b2inputlocalprobe")
    b2InputWait(field, "value == 'b2inputlocalprobe'")
    b2InputAttachGeometry(app, name: "after-local-focus")
    app.buttons["Open diagnostics"].tap()
    let report = app.textViews["diagnosticsReport"]
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    let metadata = report.value as? String ?? ""
    XCTAssertFalse(metadata.contains("b2inputlocalprobe"))
    XCTAssertTrue(metadata.contains("JS focus"))
    let attachment = XCTAttachment(string: metadata)
    attachment.name = "B2Input-local-focus-metadata"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.buttons["Close"].tap()
    b2InputWait(app.staticTexts["Folio diagnostics"], "exists == false")
    b2InputWait(field, "exists == true AND hittable == true")
    b2InputAttachGeometry(app, name: "after-local-close")
    // This fixture need not reproduce the owner's jump or physical keyboard geometry.
  }

  private func b2InputAttachGeometry(_ app: XCUIApplication, name: String) {
    let status = app.staticTexts["focusGeometry"]
    XCTAssertTrue(status.waitForExistence(timeout: 5))
    let attachment = XCTAttachment(string: status.label)
    attachment.name = "B2Input-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func b2InputWait(_ element: XCUIElement, _ predicate: String) {
    let condition = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: predicate), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 10), .completed)
  }
}
