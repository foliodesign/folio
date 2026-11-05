import XCTest

/// Explicit hardware opt-in. Local routing and real scratch outcomes are separate cases.
@MainActor
final class KeyboardDeviceDebugTests: XCTestCase {
  override func setUpWithError() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["FOLIO_DEVICE_DEBUG"] == "1"
        && ProcessInfo.processInfo.environment["FOLIO_MAGIC_KEYBOARD_READY"] == "1",
      "Requires explicit device-debug opt-in and an attached Magic Keyboard")
    continueAfterFailure = false
  }

  func testColdLaunchAndNewTabReceiveKeysWithoutCanvasInteraction() {
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--keyboard-logging", "--keyboard-all-off"]
    app.launch()
    app.terminate()
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["Local tab 0"].waitForExistence(timeout: 20))
    assertColdFixtureKeys(app)
    app.links["Open file 1"].tap()
    XCTAssertTrue(app.buttons["tab-1"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["tab-1"].isSelected)
    XCTAssertTrue(app.staticTexts["Local tab 1"].waitForExistence(timeout: 10))
    // No canvas tap, Increment, diagnostics, or background transition before the keys.
    assertColdFixtureKeys(app)
  }

  private func assertColdFixtureKeys(_ app: XCUIApplication) {
    assertHardwareReady(app)
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    app.typeKey("v", modifierFlags: [])
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    app.typeKey("t", modifierFlags: [])
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    app.typeKey("a", modifierFlags: .control)
    XCTAssertTrue(
      app.staticTexts["Fixture tools V 1 T 1 Ctrl+A 1"].waitForExistence(timeout: 5),
      app.debugDescription)
    XCTAssertTrue(app.staticTexts["Count 0"].exists)
    XCTAssertTrue(app.staticTexts["Fixture clicks increment 0 undo 0 redo 0"].exists)
    for cycle in 1...20 {
      app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
      XCTAssertTrue(
        app.staticTexts[
          "Cold shape present false undo \(cycle - 1) redo \(cycle - 1)"
        ].waitForExistence(timeout: 5), "delete cycle \(cycle)")
      XCTAssertEqual(app.keyboards.count, 0)
      app.typeKey("z", modifierFlags: .command)
      XCTAssertTrue(
        app.staticTexts[
          "Cold shape present true undo \(cycle) redo \(cycle - 1)"
        ].waitForExistence(timeout: 5), "undo cycle \(cycle)")
      XCTAssertEqual(app.keyboards.count, 0)
      app.typeKey("z", modifierFlags: [.command, .shift])
      XCTAssertTrue(
        app.staticTexts[
          "Cold shape present false undo \(cycle) redo \(cycle)"
        ].waitForExistence(timeout: 5), "redo cycle \(cycle)")
      XCTAssertEqual(app.keyboards.count, 0)
    }
    app.typeKey("z", modifierFlags: .command)
    XCTAssertTrue(
      app.staticTexts["Cold shape present true undo 21 redo 20"].waitForExistence(timeout: 5))
    let keys = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Keys '")).firstMatch
    XCTAssertTrue(keys.label.contains("Backspace:20:prevented=true"))
    XCTAssertFalse(keys.label.contains("Backspace:21:"))
    XCTAssertTrue(keys.label.contains("Cmd+z:21:prevented=true"))
    XCTAssertFalse(keys.label.contains("Cmd+z:22:"))
    XCTAssertTrue(keys.label.contains("Cmd+Shift+z:20:prevented=true"))
    XCTAssertFalse(keys.label.contains("Cmd+Shift+z:21:"))
    XCTAssertFalse(app.keyboards.firstMatch.exists)
  }

  /// Owner prepares one known shape in the named scratch and restores it before cold launch.
  /// Expected selection/shape labels must come from that scratch's returned accessibility tree.
  func testScratchColdLaunchAndDuplicateTabToolSelectionAndHistory() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["FOLIO_KEYBOARD_SCRATCH_READY"] == "1")
    let selection = try XCTUnwrap(environment["FOLIO_SCRATCH_SELECTION_LABEL"])
    let shape = try XCTUnwrap(environment["FOLIO_SCRATCH_SHAPE_LABEL"])
    XCTAssertFalse(selection.isEmpty)
    XCTAssertFalse(shape.isEmpty)
    let app = XCUIApplication()
    app.launchArguments = ["--keyboard-logging"]
    app.launch()
    app.terminate()
    app.launch()
    defer { app.terminate() }
    let selected = app.buttons.matching(
      NSPredicate(format: "selected == true AND identifier BEGINSWITH 'tab-'")
    ).firstMatch
    XCTAssertTrue(selected.waitForExistence(timeout: 30))
    XCTAssertEqual(selected.label, "Folio automation (safe to delete)", app.debugDescription)
    let sourceID = selected.identifier
    defer {
      if app.buttons[sourceID].exists { app.buttons[sourceID].tap() }
    }
    for duplicate in [false, true] {
      if duplicate {
        app.buttons["Open current file in new tab"].tap()
        XCTAssertTrue(app.switches["Move"].waitForExistence(timeout: 30))
        XCTAssertEqual(selected.label, "Folio automation (safe to delete)")
        XCTAssertNotEqual(selected.identifier, sourceID)
      }
      waitForTool(app.switches["Move"])
      assertHardwareReady(app)
      // First events after each ready page: no touch/chrome interaction to repair focus.
      XCTAssertFalse(app.keyboards.firstMatch.exists, app.debugDescription)
      app.typeKey("t", modifierFlags: [])
      waitForTool(app.switches["Text"])
      app.typeKey("v", modifierFlags: [])
      waitForTool(app.switches["Move"])
      app.typeKey("a", modifierFlags: .control)
      XCTAssertTrue(app.staticTexts[selection].waitForExistence(timeout: 5), app.debugDescription)
      XCTAssertFalse(app.keyboards.firstMatch.exists)
      XCTAssertTrue(app.staticTexts[shape].exists)
      // Twenty reversible history cycles. Leave the approved scratch shape restored.
      for cycle in 1...20 {
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertTrue(
          app.staticTexts[shape].waitForNonExistence(timeout: 5), "delete cycle \(cycle)")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts[shape].waitForExistence(timeout: 5), "undo cycle \(cycle)")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts[shape].waitForNonExistence(timeout: 5), "redo cycle \(cycle)")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts[shape].waitForExistence(timeout: 5), "restore cycle \(cycle)")
        XCTAssertEqual(app.keyboards.count, 0)
        app.typeKey("a", modifierFlags: .control)
        XCTAssertTrue(app.staticTexts[selection].waitForExistence(timeout: 5))
      }
      if duplicate { app.buttons["Close tab"].tap() }
    }
  }

  private func assertHardwareReady(_ app: XCUIApplication) {
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format:
          "value CONTAINS 'externalKeyboard=true' AND value CONTAINS 'pageReady=true' AND value CONTAINS 'sceneActive=true' AND value CONTAINS 'geometryReady=true' AND value CONTAINS 'initialPending=false'"
      ),
      object: app.buttons["Open diagnostics"])
    let result = XCTWaiter.wait(for: [ready], timeout: 10)
    let evidence = XCTAttachment(
      string: "\(app.buttons["Open diagnostics"].value ?? "unreturned")\n\(app.debugDescription)")
    evidence.name = "keyboard-native-readiness"
    evidence.lifetime = .keepAlways
    add(evidence)
    XCTAssertEqual(result, .completed)
    XCTAssertEqual(app.keyboards.count, 0)
  }

  private func waitForTool(_ tool: XCUIElement) {
    let selected = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND (selected == true OR value == '1')"),
      object: tool)
    XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
  }

  func testColdLaunchAndDiagnosticsReturnToExactLocalHistory() {
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--keyboard-logging"]
    app.launch()
    app.terminate()
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["Local tab 0"].waitForExistence(timeout: 20))
    let browserID = app.webViews.firstMatch.identifier
    let token = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Load token '"))
      .firstMatch.label
    let increment = app.buttons["Increment"]
    XCTAssertTrue(increment.isHittable)
    increment.tap()
    XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 5))
    let canvas = app.buttons["History canvas"]
    XCTAssertTrue(canvas.isHittable)
    canvas.tap()
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    for (index, diagnostics) in [false, true].enumerated() {
      if diagnostics {
        app.buttons["Open diagnostics"].tap()
        XCTAssertTrue(app.staticTexts["Folio diagnostics"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        let gone = XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "exists == false"),
          object: app.otherElements["b2InputDiagnosticsSheet"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
      }
      app.typeKey("z", modifierFlags: .command)
      XCTAssertTrue(app.staticTexts["Count 0"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.staticTexts["Cursor 0"].exists)
      app.typeKey("z", modifierFlags: [.command, .shift])
      XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.staticTexts["Cursor 1"].exists)
      XCTAssertTrue(app.staticTexts["History 0,1"].exists)
      XCTAssertTrue(app.staticTexts["Fixture keys undo \(index + 1) redo \(index + 1)"].exists)
      XCTAssertTrue(app.staticTexts["Fixture clicks increment 1 undo 0 redo 0"].exists)
      XCTAssertTrue(app.staticTexts[token].exists)
      XCTAssertEqual(app.webViews.firstMatch.identifier, browserID)
      XCTAssertFalse(app.keyboards.firstMatch.exists)
    }
  }
}
