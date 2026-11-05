import XCTest

@MainActor
final class InterfaceZoomSmokeTests: XCTestCase {
  func testThreeTabsExtremeHitsScrollFocusAndStateRetention() {
    continueAfterFailure = false
    let app = launch(reset: true)
    defer { app.terminate() }
    var tokens: [Int: String] = [:]
    for number in 1...3 {
      select(number, app: app)
      tokens[number] = token(app).label
      app.buttons["Zoom target"].tap()
      XCTAssertTrue(app.staticTexts["Hits 1; canvas 0"].waitForExistence(timeout: 5))
    }
    for (index, percent) in ["50%", "100%", "200%"].enumerated() {
      setPreset(percent, app: app)
      for number in 1...3 {
        select(number, app: app)
        XCTAssertEqual(token(app).label, tokens[number])
        XCTAssertTrue(app.staticTexts["Hits \(index + 1); canvas \(index)"].exists)
        let target = app.buttons["Zoom target"]
        ready(target)
        // Exercise a native coordinate tap, rather than JS dispatching a click.
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(
          app.staticTexts["Hits \(index + 2); canvas \(index)"].waitForExistence(timeout: 5))
        let canvas = app.buttons["Zoom canvas"]
        ready(canvas)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(
          app.staticTexts["Hits \(index + 2); canvas \(index + 1)"].waitForExistence(timeout: 5))
      }
    }
  }

  func testLocalNativeHitsScrollingAndFocusAt50Percent() {
    checkLocalScrollingAndFocus(percent: "50%")
  }

  func testLocalNativeHitsScrollingAndFocusAt75Percent() {
    checkLocalScrollingAndFocus(percent: "75%")
  }

  func testLocalNativeHitsScrollingAndFocusAt125Percent() {
    checkLocalScrollingAndFocus(percent: "125%")
  }

  func testLocalNativeHitsScrollingAndFocusAt150Percent() {
    checkLocalScrollingAndFocus(percent: "150%")
  }

  func testLocalNativeHitsScrollingAndFocusAt100Percent() {
    checkLocalScrollingAndFocus(percent: "100%")
  }

  func testLocalNativeHitsScrollingAndFocusAt200Percent() {
    checkLocalScrollingAndFocus(percent: "200%")
  }

