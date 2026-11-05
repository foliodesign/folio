import XCTest

@MainActor
final class TabSmokeTests: XCTestCase {
  func testThreeTabsKeepPageStateWithoutReloadAndLastCloseSelectsHome() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--browser-readiness"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["Local tab 0"].waitForExistence(timeout: 20))
    var tokens: [String] = []
    for number in 1...3 {
      if number > 1 { app.buttons["tab-0"].tap() }
      switch number {
      case 1: tapReady(app.links["Open file 1"], app: app)
      case 2: tapReady(app.links["Open file 2 popup"], app: app)
      default:
        tapReady(app.links["Open file 3 SPA link"], app: app)
      }
      b2InputWait(app.buttons["tab-\(number)"], "selected == true")
      XCTAssertTrue(app.staticTexts["Local tab \(number)"].waitForExistence(timeout: 10))
      let token = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Load token '"))
        .firstMatch
      XCTAssertTrue(token.waitForExistence(timeout: 10))
      tokens.append(token.label)
      tapReady(app.buttons["Increment"], app: app)
      XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 5))
      let note = app.textFields["Tab note"]
      tapReady(note, app: app)
      note.typeText("note\(number)")
    }
    for number in [1, 3, 2, 1] {
      app.buttons["tab-\(number)"].tap()
      XCTAssertTrue(app.staticTexts["Local tab \(number)"].exists)
      XCTAssertTrue(app.staticTexts[tokens[number - 1]].exists)
      XCTAssertTrue(app.staticTexts["Count 1"].exists)
      XCTAssertEqual(app.textFields["Tab note"].value as? String, "note\(number)")
    }
    app.buttons["tab-0"].tap()
    XCTAssertTrue(app.staticTexts["Local tab 0"].exists)
    app.buttons["tab-2"].tap()
    XCTAssertTrue(app.staticTexts[tokens[1]].exists)
    app.buttons["Close tab"].tap()
    XCTAssertTrue(app.staticTexts[tokens[2]].exists)
    app.buttons["Close tab"].tap()
    XCTAssertTrue(app.staticTexts[tokens[0]].exists)
    app.buttons["Close tab"].tap()
    XCTAssertTrue(app.staticTexts["Local tab 0"].exists)
    XCTAssertFalse(app.buttons["Close tab"].isEnabled)
  }
}

extension TabSmokeTests {
  func testB2InputSameTabPreservesFixtureHistory() {
    b2InputCheckTransition { app in app.buttons["tab-0"].tap() }
  }

  func testB2InputURLCancelPreservesFixtureHistory() {
    b2InputCheckTransition { app in
      let alert = b2InputOpenURLAlert(app)
      alert.buttons["Cancel"].tap()
      b2InputWait(alert, "exists == false")
    }
  }

  func testB2InputInvalidURLPreservesFixtureHistory() {
    b2InputCheckTransition { app in
      let alert = b2InputOpenURLAlert(app)
      alert.textFields.firstMatch.tap()
      alert.textFields.firstMatch.typeText("invalid")
      alert.buttons["Open"].tap()
      b2InputWait(alert, "exists == false")
    }
  }

  func testB2InputDiagnosticsMeterClosePreservesFixtureHistory() {
    b2InputCheckTransition { app in
      b2InputOpenDiagnostics(app)
      let meter = app.textFields["Figma memory meter"]
      b2InputRevealDiagnostics(app, element: meter, swipeUp: false)
      b2InputWait(meter, "exists == true AND hittable == true")
      meter.tap()
      meter.typeText("42%")
      app.buttons["Close"].tap()
      b2InputWaitForDiagnosticsDismissal(app)
    }
  }

  func testB2InputDiagnosticsSwipePreservesFixtureHistory() {
    b2InputCheckTransition { app in
      b2InputOpenDiagnostics(app)
      swipeDiagnosticsSheet(app)
      b2InputWaitForDiagnosticsDismissal(app)
    }
  }

