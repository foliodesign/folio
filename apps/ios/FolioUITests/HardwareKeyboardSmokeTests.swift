import XCTest

@MainActor
final class HardwareKeyboardSmokeTests: XCTestCase {
  override func setUpWithError() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["FOLIO_MAGIC_KEYBOARD_READY"] == "1",
      "Owner must independently confirm an attached Magic Keyboard; an unconfirmed profile is not hardware evidence"
    )
  }

  func testHiddenSinkHardwareKeys() {
    exercise(allOff: false, cold: false)
  }

  func testHiddenSinkHardwareKeysAllSwitchesOff() {
    exercise(allOff: true, cold: false)
  }

  func testColdLaunchAndNewTabHardwareKeysWithoutPageInteraction() {
    exercise(allOff: true, cold: true)
  }

  private func exercise(allOff: Bool, cold: Bool) {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments =
      ["--tabs-lab", "--keyboard-logging"]
      + (allOff ? ["--keyboard-all-off"] : []) + (cold ? ["--keyboard-cold"] : [])
    app.launch()
    defer { app.terminate() }
    let canvas = app.buttons["Keyboard canvas"]
    XCTAssertTrue(canvas.waitForExistence(timeout: 20))
    let hardware = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format:
          "value CONTAINS 'externalKeyboard=true' AND value CONTAINS 'pageReady=true' AND value CONTAINS 'geometryReady=true' AND value CONTAINS 'initialPending=false'"
      ),
      object: app.buttons["Open diagnostics"])
    let hardwareResult = XCTWaiter.wait(for: [hardware], timeout: 10)
    let readiness = XCTAttachment(
      string: "\(app.buttons["Open diagnostics"].value ?? "unreturned")\n\(app.debugDescription)")
    readiness.name = "h1-confirmed-profile-readiness"
    readiness.lifetime = .keepAlways
    add(readiness)
    XCTAssertEqual(hardwareResult, .completed)
    if !cold {
      canvas.tap()
      // Same-tab selection must preserve the content responder, not replace it.
      app.buttons["tab-0"].tap()
    }
    print("H1_KEYBOARD \(app.keyboards.debugDescription)")
    XCTAssertEqual(app.keyboards.count, 0)
    if !cold {
      app.buttons["Open diagnostics"].tap()
      app.buttons["Close"].tap()
      // Optional chrome restoration is OFF. A real page tap resumes content input.
      canvas.tap()
      XCTAssertEqual(app.keyboards.count, 0)
    }
    let keys = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Keys '")).firstMatch
    for (key, modifiers, label) in [
      ("v", XCUIElement.KeyModifierFlags(), "v"), ("t", XCUIElement.KeyModifierFlags(), "t"),
      ("a", XCUIElement.KeyModifierFlags.control, "Ctrl+a"),
      (XCUIKeyboardKey.delete.rawValue, XCUIElement.KeyModifierFlags(), "Backspace"),
      ("z", XCUIElement.KeyModifierFlags.command, "Cmd+z"),
    ] {
      app.typeKey(key, modifierFlags: modifiers)
      expectation(
        for: NSPredicate(format: "label CONTAINS %@", "\(label):1:prevented=\(label == "Cmd+z")"),
        evaluatedWith: keys)
      waitForExpectations(timeout: 5)
      XCTAssertFalse(keys.label.contains("\(label):2:"))
      XCTAssertEqual(app.keyboards.count, 0)
    }
    XCTAssertTrue(app.staticTexts["Sink xyv; editor xy; deleted true"].exists)
    let editor = app.textViews["Keyboard editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    app.typeKey("e", modifierFlags: .control)
    app.typeKey("q", modifierFlags: [])
    XCTAssertTrue(
      app.staticTexts["Sink xyv; editor xyq; deleted true"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.keyboards.count, 0)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "h1-hardware-keys"
    shot.lifetime = .keepAlways
    add(shot)
    print("H1_KEYS \(keys.label)")
    if cold {
      app.links["Open file 1"].tap()
      XCTAssertTrue(app.staticTexts["Local tab 1"].waitForExistence(timeout: 10))
      let newTabReady = XCTNSPredicateExpectation(
        predicate: NSPredicate(
          format:
            "value CONTAINS 'externalKeyboard=true' AND value CONTAINS 'pageReady=true' AND value CONTAINS 'geometryReady=true' AND value CONTAINS 'initialPending=false'"
        ),
        object: app.buttons["Open diagnostics"])
      XCTAssertEqual(XCTWaiter.wait(for: [newTabReady], timeout: 10), .completed)
      XCTAssertEqual(app.keyboards.count, 0)
      // Run every requested chord on the new tab, before any canvas/text interaction.
      for (key, modifiers, label) in [
        ("v", XCUIElement.KeyModifierFlags(), "v"),
        ("t", XCUIElement.KeyModifierFlags(), "t"),
        ("a", XCUIElement.KeyModifierFlags.control, "Ctrl+a"),
        (XCUIKeyboardKey.delete.rawValue, XCUIElement.KeyModifierFlags(), "Backspace"),
        ("z", XCUIElement.KeyModifierFlags.command, "Cmd+z"),
      ] {
        app.typeKey(key, modifierFlags: modifiers)
        let keySeen = XCTNSPredicateExpectation(
          predicate: NSPredicate(
            format: "label CONTAINS %@", "\(label):1:prevented=\(label == "Cmd+z")"),
          object: keys)
        XCTAssertEqual(XCTWaiter.wait(for: [keySeen], timeout: 5), .completed)
        XCTAssertFalse(keys.label.contains("\(label):2:"))
        XCTAssertEqual(app.keyboards.count, 0)
      }
      XCTAssertTrue(app.staticTexts["Sink xyv; editor xy; deleted true"].exists)
      XCTAssertEqual(app.keyboards.count, 0)
    }
  }
}
