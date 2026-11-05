import XCTest

@MainActor
final class ColdKeyboardRoutingTests: XCTestCase {
  // Routing-only comparison can run with a software keyboard. Hardware absence is
  // separately asserted by HardwareKeyboardSmokeTests, never inferred here.
  func testColdLaunchDeliversKeysWithoutPageInteraction() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--keyboard-cold", "--keyboard-all-off", "--smoke-report"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["Local tab 0"].waitForExistence(timeout: 20))
    app.typeKey("v", modifierFlags: [])
    let keys = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Keys '")).firstMatch
    expectation(
      for: NSPredicate(format: "label CONTAINS 'v:1:prevented=false'"), evaluatedWith: keys)
    waitForExpectations(timeout: 5)
    XCTAssertFalse(keys.label.contains("v:2:"))
    print("H1_COLD_ROUTING \(keys.label) softwareKeyboards=\(app.keyboards.count)")
  }
}

extension ColdKeyboardRoutingTests {
  func testB3NewTabDeliversFirstKeyWithoutDestinationInteraction() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--tabs-lab", "--keyboard-cold", "--keyboard-all-off"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["Local tab 0"].waitForExistence(timeout: 20))
    let link = app.links["Open file 1"]
    XCTAssertTrue(link.isHittable)
    link.tap()
    XCTAssertTrue(app.staticTexts["Local tab 1"].waitForExistence(timeout: 10))
    // No tap, focus command or background workaround in the new page.
    app.typeKey("v", modifierFlags: [])
    let keys = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Keys '")).firstMatch
    let delivered = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS 'v:1:prevented=false'"), object: keys)
    XCTAssertEqual(XCTWaiter.wait(for: [delivered], timeout: 5), .completed)
    XCTAssertFalse(keys.label.contains("v:2:"))
    // Strict zero-software-keyboard cases remain in HardwareKeyboardSmokeTests.
  }
}