  private func b2InputCheckTransition(_ transition: (XCUIApplication) -> Void) {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--tabs-url-alert"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["Local tab 0"].waitForExistence(timeout: 20))
    let token = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Load token '"))
      .firstMatch
    XCTAssertTrue(token.waitForExistence(timeout: 10))
    let originalToken = token.label
    let browserID = app.webViews.firstMatch.identifier
    b2InputWait(app.staticTexts["Count 0"], "exists == true")
    b2InputWait(app.buttons["Increment"], "exists == true AND hittable == true")
    tapReady(app.buttons["Increment"], app: app)
    b2InputAssertState(app, token: originalToken, count: 1, cursor: 1, undo: 0, redo: 0)
    transition(app)
    XCTAssertEqual(app.webViews.firstMatch.identifier, browserID)
    // A retained underlying element is not evidence of completed native dismissal.
    b2InputWait(app.alerts.firstMatch, "exists == false")
    b2InputWaitForDiagnosticsDismissal(app)
    b2InputAssertState(app, token: originalToken, count: 1, cursor: 1, undo: 0, redo: 0)
    b2InputWait(app.buttons["Fixture undo"], "exists == true AND hittable == true")
    app.buttons["Fixture undo"].tap()
    b2InputAssertState(app, token: originalToken, count: 0, cursor: 0, undo: 1, redo: 0)
    b2InputWait(app.buttons["Fixture redo"], "exists == true AND hittable == true")
    app.buttons["Fixture redo"].tap()
    b2InputAssertState(app, token: originalToken, count: 1, cursor: 1, undo: 1, redo: 1)
    // Fixture clicks/history are distinct from hardware shortcuts and Figma history.
  }

  private func b2InputAssertState(
    _ app: XCUIApplication, token: String, count: Int, cursor: Int, undo: Int, redo: Int
  ) {
    b2InputWait(app.staticTexts["Count \(count)"], "exists == true")
    b2InputWait(app.staticTexts["Cursor \(cursor)"], "exists == true")
    b2InputWait(
      app.staticTexts["Fixture clicks increment 1 undo \(undo) redo \(redo)"], "exists == true")
    XCTAssertTrue(app.staticTexts[token].exists, "Fixture reloaded")
    XCTAssertTrue(app.staticTexts["History 0,1"].exists, "Fixture history was replaced")
  }

  private func b2InputOpenURLAlert(_ app: XCUIApplication) -> XCUIElement {
    // Required DEBUG setup contract under --tabs-lab; see the B2 input handoff.
    b2InputWait(app.buttons["New tab"], "exists == true AND hittable == true")
    app.buttons["New tab"].tap()
    let alert = app.alerts["New tab"]
    b2InputWait(alert, "exists == true")
    return alert
  }

  private func b2InputOpenDiagnostics(_ app: XCUIApplication) {
    b2InputWait(app.buttons["Open diagnostics"], "exists == true AND hittable == true")
    app.buttons["Open diagnostics"].tap()
    b2InputWait(app.staticTexts["Folio diagnostics"], "exists == true AND hittable == true")
    let logging = app.switches["Input logging"]
    b2InputRevealDiagnostics(app, element: logging, swipeUp: true)
    if logging.value as? String != "1" { logging.tap() }
    b2InputWait(logging, "value == '1'")
  }

  private func b2InputRevealDiagnostics(
    _ app: XCUIApplication, element: XCUIElement, swipeUp: Bool
  ) {
    for _ in 0..<6 {
      if element.isHittable { break }
      let scroller = app.scrollViews["b2InputDiagnosticsScroll"]
      if swipeUp { scroller.swipeUp() } else { scroller.swipeDown() }
    }
    b2InputWait(element, "exists == true AND hittable == true")
  }

  private func b2InputWaitForDiagnosticsDismissal(_ app: XCUIApplication) {
    b2InputWait(app.otherElements["b2InputDiagnosticsSheet"], "exists == false")
    b2InputWait(app.staticTexts["Folio diagnostics"], "exists == false")
    b2InputWait(app.textViews["diagnosticsReport"], "exists == false")
    b2InputWait(app.textFields["Figma memory meter"], "exists == false")
  }

