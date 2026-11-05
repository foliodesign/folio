import XCTest

@MainActor
final class FocusSmokeTests: XCTestCase {
  func testSoftwareKeyboardFocusKeepsNativeGeometryWithControls() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--focus-lab", "--focus-lock", "--focus-viewport", "--focus-logging"]
    app.launch()
    defer { app.terminate() }
    let field = app.textFields["Small focus field"]
    XCTAssertTrue(field.waitForExistence(timeout: 20))
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
    let status = app.staticTexts["focusGeometry"]
    let settled = NSPredicate(
      format:
        "label CONTAINS 'lock=true zoom=1.0 offset=0.0,0.0' AND NOT label CONTAINS 'keyboardFrames=0'"
    )
    expectation(for: settled, evaluatedWith: status)
    waitForExpectations(timeout: 10)
    app.typeText("privacyprobe")
    XCTAssertTrue(settled.evaluate(with: status))
    let canvas = app.descendants(matching: .any).matching(identifier: "Focus canvas").firstMatch
    XCTAssertTrue(canvas.exists)
    print("FOCUS_PINCH canvas=\(canvas.frame) keyboard=\(app.keyboards.firstMatch.frame)")
    canvas.pinch(withScale: 1.5, velocity: 1)
    XCTAssertTrue(app.staticTexts["contactsPeak=2"].waitForExistence(timeout: 5))
    XCTAssertTrue(settled.evaluate(with: status))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "focus-keyboard-locked"
    shot.lifetime = .keepAlways
    add(shot)
    app.buttons["Open diagnostics"].tap()
    let report = app.textViews["diagnosticsReport"]
    let value = report.value as? String ?? ""
    XCTAssertTrue(value.contains("JS focus focusin tag=INPUT type=text"))
    XCTAssertTrue(value.contains("Native keyboard"))
    XCTAssertTrue(value.contains("visualViewport="))
    XCTAssertFalse(value.contains("privacyprobe"))
    app.terminate()
  }
  func testBaselineFocusCapturesGeometryForComparison() {
    let app = XCUIApplication()
    app.launchArguments = ["--focus-lab", "--focus-logging"]
    app.launch()
    defer { app.terminate() }
    let field = app.textFields["Small focus field"]
    XCTAssertTrue(field.waitForExistence(timeout: 20))
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
    let status = app.staticTexts["focusGeometry"]
    expectation(
      for: NSPredicate(format: "NOT label CONTAINS 'keyboardFrames=0'"), evaluatedWith: status)
    waitForExpectations(timeout: 10)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "focus-keyboard-baseline"
    shot.lifetime = .keepAlways
    add(shot)
    // Evidence only: a simulator baseline need not reproduce this iPad's focus zoom.
    print("FOCUS_BASELINE \(status.label)")
    app.terminate()
  }
}

extension FocusSmokeTests {
  func testVisibleEditableKeepsNativeTextUndoAfterDiagnostics() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["FOLIO_MAGIC_KEYBOARD_READY"] == "1",
      "Requires the hardware keyboard profile")
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--focus-lab", "--focus-logging"]
    app.launch()
    defer { app.terminate() }
    let field = app.textFields["Small focus field"]
    XCTAssertTrue(field.waitForExistence(timeout: 20))
    field.tap()
    field.typeText("localundo")
    let before = field.value as? String
    XCTAssertEqual(before, "localundo")
    app.buttons["Open diagnostics"].tap()
    XCTAssertTrue(app.staticTexts["Folio diagnostics"].waitForExistence(timeout: 5))
    app.buttons["Close"].tap()
    XCTAssertTrue(app.otherElements["b2InputDiagnosticsSheet"].waitForNonExistence(timeout: 10))
    XCTAssertEqual(field.value as? String, before)
    for cycle in 1...20 {
      app.typeKey("z", modifierFlags: .command)
      let undone = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value != %@", before ?? ""), object: field)
      XCTAssertEqual(XCTWaiter.wait(for: [undone], timeout: 5), .completed)
      app.typeKey("z", modifierFlags: [.command, .shift])
      let redone = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", before ?? ""), object: field)
      XCTAssertEqual(XCTWaiter.wait(for: [redone], timeout: 5), .completed)
      XCTAssertEqual(app.keyboards.count, 0, "visible text undo cycle \(cycle)")
    }
  }

  func testDiagnosticsCloseAndSwipeKeepLocalText() {
    let app = XCUIApplication()
    app.launchArguments = ["--focus-lab", "--focus-logging"]
    app.launch()
    defer { app.terminate() }
    let field = app.textFields["Small focus field"]
    XCTAssertTrue(field.waitForExistence(timeout: 20))
    field.tap()
    field.typeText("localprobe")
    for swipe in [false, true] {
      app.buttons["Open diagnostics"].tap()
      if swipe {
        let sheet = app.otherElements["b2InputDiagnosticsSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let grabber = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        grabber.press(
          forDuration: 0.1,
          thenDragTo: grabber.withOffset(CGVector(dx: 0, dy: sheet.frame.height * 0.7)))
      } else {
        app.buttons["Close"].tap()
      }
      let dismissed = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == false"),
        object: app.otherElements["b2InputDiagnosticsSheet"])
      let result = XCTWaiter.wait(for: [dismissed], timeout: 10)
      if result != .completed {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "focus-dismissal-failure"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
      }
      XCTAssertEqual(result, .completed)
      XCTAssertTrue(field.isHittable)
      XCTAssertEqual(field.value as? String, "localprobe")
    }
  }
}
