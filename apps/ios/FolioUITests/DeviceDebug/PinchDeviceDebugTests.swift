import XCTest

// Never runs in normal suites. Reuses only the exact named automation scratch file.
@MainActor
final class PinchDeviceDebugTests: XCTestCase {
  override func setUpWithError() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["FOLIO_DEVICE_DEBUG"] == "1",
      "Requires TEST_RUNNER_FOLIO_DEVICE_DEBUG=1 and a cabled iPad")
    continueAfterFailure = false
  }

  private func openScratch() -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "app.foliodesign.folio")
    app.launchArguments = ["--pinch-harness"]
    app.launchEnvironment["FOLIO_SOURCE_REVISION"] =
      ProcessInfo.processInfo.environment["FOLIO_SOURCE_REVISION"] ?? "unrecorded"
    app.launch()
    app.buttons["tab-0"].tap()
    let scratch = app.buttons["Folio automation (safe to delete), Design file"]
    XCTAssertTrue(
      scratch.waitForExistence(timeout: 20), "Create the named automation scratch before this test")
    sleep(4)
    scratch.doubleTap()
    XCTAssertTrue(app.buttons["File"].waitForExistence(timeout: 20))
    sleep(3)
    app.buttons["File"].tap()
    return app
  }

  func testInspectScratchZoomControls() {
    let app = openScratch()
    defer { app.buttons["tab-1"].tap() }
    let zoom = app.otherElements.matching(
      NSPredicate(format: "label CONTAINS %@", "zoom and view options")
    ).firstMatch
    XCTAssertTrue(zoom.waitForExistence(timeout: 10))
    zoom.tap()
    sleep(1)
    print("PINCH_ZOOM_UI_BEGIN\n\(app.debugDescription)\nPINCH_ZOOM_UI_END")
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "pinch-scratch-zoom-menu"
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testReplayRoutes() {
    let app = openScratch()
    defer { app.buttons["tab-1"].tap() }
    let movementOnly = ProcessInfo.processInfo.environment["FOLIO_PINCH_MOVEMENT_ONLY"] == "1"
    let cases: [(String, [String])] = [
      (
        "wheel",
        ["map-10", "map-25", "map-50", "map-100", "map+25", "out-hold", "flick", "slow-in"]
      ),
      ("gesture", ["out-hold", "flick", "slow-in"]),
    ]
    for (route, names) in cases {
      for name in names where !movementOnly || !name.hasPrefix("map") {
        let zoom = app.otherElements.matching(
          NSPredicate(format: "label CONTAINS %@", "zoom and view options")
        ).firstMatch
        zoom.tap()
        XCTAssertTrue(app.menuItems["Zoom to 100%"].waitForExistence(timeout: 3))
        app.menuItems["Zoom to 100%"].tap()
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "pinch-before-\(route)-\(name)"
        before.lifetime = .keepAlways
        add(before)
        app.buttons["pinch-replay-\(route)"].tap()
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 3))
        app.buttons[name].tap()
        let status = app.staticTexts["pinch-harness-status"]
        let complete = NSPredicate(format: "label == %@", "Complete \(route) \(name)")
        XCTAssertEqual(
          XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: complete, object: status)], timeout: 12),
          .completed)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "pinch-\(route)-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
      }
    }
  }
  func testCreateScratchAnchorRectangle() {
    let app = openScratch()
    defer { app.buttons["tab-1"].tap() }
    app.buttons["Scratch drawing setup"].tap()
    let rectangle = app.switches["Rectangle"]
    XCTAssertTrue(rectangle.waitForExistence(timeout: 10))
    rectangle.tap()
    let canvas = app.webViews.firstMatch.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    canvas.press(forDuration: 0.05, thenDragTo: canvas.withOffset(CGVector(dx: 100, dy: 100)))
    if app.switches["Move"].exists { app.switches["Move"].tap() }
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "pinch-anchor-rectangle-setup"
    shot.lifetime = .keepAlways
    add(shot)
  }

}