  private func b2InputWait(
    _ element: XCUIElement, _ predicate: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let condition = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: predicate), object: element)
    let result = XCTWaiter.wait(for: [condition], timeout: 10)
    if result != .completed {
      let hierarchy = XCTAttachment(string: XCUIApplication().debugDescription)
      hierarchy.name = "failed-transition-hierarchy"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
    }
    XCTAssertEqual(
      result, .completed,
      "Fixture transition did not settle: \(predicate)", file: file, line: line)
  }
}

extension TabSmokeTests {
  func testDuplicateFolderAndFileToFileRouting() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--browser-readiness"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["Local tab 0"].waitForExistence(timeout: 20))
    XCTAssertFalse(app.buttons["New tab"].exists)
    let homeBrowser = app.webViews.firstMatch.identifier
    tapReady(app.links["Open project folder"], app: app)
    XCTAssertTrue(app.staticTexts["Local tab 0"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["tab-1"].exists)
    tapReady(app.links["Open file 1"], app: app)
    XCTAssertTrue(app.staticTexts["Local tab 1"].waitForExistence(timeout: 10))
    let fileBrowser = app.webViews.firstMatch.identifier
    let token = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Load token '"))
      .firstMatch.label
    tapReady(app.buttons["Increment"], app: app)
    b2InputAssertState(app, token: token, count: 1, cursor: 1, undo: 0, redo: 0)
    tapReady(app.links["Open file 2 popup"], app: app)
    XCTAssertTrue(app.staticTexts["Local tab 2"].waitForExistence(timeout: 10))
    tapReady(app.links["Open file 1"], app: app)
    XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["tab-3"].exists)
    XCTAssertEqual(app.webViews.firstMatch.identifier, fileBrowser)
    b2InputAssertState(app, token: token, count: 1, cursor: 1, undo: 0, redo: 0)
    tapReady(app.links["Return dashboard"], app: app)
    XCTAssertTrue(app.staticTexts["Local tab 0"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.webViews.firstMatch.identifier, homeBrowser)
    tapReady(app.links["Open file 1"], app: app)
    XCTAssertTrue(app.staticTexts["Count 1"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.webViews.firstMatch.identifier, fileBrowser)
    b2InputAssertState(app, token: token, count: 1, cursor: 1, undo: 0, redo: 0)
    XCTAssertFalse(app.buttons["tab-3"].exists)
  }
}

extension TabSmokeTests {
  private func tapReady(_ element: XCUIElement, app: XCUIApplication) {
    if element.exists && !element.isHittable && !app.keyboards.firstMatch.exists {
      let browser = app.webViews.firstMatch
      // Only scroll an element actually outside the returned browser viewport.
      // The r2r3 failed link was already inside it; scrolling is not its repair.
      if element.frame.maxY > browser.frame.maxY {
        browser.swipeUp()
      } else if element.frame.minY < browser.frame.minY {
        browser.swipeDown()
      }
    }
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
    let result = XCTWaiter.wait(for: [ready], timeout: 10)
    if result != .completed {
      let attachment = XCTAttachment(string: app.debugDescription)
      let signature = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'B3 hit '"))
        .firstMatch
      let geometry = XCTAttachment(
        string:
          "browser=\(app.webViews.firstMatch.frame) element=\(element.frame) keyboards=\(app.keyboards.count) signature=\(signature.exists ? signature.label : "unreturned") increment=\(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'B6 increment '")).firstMatch.label)"
      )
      let native = XCTAttachment(string: "\(app.buttons["Open diagnostics"].value ?? "unreturned")")
      native.name = "b3-native-hit-readiness"
      native.lifetime = .keepAlways
      add(native)
      geometry.name = "b3-browser-hit-geometry"
      geometry.lifetime = .keepAlways
      add(geometry)
      attachment.name = "hit-test-failure"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    XCTAssertEqual(result, .completed)
    guard result == .completed else { return }
    element.tap()
  }

  private func swipeDiagnosticsSheet(_ app: XCUIApplication) {
    let sheet = app.otherElements["b2InputDiagnosticsSheet"]
    b2InputWait(sheet, "exists == true AND hittable == true")
    // Deliberate grabber gesture, outside the panel's scrolling content. No fallback tap.
    let grabber = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
    grabber.press(
      forDuration: 0.1,
      thenDragTo: grabber.withOffset(CGVector(dx: 0, dy: sheet.frame.height * 0.7)))
  }

  func testSPAChangeKeepsExactSourceHistoryAndEditableState() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--browser-readiness"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["Local tab 0"].waitForExistence(timeout: 20))
    let token = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Load token '"))
      .firstMatch.label
    let browserID = app.webViews.firstMatch.identifier
    tapReady(app.buttons["Increment"], app: app)
    let field = app.textFields["Tab note"]
    tapReady(field, app: app)
    field.typeText("retained")
    b2InputWait(app.staticTexts["Browser history 1"], "exists == true")
    tapReady(app.buttons["Open file 3 SPA"], app: app)
    b2InputWait(app.staticTexts["Browser history 2"], "exists == true")
    XCTAssertFalse(app.buttons["tab-1"].exists)
    XCTAssertEqual(app.webViews.firstMatch.identifier, browserID)
    XCTAssertEqual(field.value as? String, "retained")
    b2InputAssertState(app, token: token, count: 1, cursor: 1, undo: 0, redo: 0)
    tapReady(app.buttons["Fixture undo"], app: app)
    b2InputAssertState(app, token: token, count: 0, cursor: 0, undo: 1, redo: 0)
    tapReady(app.buttons["Open current file in new tab"], app: app)
    XCTAssertTrue(app.staticTexts["Local tab 1"].waitForExistence(timeout: 10))
    tapReady(app.buttons["tab-0"], app: app)
    XCTAssertEqual(app.webViews.firstMatch.identifier, browserID)
    XCTAssertEqual(field.value as? String, "retained")
    b2InputAssertState(app, token: token, count: 0, cursor: 0, undo: 1, redo: 0)
  }

  func testStandardSPALinkOpensOneSelectedTabAndPreservesSource() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--browser-readiness"]
    app.launch()
    defer { app.terminate() }
    b2InputWait(app.staticTexts["Local tab 0"], "exists == true")
    let source = app.webViews.firstMatch.identifier
    let token = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Load token '"))
      .firstMatch.label
    tapReady(app.buttons["Increment"], app: app)
    tapReady(app.links["Open file 3 SPA link"], app: app)
    b2InputWait(app.buttons["tab-1"], "selected == true")
    b2InputWait(app.staticTexts["Local tab 1"], "exists == true")
    XCTAssertFalse(app.buttons["tab-2"].exists, "One link must create one destination")
    tapReady(app.buttons["tab-0"], app: app)
    XCTAssertEqual(app.webViews.firstMatch.identifier, source)
    b2InputAssertState(app, token: token, count: 1, cursor: 1, undo: 0, redo: 0)
    tapReady(app.buttons["Fixture undo"], app: app)
    b2InputAssertState(app, token: token, count: 0, cursor: 0, undo: 1, redo: 0)
  }

  func testWarmAndColdExternalDashboardLinkSelectsDeliveredTab() throws {
    let app = XCUIApplication()
    let url = try XCTUnwrap(
      URL(
        string:
          "folio://open?url=https%3A%2F%2Fwww.figma.com%2Ffiles%3Fnode-id%3D1%23privateFragment"))
    app.launchArguments = ["--native-lab", "--browser-readiness"]
    app.launch()
    defer { app.terminate() }
    b2InputWait(app.staticTexts["Native integration lab"], "exists == true")
    let sourceTab = app.buttons.matching(
      NSPredicate(format: "selected == true AND identifier BEGINSWITH 'tab-'")
    ).firstMatch.identifier
    for cold in [false, true] {
      if cold {
        app.terminate()
        app.launchArguments = []
      }
      app.open(url)
      let selected = app.buttons.matching(
        NSPredicate(format: "selected == true AND identifier BEGINSWITH 'tab-'")
      ).firstMatch
      b2InputWait(selected, "exists == true AND identifier != 'tab-0'")
      tapReady(app.buttons["Open diagnostics"], app: app)
      b2InputWait(app.textViews["diagnosticsReport"], "exists == true")
      let report = try XCTUnwrap(app.textViews["diagnosticsReport"].value as? String)
      XCTAssertTrue(report.contains("External link: www.figma.com/files"))
      XCTAssertFalse(report.contains("node-id"))
      XCTAssertFalse(report.contains("privateFragment"))
      tapReady(app.buttons["Close"], app: app)
      b2InputWaitForDiagnosticsDismissal(app)
      if !cold {
        tapReady(app.buttons[sourceTab], app: app)
        b2InputWait(app.staticTexts["Native integration lab"], "exists == true")
      }
    }
  }

  func testExternalDashboardLinkSelectsDestinationAndResumesOneSourceExportChoice() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    let link = try XCTUnwrap(URL(string: "folio://open?url=https%3A%2F%2Fwww.figma.com%2Ffiles"))
    app.launchArguments = ["--native-lab", "--browser-readiness"]
    app.launch()
    defer { app.terminate() }
    b2InputWait(app.staticTexts["Native integration lab"], "exists == true")
    let selected = app.buttons.matching(
      NSPredicate(format: "selected == true AND identifier BEGINSWITH 'tab-'")
    ).firstMatch
    let source = selected.identifier
    let browser = app.webViews.firstMatch.identifier
    tapReady(app.buttons["Download blob"], app: app)
    b2InputWait(app.alerts["Export ready"], "exists == true")
    app.open(link)
    let destination = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND identifier != %@", source),
      object: selected)
    XCTAssertEqual(XCTWaiter.wait(for: [destination], timeout: 10), .completed)
    b2InputWait(app.alerts["Export ready"], "exists == false")
    tapReady(app.buttons[source], app: app)
    b2InputWait(app.buttons[source], "selected == true")
    b2InputWait(app.alerts["Export ready"], "exists == true")
    XCTAssertEqual(app.alerts.matching(identifier: "Export ready").count, 1)
    XCTAssertEqual(app.webViews.firstMatch.identifier, browser)
    tapReady(app.alerts["Export ready"].buttons["Cancel"], app: app)
    b2InputWait(app.alerts["Export ready"], "exists == false")
    b2InputWait(app.staticTexts["Native integration lab"], "exists == true")
  }

  func testLocalTitleUpdatesVisibleTabAndHomeStaysFixed() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--browser-readiness"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["Local tab 0"].waitForExistence(timeout: 20))
    tapReady(app.links["Open file 1"], app: app)
    b2InputWait(app.buttons["tab-1"], "label == 'Local document 1'")
    tapReady(app.buttons["Rename local title"], app: app)
    b2InputWait(app.buttons["tab-1"], "label == 'Renamed document 1'")
    tapReady(app.buttons["tab-0"], app: app)
    XCTAssertEqual(app.buttons["tab-0"].label, "Home")
    XCTAssertEqual(app.buttons["tab-1"].label, "Renamed document 1")
  }
}

