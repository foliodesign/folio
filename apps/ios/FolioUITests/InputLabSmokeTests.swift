import XCTest

@MainActor
final class InputLabSmokeTests: XCTestCase {
  func testBundledLabTouchDragTextAndDiagnostics() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--input-lab", "--smoke-report", "--browser-readiness"]
    app.launch()
    defer { app.terminate() }
    let title = app.staticTexts["Folio input lab"]
    XCTAssertTrue(title.waitForExistence(timeout: 20))
    app.buttons["Open diagnostics"].tap()
    app.switches["Input logging"].tap()
    app.buttons["Close"].tap()
    let box = app.staticTexts["Pointer capture box"]
    XCTAssertTrue(box.exists)
    let start = box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = start.withOffset(CGVector(dx: 120, dy: 40))
    let originalFrame = box.frame
    start.press(forDuration: 0.1, thenDragTo: end)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Pointer pointerup; box'"))
        .firstMatch.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(box.frame.minX - originalFrame.minX, 80)
    XCTAssertGreaterThan(box.frame.minY - originalFrame.minY, 20)
    let canvas = app.webViews.firstMatch.coordinate(
      withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
    canvas.press(forDuration: 0.1, thenDragTo: canvas.withOffset(CGVector(dx: 170, dy: 30)))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "lab-touch-drag"
    shot.lifetime = .keepAlways
    add(shot)
    let field = app.textFields["Test text field"]
    for _ in 0..<4 {
      if field.isHittable { break }
      // The retained M4 hierarchy keeps the field below y=1402 after four center swipes.
      // The visible draw/drag arena has touch-action:none. Use the page's empty margin,
      // outside canvas, arena and inner scroll region, for this page-scroll gesture.
      let browser = app.webViews.firstMatch
      let start = browser.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.85))
        .withOffset(CGVector(dx: 6, dy: 0))
      let end = browser.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.2))
        .withOffset(CGVector(dx: 6, dy: 0))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND hittable == true"), object: field)
    let result = XCTWaiter.wait(for: [ready], timeout: 5)
    if result != .completed {
      let evidence = XCTAttachment(
        string:
          "\(app.buttons["Open diagnostics"].value ?? "unreturned")\nfield=\(field.frame) browser=\(app.webViews.firstMatch.frame) keyboards=\(app.keyboards.count)\n\(app.debugDescription)"
      )
      evidence.name = "input-field-readiness-hierarchy"
      evidence.lifetime = .keepAlways
      add(evidence)
      let image = XCTAttachment(screenshot: app.screenshot())
      image.name = "input-field-readiness"
      image.lifetime = .keepAlways
      add(image)
    }
    XCTAssertEqual(result, .completed)
    field.tap()
    field.typeText("privacyprobe")
    let completeInput = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "privacyprobe"), object: field)
    XCTAssertEqual(XCTWaiter.wait(for: [completeInput], timeout: 5), .completed)
    XCTAssertEqual(field.value as? String, "privacyprobe")
    let marker = app.staticTexts["Text input event received, value not logged"]
    let received = marker.waitForExistence(timeout: 5)
    if !received {
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "input-marker-failure"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
    }
    XCTAssertTrue(received)
    app.buttons["Open diagnostics"].tap()
    let report = app.textViews["diagnosticsReport"]
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    XCTAssertTrue((report.value as? String)?.contains("Page: Bundled input lab") == true)
    XCTAssertTrue((report.value as? String)?.contains("Pencil tests: NOT TESTED") == true)
    app.buttons["Close"].tap()
    app.swipeDown()
    app.buttons["Open diagnostics"].tap()
    app.buttons["Refresh capture"].tap()
    // Refresh capture returns asynchronously through the WebKit bridge.
    expectation(
      for: NSPredicate(
        format: "value CONTAINS %@ AND value CONTAINS %@",
        "Native type=direct", "JS pointerdown pointer=touch trusted=true"),
      evaluatedWith: report)
    waitForExpectations(timeout: 10)
    XCTAssertTrue((report.value as? String)?.contains("Native type=direct") == true)
    XCTAssertTrue(
      (report.value as? String)?.contains("JS pointerdown pointer=touch trusted=true") == true)
    app.buttons["Copy report"].tap()
    XCTAssertTrue((report.value as? String)?.contains("key=<char>") == true)
    XCTAssertFalse((report.value as? String)?.contains("privacyprobe") == true)
    let diagnostics = XCTAttachment(screenshot: app.screenshot())
    diagnostics.name = "lab-diagnostics"
    diagnostics.lifetime = .keepAlways
    add(diagnostics)
  }
  func testRuntimeStrategiesRestoreAndLabVerdictsReachReport() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--input-lab", "--smoke-report", "--browser-readiness"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["Folio input lab"].waitForExistence(timeout: 20))
    app.buttons["Open diagnostics"].tap()
    let report = app.textViews["diagnosticsReport"]
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pencil strategy:'")).firstMatch
      .tap()
    app.buttons["pencil-gesture-reroute [Tier 2 WEBKIT_INTERNAL]"].tap()
    XCTAssertTrue(
      (report.value as? String)?.contains("pencil-gesture-reroute [Tier 2 WEBKIT_INTERNAL]") == true
    )
    XCTAssertFalse(
      (report.value as? String)?.contains("WEBKIT_INTERNAL changed recognizers: 0") == true)
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Finger pan:'")).firstMatch.tap()
    app.buttons["finger-pan-canvas [Tier 2 WEBKIT_INTERNAL]"].tap()
    XCTAssertTrue((report.value as? String)?.contains("finger-pan-canvas") == true)
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pencil strategy:'")).firstMatch
      .tap()
    app.buttons["pencil-as-mouse-js [Tier 1]"].tap()
    app.switches["Native verdict: pen drag unusable"].tap()
    XCTAssertTrue((report.value as? String)?.contains("pen drag unusable=true") == true)
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pencil strategy:'")).firstMatch
      .tap()
    app.buttons["none [Tier 1]"].tap()
    app.switches["Native verdict: pen drag unusable"].tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Finger pan:'")).firstMatch.tap()
    app.buttons["baseline"].tap()
    XCTAssertTrue(
      (report.value as? String)?.contains("WEBKIT_INTERNAL changed recognizers: 0") == true)
    app.buttons["Close"].tap()
    let verdict = app.buttons["Pencil drag verdict"]
    for _ in 0..<5 {
      if verdict.isHittable { break }
      app.swipeUp()
    }
    verdict.tap()
    if app.pickerWheels.firstMatch.exists {
      app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "FAIL")
      if app.buttons["Done"].exists { app.buttons["Done"].tap() }
    } else if app.buttons["FAIL"].exists {
      app.buttons["FAIL"].tap()
    } else {
      app.staticTexts["FAIL"].tap()
    }
    XCTAssertEqual(verdict.value as? String, "FAIL")
    app.buttons["Copy summary"].tap()
    XCTAssertTrue(app.staticTexts["Summary copied"].exists)
    app.buttons["Open diagnostics"].tap()
    XCTAssertTrue((report.value as? String)?.contains("FAIL: Pencil drag") == true)
    app.buttons["Copy report"].tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pencil strategy:'")).firstMatch
      .tap()
    app.buttons["pencil-gesture-reroute [Tier 2 WEBKIT_INTERNAL]"].tap()
    XCTAssertFalse((report.value as? String)?.contains("FAIL: Pencil drag") == true)
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pencil strategy:'")).firstMatch
      .tap()
    app.buttons["none [Tier 1]"].tap()
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "lab-runtime-strategies"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testSafeModeLeavesLabAndRestoresNormalMode() {
    let app = XCUIApplication()
    app.launchArguments = ["--input-lab"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["Folio input lab"].waitForExistence(timeout: 20))
    app.buttons["Open diagnostics"].tap()
    app.buttons["Safe"].tap()
    let report = app.textViews["diagnosticsReport"]
    XCTAssertTrue((report.value as? String)?.contains("Page: Network browser") == true)
    XCTAssertTrue((report.value as? String)?.contains("Mode: Safe") == true)
    XCTAssertFalse(app.buttons["Input lab"].isEnabled)
    XCTAssertFalse((report.value as? String)?.contains("Return to Figma") == true)
    app.buttons["Normal"].tap()
    app.buttons["Input lab"].tap()
    XCTAssertTrue(app.staticTexts["Folio input lab"].waitForExistence(timeout: 20))
  }

}
