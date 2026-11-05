import XCTest

@MainActor
final class AuthPopupSmokeTests: XCTestCase {
  func testBlankAndLinkedOpenerMessagingAndClose() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--auth-lab"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Folio auth popup lab"].waitForExistence(timeout: 20))
    app.buttons["Open diagnostics"].tap()
    app.switches["Input logging"].tap()
    app.buttons["Close"].tap()
    for linked in [false, true] {
      if linked {
        app.links["Open linked popup"].tap()
      } else {
        app.buttons["Open blank popup"].tap()
      }
      XCTAssertTrue(
        app.staticTexts["PASS: opener acknowledgement received"].waitForExistence(timeout: 10))
      XCTAssertTrue(app.buttons["Close window"].isHittable)
      XCTAssertEqual(app.staticTexts["popupHost"].label, "Local test page")
      let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      before.name = "popup-before-tap"
      before.lifetime = .keepAlways
      add(before)
      let tree = XCTAttachment(string: app.debugDescription)
      tree.name = "popup-accessibility"
      tree.lifetime = .keepAlways
      add(tree)
      // Related WKWebViews expose correct frames but XCTest may return no automatic hit point.
      // Tap the reported center and verify the actual page action, without evaluating page JS.
      app.buttons["Try nested popup"].coordinate(
        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
      ).tap()
      XCTAssertTrue(app.staticTexts["PASS: nested rejected"].waitForExistence(timeout: 5))
      let popup = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      popup.name = linked ? "linked-popup-opener" : "blank-popup-opener"
      popup.lifetime = .keepAlways
      add(popup)
      if linked {
        app.buttons["Close window"].tap()
      } else {
        app.buttons["Close from page"].coordinate(
          withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
      }
      XCTAssertTrue(app.buttons["Open blank popup"].waitForExistence(timeout: 5))
      XCTAssertFalse(app.buttons["Close window"].exists)
      app.buttons["Open diagnostics"].tap()
      let report = app.textViews["diagnosticsReport"].value as? String ?? ""
      XCTAssertTrue(report.contains("Native keyboard popup-closed"))
      // Chrome restoration defaults OFF: record the request, without starting input.
      XCTAssertTrue(report.contains("Native keyboard restore-request-popupClosed"))
      XCTAssertFalse(report.contains("Native keyboard popupClosed"))
      app.buttons["Close"].tap()
      XCTAssertTrue(app.staticTexts["PASS: window.opener postMessage received"].exists)
    }
    app.links["Open blocked Google popup"].tap()
    XCTAssertTrue(app.staticTexts["popupNotice"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["popupNotice"].label.contains("Google sign-in cannot run"))
    XCTAssertTrue(app.buttons["Close window"].isHittable)
    XCTAssertFalse(app.staticTexts["Popup fixture"].exists)
    let blocked = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    blocked.name = "google-policy-message"
    blocked.lifetime = .keepAlways
    add(blocked)
    app.buttons["Close window"].tap()
    XCTAssertTrue(app.buttons["Open blank popup"].waitForExistence(timeout: 5))
    let parent = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    parent.name = "parent-opener-result"
    parent.lifetime = .keepAlways
    add(parent)
  }
  func testAuthLabCanLeaveForInputLabAndSafeMode() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--auth-lab"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Folio auth popup lab"].waitForExistence(timeout: 20))
    app.buttons["Open diagnostics"].tap()
    app.buttons["Input lab"].tap()
    XCTAssertTrue(app.staticTexts["Folio input lab"].waitForExistence(timeout: 20))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Folio auth popup lab"].waitForExistence(timeout: 20))
    app.buttons["Open diagnostics"].tap()
    app.buttons["Safe"].tap()
    app.buttons["Close"].tap()
    XCTAssertFalse(app.staticTexts["Folio auth popup lab"].exists)
    app.buttons["Open diagnostics"].tap()
    app.buttons["Normal"].tap()
    app.buttons["Close"].tap()
    XCTAssertFalse(app.staticTexts["Folio auth popup lab"].exists)
  }

}