// Isolate standard navigation from supplied-configuration child readiness.
// Neither result substitutes for the two original A2/A3 routing methods.
extension TabSmokeTests {
  func testStandardNativeNavigationReusesFileAndPreservesNestedHome() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--browser-readiness"]
    app.launch()
    defer { app.terminate() }
    b2InputWait(app.staticTexts["Local tab 0"], "exists == true")
    tapReady(app.links["Open project folder"], app: app)
    b2InputWait(app.buttons["browser-back"], "enabled == true")
    let homeID = app.webViews.firstMatch.identifier
    let token = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Load token '"))
      .firstMatch.label
    tapReady(app.buttons["Increment"], app: app)
    let note = app.textFields["Tab note"]
    tapReady(note, app: app)
    note.typeText("nested")
    tapReady(app.links["Open file 1"], app: app)
    b2InputWait(app.buttons["tab-1"], "selected == true")
    let fileID = app.webViews.firstMatch.identifier
    let fileToken = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Load token '"))
      .firstMatch.label
    tapReady(app.buttons["tab-0"], app: app)
    XCTAssertEqual(app.webViews.firstMatch.identifier, homeID)
    XCTAssertEqual(note.value as? String, "nested")
    b2InputAssertState(app, token: token, count: 1, cursor: 1, undo: 0, redo: 0)
    XCTAssertTrue(app.buttons["browser-back"].isEnabled)
    tapReady(app.links["Open file 1"], app: app)
    b2InputWait(app.buttons["tab-1"], "selected == true")
    XCTAssertEqual(app.webViews.firstMatch.identifier, fileID)
    XCTAssertTrue(app.staticTexts[fileToken].exists)
    XCTAssertFalse(app.buttons["tab-2"].exists)
    tapReady(app.buttons["Close tab"], app: app)
    b2InputWait(app.buttons["tab-0"], "selected == true")
    XCTAssertEqual(app.webViews.firstMatch.identifier, homeID)
    XCTAssertEqual(note.value as? String, "nested")
    b2InputAssertState(app, token: token, count: 1, cursor: 1, undo: 0, redo: 0)
  }

  func testRelatedChildNativeReadinessWithoutEarlierTabOrFocusTransitions() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--browser-readiness"]
    app.launch()
    defer { app.terminate() }
    b2InputWait(app.staticTexts["Local tab 0"], "exists == true")
    tapReady(app.links["Open file 2 popup"], app: app)
    b2InputWait(app.buttons["tab-1"], "selected == true")
    b2InputWait(app.staticTexts["Local tab 1"], "exists == true")
    tapReady(app.buttons["Increment"], app: app)
    b2InputWait(app.staticTexts["Count 1"], "exists == true")
    tapReady(app.links["Open file 1"], app: app)
    b2InputWait(app.buttons["tab-2"], "selected == true")
    XCTAssertFalse(app.buttons["tab-3"].exists)
  }
}

