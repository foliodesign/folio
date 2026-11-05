import XCTest

@MainActor
final class B6TabsSmokeTests: XCTestCase {
  private func wait(_ element: XCUIElement, _ predicate: String) {
    let result = XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: predicate), object: element)
      ], timeout: 15)
    if result != .completed { recordFailure(XCUIApplication()) }
    XCTAssertEqual(result, .completed)
  }

  private func tap(_ element: XCUIElement, app: XCUIApplication) {
    let result = XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
      ], timeout: 15)
    if result != .completed { recordFailure(app) }
    XCTAssertEqual(result, .completed)
    guard result == .completed else { return }
    element.tap()
  }

  private func recordFailure(_ app: XCUIApplication) {
    let probe = app.buttons["Open developer tools"]
    let readiness = probe.exists ? probe.value ?? "unreturned" : "unattached"
    let detail = app.debugDescription + "\nNative readiness: \(readiness)"
    // Keep the console evidence usable if Xcode cannot finalize a failed xcresult.
    print(detail)
    let evidence = XCTAttachment(string: detail)
    evidence.lifetime = .keepAlways
    add(evidence)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  /// iOS 27.0 simulator remote AX can report these controls unhittable after a related
  /// window opens. Correct-frame native touches still deliver the exact fixture action.
  /// Limit this to Home's SPA/reopen links and the ordinary-route Increment/blank action.
  /// See tests/results/2026-10-20-tab-ui-gate.md. Keep ordinary tap checks everywhere else.
  private func tapVisibleFixtureControl(
    _ element: XCUIElement, app: XCUIApplication, outcome: XCUIElement, predicate: String
  ) {
    let visible = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        guard element.exists else { return false }
        let frame = element.frame
        return !frame.isEmpty && app.frame.contains(frame)
          && app.windows.firstMatch.frame.contains(frame)
      }, object: element)
    let result = XCTWaiter.wait(for: [visible], timeout: 15)
    if result != .completed { recordFailure(app) }
    XCTAssertEqual(result, .completed)
    guard result == .completed else { return }
    XCTAssertTrue(element.exists)
    XCTAssertFalse(element.frame.isEmpty)
    XCTAssertTrue(app.frame.contains(element.frame))
    XCTAssertTrue(app.windows.firstMatch.frame.contains(element.frame))
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    wait(outcome, predicate)
  }

  func testHomeDocumentCreationAndIndependentCloseOffline() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--browser-readiness", "--tab-route-evidence"]
    app.launch()
    defer { app.terminate() }
    wait(app.webViews.firstMatch.staticTexts["Local tab 0"], "exists == true")
    let homeID = app.webViews.firstMatch.identifier
    for (index, link) in ["Open file 1", "Open file 2 popup", "Open file 3 SPA link"].enumerated() {
      if index > 0 {
        tap(app.buttons["tab-0"], app: app)
        wait(app.buttons["tab-0"], "selected == true")
        wait(app.webViews.firstMatch.staticTexts["Local tab 0"], "exists == true")
        XCTAssertEqual(app.webViews.firstMatch.identifier, homeID)
      }
      if link == "Open file 3 SPA link" {
        tapVisibleFixtureControl(
          app.webViews.firstMatch.links[link], app: app,
          outcome: app.buttons["tab-3"], predicate: "selected == true")
      } else {
        tap(app.webViews.firstMatch.links[link], app: app)
      }
      wait(app.buttons["tab-\(index + 1)"], "selected == true")
      wait(app.buttons["tab-\(index + 1)"], "label == 'Local document \(index + 1)'")
    }
    tap(app.buttons["tab-0"], app: app)
    XCTAssertEqual(app.webViews.firstMatch.identifier, homeID)
    wait(app.buttons["tab-0"], "selected == true")
    wait(app.webViews.firstMatch.staticTexts["Local tab 0"], "exists == true")
    // PR #121: 992cedf reloads the dashboard if an observed file URL escaped the navigation
    // decision, including late callbacks after Home became inactive.
    // Require restored Home in the same WebView, not the pre-navigation DOM.
    XCTAssertFalse(app.buttons["tab-close-0"].exists)
    tapVisibleFixtureControl(
      app.webViews.firstMatch.links["Open file 1"], app: app,
      outcome: app.buttons["tab-1"], predicate: "selected == true")
    XCTAssertFalse(app.buttons["tab-4"].exists)
    tap(app.buttons["tab-0"], app: app)
    wait(app.webViews.firstMatch.staticTexts["Local tab 0"], "exists == true")
    XCTAssertEqual(app.webViews.firstMatch.identifier, homeID)
    let restoredToken = app.webViews.firstMatch.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH 'Load token '")
    ).firstMatch
    wait(restoredToken, "exists == true")
    let homeToken = restoredToken.label
    tap(app.buttons["tab-1"], app: app)
    wait(app.buttons["tab-1"], "selected == true")
    // Native creation/selection/close never navigates Home. Its restored token
    // must survive those operations unchanged.
    // Native horizontal scrolling reveals the right end. Chrome keeps ordinary AX taps.
    let create = app.buttons["browser-create-design"]
    for _ in 0..<5 where !create.isHittable { app.scrollViews.firstMatch.swipeLeft() }
    tap(create, app: app)
    wait(app.buttons["tab-4"], "selected == true")
    wait(app.webViews.firstMatch.staticTexts["Local tab 4"], "exists == true")
    for _ in 0..<5 where !create.isHittable { app.scrollViews.firstMatch.swipeLeft() }
    tap(create, app: app)
    wait(app.buttons["tab-5"], "selected == true")
    wait(app.webViews.firstMatch.staticTexts["Local tab 5"], "exists == true")
    // PR #121: ChromeTabView is one AX element; its inline close is a custom action.
    // Use the existing native overflow command instead of a nonexistent test id.
    tap(app.buttons["browser-more"], app: app)
    tap(app.buttons["Close tab"], app: app)
    XCTAssertFalse(app.buttons["tab-5"].exists)
    XCTAssertTrue(app.buttons["tab-4"].exists)
    tap(app.buttons["tab-0"], app: app)
    XCTAssertEqual(app.webViews.firstMatch.identifier, homeID)
    wait(app.buttons["tab-0"], "selected == true")
    wait(app.webViews.firstMatch.staticTexts[homeToken], "exists == true")
    tap(app.buttons["browser-more"], app: app)
    wait(app.buttons["Close tab"], "exists == true")
    XCTAssertFalse(app.buttons["Close tab"].isEnabled)
  }

  func testOrdinaryLocationWindowOpenAndBlankFirstKeepSource() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--tabs-lab", "--b6-routes", "--browser-readiness", "--tab-route-evidence",
    ]
    app.launch()
    defer { app.terminate() }
    wait(app.webViews.firstMatch.staticTexts["Local tab 0"], "exists == true")
    let homeID = app.webViews.firstMatch.identifier
    var documentIDs: [String] = []
    for (index, label) in [
      "Open ordinary location", "Open location replace", "Open window file", "Open blank child",
    ]
    .enumerated() {
      if index > 0 { tap(app.buttons["tab-0"], app: app) }
      if label == "Open blank child" {
        tapVisibleFixtureControl(
          app.webViews.firstMatch.buttons[label], app: app,
          outcome: app.buttons["tab-4"], predicate: "selected == true")
      } else {
        tap(app.webViews.firstMatch.buttons[label], app: app)
      }
      wait(app.buttons["tab-\(index + 1)"], "selected == true")
      wait(app.webViews.firstMatch.staticTexts["Local tab \(index + 1)"], "exists == true")
      documentIDs.append(app.webViews.firstMatch.identifier)
      tapVisibleFixtureControl(
        app.webViews.firstMatch.buttons["Increment"], app: app,
        outcome: app.webViews.firstMatch.staticTexts["Count 1"], predicate: "exists == true")
    }
    tap(app.buttons["tab-0"], app: app)
    XCTAssertEqual(app.webViews.firstMatch.identifier, homeID)
    wait(app.webViews.firstMatch.staticTexts["Local tab 0"], "exists == true")
    // Home may reload through 992cedf's observed-URL fallback. Native Home
    // identity is fixed; each document must retain its own live view and Count 1.
    XCTAssertFalse(app.buttons["tab-5"].exists)
    for (index, documentID) in documentIDs.enumerated() {
      tap(app.buttons["tab-\(index + 1)"], app: app)
      wait(app.buttons["tab-\(index + 1)"], "selected == true")
      wait(app.webViews.firstMatch.staticTexts["Count 1"], "exists == true")
      XCTAssertEqual(app.webViews.firstMatch.identifier, documentID)
    }
    tap(app.buttons["tab-0"], app: app)
    wait(app.webViews.firstMatch.staticTexts["Local tab 0"], "exists == true")
    XCTAssertEqual(app.webViews.firstMatch.identifier, homeID)
  }

  func testPureButtonSPAOpensDocumentAndRestoresHome() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--browser-readiness", "--tab-route-evidence"]
    app.launch()
    defer { app.terminate() }
    wait(app.webViews.firstMatch.staticTexts["Local tab 0"], "exists == true")
    let homeID = app.webViews.firstMatch.identifier
    tap(app.webViews.firstMatch.buttons["Open file 3 SPA"], app: app)
    wait(app.buttons["tab-1"], "selected == true")
    wait(app.webViews.firstMatch.staticTexts["Local tab 1"], "exists == true")
    tap(app.buttons["tab-0"], app: app)
    wait(app.webViews.firstMatch.staticTexts["Local tab 0"], "exists == true")
    XCTAssertEqual(app.webViews.firstMatch.identifier, homeID)
    XCTAssertTrue(app.webViews.firstMatch.buttons["Open file 3 SPA"].exists)
  }

  func testEditorDelayedDuplicateOpensNewTabAndRetainsSource() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--b6-routes", "--browser-readiness"]
    app.launch()
    defer { app.terminate() }
    tap(app.webViews.firstMatch.links["Open file 1"], app: app)
    wait(app.buttons["tab-1"], "selected == true")
    tap(app.webViews.firstMatch.buttons["Increment"], app: app)
    wait(app.webViews.firstMatch.staticTexts["Count 1"], "exists == true")
    let sourceID = app.webViews.firstMatch.identifier
    tap(app.webViews.firstMatch.buttons["Duplicate after delay"], app: app)
    wait(app.buttons["tab-2"], "selected == true")
    wait(app.webViews.firstMatch.staticTexts["Local tab 2"], "exists == true")
    XCTAssertFalse(app.buttons["tab-3"].exists)
    tap(app.buttons["tab-1"], app: app)
    wait(app.buttons["tab-1"], "selected == true")
    wait(app.webViews.firstMatch.staticTexts["Count 1"], "exists == true")
    XCTAssertEqual(app.webViews.firstMatch.identifier, sourceID)
  }

}
