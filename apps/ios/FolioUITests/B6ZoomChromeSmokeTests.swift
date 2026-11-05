import XCTest

@MainActor
final class ZoomChromeSmokeTests: XCTestCase {
  private let scales = ["50%", "75%", "125%", "150%", "200%"]
  private let labels = [
    "northwest", "north", "northeast", "west", "center", "east", "southwest", "south", "southeast",
  ]

  func testPortraitFiveScaleViewportCoverageAndExactlyOneNativeActionPerTap() {
    checkCoverage(orientation: .portrait)
  }

  func testLandscapeFiveScaleViewportCoverageAndExactlyOneNativeActionPerTap() {
    checkCoverage(orientation: .landscapeLeft)
  }

  private func checkCoverage(orientation: UIDeviceOrientation) {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = orientation
    let app = launch()
    defer {
      app.terminate()
      XCUIDevice.shared.orientation = .portrait
    }
    let identity = token(app)
    for (index, scale) in scales.enumerated() {
      preset(scale, app)
      assertCoverage(app, scale: scale)
      capture(app, "\(orientation.rawValue) \(scale) before taps")
      let web = app.webViews.firstMatch
      for label in labels {
        let target = app.buttons["B6 \(label) \(index)"]
        ready(target)
        XCTAssertTrue(web.frame.contains(target.frame), "\(label) native bounds at \(scale)")
        // Corner buttons are tapped near the corresponding native viewport edges.
        let dx = label.contains("west") ? 0.08 : label.contains("east") ? 0.92 : 0.5
        var dy = label.hasPrefix("north") ? 0.08 : label.hasPrefix("south") ? 0.92 : 0.5
        // The existing 32-point Diagnostics overlay is outside B6 ownership.
        // Keep northeast actions below it; full CSS corner coverage is still asserted.
        if label == "northeast" { dy = max(dy, 48 / target.frame.height) }
        target.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
        XCTAssertTrue(app.buttons["B6 \(label) \(index + 1)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["B6 \(label) \(index + 2)"].exists, "Duplicate action")
      }
      XCTAssertEqual(token(app), identity)
      capture(app, "\(orientation.rawValue) \(scale) after taps")
    }
  }

  private func assertCoverage(_ app: XCUIApplication, scale: String) {
    let metric = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'B6 metrics '"))
      .firstMatch
    XCTAssertTrue(metric.waitForExistence(timeout: 10))
    let factor = Double(scale.dropLast())! / 100
    let settled = NSPredicate { _, _ in
      let values = metric.label.dropFirst("B6 metrics ".count).split(separator: " ").compactMap {
        Double($0)
      }
      return values.count == 8 && abs(values[0] * factor - app.webViews.firstMatch.frame.width) <= 2
    }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: settled, object: metric)], timeout: 10),
      .completed)
    let numbers = metric.label.dropFirst("B6 metrics ".count).split(separator: " ").compactMap {
      Double($0)
    }
    XCTAssertEqual(numbers.count, 8)
    guard numbers.count == 8 else { return }
    let web = app.webViews.firstMatch.frame
    XCTAssertEqual(numbers[0] * factor, web.width, accuracy: 2, "CSS numeric width")
    // Height with the software keyboard is separately captured by the edit/chrome case.
    XCTAssertEqual(numbers[1] * factor, web.height, accuracy: 2, "CSS numeric height")
    XCTAssertEqual(numbers[2], numbers[6], accuracy: 1, "CSS full viewport width")
    XCTAssertEqual(numbers[3], numbers[7], accuracy: 1, "CSS full viewport height")
    XCTAssertEqual(numbers[4], 0, accuracy: 1)
    XCTAssertEqual(numbers[5], 0, accuracy: 1)
    let nw = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'B6 northwest '"))
      .firstMatch.frame
    let ne = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'B6 northeast '"))
      .firstMatch.frame
    let sw = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'B6 southwest '"))
      .firstMatch.frame
    let se = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'B6 southeast '"))
      .firstMatch.frame
    XCTAssertEqual(nw.minX, web.minX, accuracy: 1)
    XCTAssertEqual(nw.minY, web.minY, accuracy: 1)
    XCTAssertEqual(ne.maxX, web.maxX, accuracy: 1)
    XCTAssertEqual(sw.maxY, web.maxY, accuracy: 1)
    XCTAssertEqual(se.maxX, web.maxX, accuracy: 1)
    XCTAssertEqual(se.maxY, web.maxY, accuracy: 1)
  }

  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--interface-zoom-lab", "--interface-zoom-reset", "--b6-zoom-geometry"]
    app.launch()
    ready(app.buttons["interface-zoom-presets"])
    _ = token(app)
    return app
  }

  private func token(_ app: XCUIApplication) -> String {
    let element = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'B6 token '"))
      .firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: 10))
    return element.label
  }

  private func preset(_ scale: String, _ app: XCUIApplication) {
    let control = app.buttons["interface-zoom-presets"]
    ready(control)
    control.tap()
    ready(app.buttons[scale].firstMatch)
    app.buttons[scale].firstMatch.tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", scale), object: control)
        ], timeout: 5), .completed)
  }

  private func capture(_ app: XCUIApplication, _ context: String) {
    for attachment in [
      XCTAttachment(screenshot: app.screenshot()), XCTAttachment(string: app.debugDescription),
    ] {
      attachment.name = "B6 \(context)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  private func ready(_ element: XCUIElement) {
    let result = XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
      ], timeout: 10)
    if result != .completed { capture(XCUIApplication(), "readiness failure") }
    XCTAssertEqual(result, .completed)
  }
}