extension TabSmokeTests {
  func testB4ChromeNativeHitsAt50Percent() { checkB4Chrome(percent: "50%") }
  func testB4ChromeNativeHitsAt100Percent() { checkB4Chrome(percent: "100%") }
  func testB4ChromeNativeHitsAt200Percent() { checkB4Chrome(percent: "200%") }

  private func checkB4Chrome(percent: String) {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--tabs-lab", "--browser-readiness", "--browser-chrome-visibility",
      "--interface-zoom-reset",
    ]
    app.launch()
    defer {
      XCUIDevice.shared.orientation = .portrait
      app.terminate()
    }
    b2InputWait(app.staticTexts["Local tab 0"], "exists == true")
    tapReady(app.buttons["interface-zoom-presets"], app: app)
    tapReady(app.buttons[percent], app: app)
    let browserID = app.webViews.firstMatch.identifier
    let token = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Load token '"))
      .firstMatch.label
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      b2InputWait(app.buttons["Increment"], "hittable == true")
      let count = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Count '"))
        .firstMatch.label
      XCTAssertEqual(app.webViews.firstMatch.identifier, browserID)
      XCTAssertTrue(app.staticTexts[token].exists)
      XCTAssertTrue(app.staticTexts[count].exists)
      tapReady(app.buttons["Increment"], app: app)
      let expectedCount = (Int(count.dropFirst("Count ".count)) ?? -1) + 1
      XCTAssertGreaterThan(expectedCount, 0)
      XCTAssertTrue(app.staticTexts["Count \(expectedCount)"].waitForExistence(timeout: 5))
      let note = app.textFields["Tab note"]
      tapReady(note, app: app)
      note.typeText("local")
      let value = note.value as? String
      let keyboards = app.keyboards.count
      XCTAssertEqual(app.webViews.firstMatch.identifier, browserID)
      XCTAssertEqual(note.value as? String, value)
      XCTAssertLessThanOrEqual(app.keyboards.count, keyboards)
      XCTAssertTrue(app.staticTexts[token].exists)
    }
    tapReady(app.links["Open file 1"], app: app)
    b2InputWait(app.buttons["tab-1"], "selected == true")
    tapReady(app.buttons["b4-select-home"], app: app)
    b2InputWait(app.buttons["tab-0"], "selected == true")
    XCTAssertEqual(app.webViews.firstMatch.identifier, browserID)
    XCTAssertTrue(app.staticTexts[token].exists)
    XCTAssertTrue(app.buttons["tab-1"].exists)
  }
}