  private func checkLocalScrollingAndFocus(percent: String) {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = launch(reset: true)
    defer { app.terminate() }
    setPreset(percent, app: app)
    let original = token(app).label
    let target = app.buttons["Zoom target"]
    ready(target)
    target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    let canvas = app.buttons["Zoom canvas"]
    ready(canvas)
    canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.staticTexts["Hits 1; canvas 1"].waitForExistence(timeout: 5))
    dragPanel(app, upward: true, context: "\(percent) before focus")
    let note = app.textFields["Zoom note"]
    ready(note)
    note.tap()
    note.typeText("local")
    let completeInput = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "local"), object: note)
    XCTAssertEqual(XCTWaiter.wait(for: [completeInput], timeout: 5), .completed)
    XCTAssertEqual(note.value as? String, "local")
    XCTAssertTrue(app.staticTexts["Focus note"].exists)
    setPreset("100%", app: app)
    XCTAssertEqual(note.value as? String, "local")
    XCTAssertTrue(app.staticTexts["Focus note"].exists)
    setPreset(percent, app: app)
    XCTAssertEqual(note.value as? String, "local")
    ready(app.buttons["End editing"])
    app.buttons["End editing"].tap()
    XCTAssertTrue(app.staticTexts["Focus none"].waitForExistence(timeout: 5))
    // A downward drag followed by an upward drag proves fresh movement after focus/zoom.
    dragPanel(app, upward: false, context: "\(percent) after focus, down")
    dragPanel(app, upward: true, context: "\(percent) after focus, up")
    XCTAssertEqual(note.value as? String, "local")
    XCTAssertEqual(token(app).label, original)
    XCTAssertTrue(app.staticTexts["Hits 1; canvas 1"].exists)
    XCTAssertEqual(app.buttons["interface-zoom-presets"].value as? String, percent)
  }

  private func scrollValue(_ app: XCUIApplication) -> Int? {
    let label = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^Scroll [0-9]+$'"))
      .firstMatch.label
    return Int(label.dropFirst("Scroll ".count))
  }

  private func dragPanel(_ app: XCUIApplication, upward: Bool, context: String) {
    let panel = app.webViews.firstMatch.otherElements["Zoom scroll, region"]
    XCTAssertTrue(panel.waitForExistence(timeout: 10), context)
    let visible = panel.frame.intersection(app.webViews.firstMatch.frame).intersection(app.frame)
    // The old 31-point region at 50% cannot satisfy this gesture contract.
    XCTAssertGreaterThanOrEqual(visible.height, 80, context)
    XCTAssertGreaterThanOrEqual(visible.width, 80, context)
    let origin = panel.coordinate(withNormalizedOffset: .zero)
    let x = visible.midX - panel.frame.minX
    let top = visible.minY - panel.frame.minY + visible.height * 0.2
    let bottom = visible.minY - panel.frame.minY + visible.height * 0.8
    let start = origin.withOffset(CGVector(dx: x, dy: upward ? bottom : top))
    let end = origin.withOffset(CGVector(dx: x, dy: upward ? top : bottom))
    let before = scrollValue(app)
    XCTAssertNotNil(before, context)
    let geometry = XCTAttachment(
      string:
        "\(context): panel=\(panel.frame), visible=\(visible), start=\(start.screenPoint), end=\(end.screenPoint), before=\(String(describing: before))"
    )
    geometry.name = "Zoom native gesture geometry"
    geometry.lifetime = .keepAlways
    add(geometry)
    let beforeHierarchy = XCTAttachment(string: app.debugDescription)
    beforeHierarchy.name = "Zoom before readiness \(context)"
    beforeHierarchy.lifetime = .keepAlways
    add(beforeHierarchy)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Zoom local fixture before readiness \(context)"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    // Keep the strict gate, but retain coordinates/hierarchy even when it fails.
    ready(panel)
    start.press(forDuration: 0.05, thenDragTo: end)
    let changed = NSPredicate { _, _ in
      guard let old = before, let current = self.scrollValue(app) else { return false }
      return upward ? current > old : current < old
    }
    let result = XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: changed, object: app)], timeout: 5)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "Zoom scroll result \(context)"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    XCTAssertEqual(result, .completed, context)
    if upward { XCTAssertGreaterThan(scrollValue(app) ?? 0, 0, context) }
  }

  func testRelaunchPresetsResetAndRotationRemainReachable() {
    continueAfterFailure = false
    let app = launch(reset: true)
    defer {
      app.terminate()
      XCUIDevice.shared.orientation = .portrait
    }
    setPreset("200%", app: app)
    XCTAssertFalse(app.buttons["interface-zoom-increase"].isEnabled)
    app.terminate()
    app.launchArguments = ["--interface-zoom-lab"]
    app.launch()
    XCTAssertTrue(app.buttons["interface-zoom-presets"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.buttons["interface-zoom-presets"].value as? String, "200%")
    XCUIDevice.shared.orientation = .landscapeLeft
    ready(app.buttons["interface-zoom-reset"])
    app.buttons["interface-zoom-reset"].tap()
    XCTAssertEqual(app.buttons["interface-zoom-presets"].value as? String, "100%")
    XCUIDevice.shared.orientation = .portrait
    ready(app.buttons["interface-zoom-decrease"])
    app.buttons["interface-zoom-decrease"].tap()
    XCTAssertEqual(app.buttons["interface-zoom-presets"].value as? String, "80%")
    setPreset("50%", app: app)
    XCTAssertFalse(app.buttons["interface-zoom-decrease"].isEnabled)
    app.buttons["interface-zoom-increase"].tap()
    XCTAssertEqual(app.buttons["interface-zoom-presets"].value as? String, "75%")
  }

  func testSafeFixtureSupportsNativeInterfaceZoom() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--interface-zoom-lab", "--interface-zoom-reset", "--interface-zoom-safe",
    ]
    app.launch()
    defer { app.terminate() }
    _ = token(app)
    // a5072ac moved interface zoom from the removed control row into the More menu.
    ready(app.buttons["browser-more"])
    app.buttons["browser-more"].tap()
    ready(app.buttons["Interface zoom"])
    app.buttons["Interface zoom"].tap()
    ready(app.buttons["200%"])
    app.buttons["200%"].tap()
    ready(app.buttons["Zoom target"])
    app.buttons["Zoom target"].tap()
    XCTAssertTrue(app.staticTexts["Hits 1; canvas 0"].waitForExistence(timeout: 5))
    // Zero Folio scripts/known handlers are asserted by InterfaceZoomTests, not inferred from this click.
  }

  private func launch(reset: Bool, safe: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--interface-zoom-lab"]
    if reset { app.launchArguments.append("--interface-zoom-reset") }
    if safe { app.launchArguments.append("--interface-zoom-safe") }
    app.launch()
    XCTAssertTrue(app.buttons["interface-zoom-presets"].waitForExistence(timeout: 15))
    _ = token(app)
    return app
  }

  private func select(_ number: Int, app: XCUIApplication) {
    ready(app.buttons["tab-\(number)"])
    app.buttons["tab-\(number)"].tap()
    XCTAssertTrue(app.buttons["tab-\(number)"].isSelected)
    _ = token(app)
  }

  private func token(_ app: XCUIApplication) -> XCUIElement {
    let result = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Zoom token '"))
      .firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 10))
    return result
  }

  private func setPreset(_ percent: String, app: XCUIApplication) {
    let control = app.buttons["interface-zoom-presets"]
    ready(control)
    control.tap()
    let item = app.buttons[percent].firstMatch
    ready(item)
    item.tap()
    let expected = NSPredicate(format: "value == %@", percent)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: expected, object: control)], timeout: 5),
      .completed)
  }

  private func ready(_ element: XCUIElement) {
    let expected = NSPredicate(format: "exists == true AND hittable == true")
    let result = XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: expected, object: element)], timeout: 10)
    if result != .completed {
      let attachment = XCTAttachment(string: XCUIApplication().debugDescription)
      attachment.name = "Zoom readiness hierarchy"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    XCTAssertEqual(result, .completed)
  }
}
