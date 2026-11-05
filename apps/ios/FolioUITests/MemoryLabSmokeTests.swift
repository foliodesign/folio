import XCTest

@MainActor
final class MemoryLabSmokeTests: XCTestCase {
  func testDeviceChecklistControlsAndLabRouting() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--memory-lab"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Folio memory lab"].waitForExistence(timeout: 20))
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "memory-lab-controls"
    tree.lifetime = .keepAlways
    add(tree)
    XCTAssertTrue(app.buttons["Start"].isHittable)
    XCTAssertFalse(app.buttons["Stop"].isEnabled)
    app.buttons["Open diagnostics"].tap()
    for title in [
      "Normal", "Compatibility", "Safe", "Return to Figma", "Reload memory lab",
      "Copy report", "Refresh capture", "Close",
    ] {
      XCTAssertTrue(app.buttons[title].isHittable, title)
    }
    XCTAssertTrue(app.textFields["Figma memory meter"].isHittable)
    XCTAssertTrue(app.switches["Input logging"].isHittable)
    XCTAssertTrue(app.switches["Native verdict: pen drag unusable"].isHittable)
    for title in ["Pencil double-tap", "Pencil squeeze"] {
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.tap()
      for action in ["Log only", "Open diagnostics", "Toggle input logging"] {
        XCTAssertTrue(app.buttons[action].exists)
      }
      app.buttons["Log only"].tap()
    }
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    // A UI action waits for rotation to settle and refreshes the changed viewport capture.
    app.buttons["Refresh capture"].tap()
    XCTAssertTrue(app.buttons["Copy report"].isHittable)
    XCTAssertTrue(app.buttons["Close"].isHittable)
    let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    landscape.name = "diagnostics-landscape-controls"
    landscape.lifetime = .keepAlways
    add(landscape)
    XCUIDevice.shared.orientation = .portrait
    app.buttons["Return to Figma"].tap()
    app.buttons["Open diagnostics"].tap()
    let report = app.textViews["diagnosticsReport"]
    XCTAssertTrue((report.value as? String)?.contains("Page: Network browser") == true)
    app.buttons["Safe"].tap()
    XCTAssertFalse(app.buttons["Memory lab"].isEnabled)
    XCTAssertFalse(app.buttons["Input lab"].isEnabled)
    app.buttons["Normal"].tap()
    app.buttons["Input lab"].tap()
    XCTAssertTrue(app.staticTexts["Folio input lab"].waitForExistence(timeout: 20))
    app.buttons["Open diagnostics"].tap()
    app.buttons["Memory lab"].tap()
    XCTAssertTrue(app.staticTexts["Folio memory lab"].waitForExistence(timeout: 20))
  }

  func testTypedArrayAndWasmPersistAfterRelaunch() {
    continueAfterFailure = false
    let app = XCUIApplication()
    for wasm in [false, true] {
      app.launchArguments =
        ["--memory-lab", "--memory-smoke", "--smoke-report"] + (wasm ? ["--wasm-smoke"] : [])
      app.launch()
      XCTAssertTrue(app.staticTexts["Folio memory lab"].waitForExistence(timeout: 20))
      let completion = app.staticTexts.matching(
        NSPredicate(
          format:
            "label CONTAINS 'largest successful 8 MiB' AND label CONTAINS 'limit. Saved natively.'")
      ).firstMatch
      XCTAssertTrue(completion.waitForExistence(timeout: 15))
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = wasm ? "memory-wasm-8MiB" : "memory-typed-array-8MiB"
      shot.lifetime = .keepAlways
      add(shot)
      app.terminate()
    }
    app.launchArguments = ["--memory-lab", "--smoke-report"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Folio memory lab"].waitForExistence(timeout: 20))
    app.buttons["Open diagnostics"].tap()
    let report = app.textViews["diagnosticsReport"]
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    let value = report.value as? String ?? ""
    XCTAssertTrue(value.contains("typed-array largest successful=8 MiB"))
    XCTAssertTrue(value.contains("wasm largest successful=8 MiB"))
    XCTAssertTrue(value.contains("status=limit"))
    XCTAssertTrue(value.contains("NOT WebContent memory"))
    let note = app.textFields["Figma memory meter"]
    note.tap()
    note.typeText(
      String(repeating: XCUIKeyboardKey.delete.rawValue, count: (note.value as? String ?? "").count)
        + "42%")
    XCTAssertTrue(
      (report.value as? String)?.contains("Figma memory meter (owner note): 42%") == true)
    app.buttons["Reload memory lab"].tap()
    XCTAssertTrue(app.staticTexts["Folio memory lab"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons["Start"].isEnabled)
    app.buttons["Open diagnostics"].tap()
    XCTAssertEqual(app.textFields["Figma memory meter"].value as? String, "42%")
    XCTAssertTrue((report.value as? String)?.contains("wasm largest successful=8 MiB") == true)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "memory-persisted-diagnostics"
    shot.lifetime = .keepAlways
    add(shot)
  }
}
