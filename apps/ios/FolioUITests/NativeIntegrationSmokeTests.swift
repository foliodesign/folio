import XCTest

@MainActor
final class NativeIntegrationSmokeTests: XCTestCase {
  override func tearDownWithError() throws {
    let app = XCUIApplication()
    if let testRun, testRun.failureCount > 0 {
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "Export system hierarchy"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
      add(XCTAttachment(screenshot: app.screenshot()))
    }
    app.terminate()
    try super.tearDownWithError()
  }

  func testBlobAndDataExportChoices() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--native-lab", "--browser-readiness"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Native integration lab"].waitForExistence(timeout: 20))
    app.buttons["Download blob"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 15))
    app.alerts.buttons["Share"].tap()
    XCTAssertTrue(app.otherElements["ShareSheet.RemoteContainerView"].waitForExistence(timeout: 10))
    b3DismissShare(app)
    XCTAssertTrue(app.alerts["Export ready"].waitForNonExistence(timeout: 10))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Native integration lab"].waitForExistence(timeout: 20))
    app.links["Download data"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 15))
    app.alerts.buttons["Save to Files"].tap()
    XCTAssertTrue(
      app.otherElements["folioExportFiles"].waitForExistence(timeout: 10), app.debugDescription)
    let cancel = app.buttons["Cancel"].firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
    cancel.tap()
    XCTAssertTrue(app.otherElements["folioExportFiles"].waitForNonExistence(timeout: 10))
    app.buttons["Download blob"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 15))
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForNonExistence(timeout: 10))
  }

  func testExternalLinkSuspendsExportChoice() throws {
    try externalLinkSuspendsExport(action: "Export ready")
  }

  func testExternalLinkSuspendsShareSheet() throws {
    try externalLinkSuspendsExport(action: "Share")
  }

  func testExternalLinkSuspendsFilesSheet() throws {
    try externalLinkSuspendsExport(action: "Save to Files")
  }

  private func externalLinkSuspendsExport(action: String) throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    let link = try XCTUnwrap(URL(string: "folio://open?url=https%3A%2F%2Fwww.figma.com%2Ffiles"))
    app.launchArguments = ["--native-lab", "--browser-readiness"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Native integration lab"].waitForExistence(timeout: 20))
    let sourceTab = app.buttons.matching(
      NSPredicate(format: "selected == true AND identifier BEGINSWITH 'tab-'")
    )
    .firstMatch.identifier
    XCTAssertFalse(sourceTab.isEmpty)
    app.buttons["Download blob"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 15))
    if action != "Export ready" {
      app.alerts.buttons[action].tap()
      let sheet =
        action == "Share"
        ? app.otherElements["ShareSheet.RemoteContainerView"]
        : app.otherElements["folioExportFiles"]
      XCTAssertTrue(sheet.waitForExistence(timeout: 10))
    }
    let oldChoiceCount = app.alerts.matching(identifier: "Export ready").count
    XCTAssertLessThanOrEqual(oldChoiceCount, 1)
    b3CaptureDownloadHierarchy(app, stage: action + " before delivery")
    app.open(link)
    XCTAssertTrue(app.buttons["tab-0"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.alerts["Export ready"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.otherElements["folioExportFiles"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(
      app.otherElements["ShareSheet.RemoteContainerView"].waitForNonExistence(timeout: 10))
    let destination = app.buttons.matching(
      NSPredicate(format: "selected == true AND identifier BEGINSWITH 'tab-'")
    ).firstMatch
    XCTAssertTrue(destination.exists, app.debugDescription)
    XCTAssertNotEqual(destination.identifier, sourceTab, app.debugDescription)
    b3CaptureDownloadHierarchy(app, stage: action + " destination, old sheet gone")
    app.buttons[sourceTab].tap()
    b3CaptureDownloadHierarchy(app, stage: action + " source selected")
    XCTAssertTrue(app.buttons[sourceTab].isSelected)
    XCTAssertTrue(app.staticTexts["Native integration lab"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 10), app.debugDescription)
    b3CaptureDownloadHierarchy(app, stage: action + " resumed choice attached")
    XCTAssertEqual(app.alerts.matching(identifier: "Export ready").count, 1)
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Native integration lab"].waitForExistence(timeout: 10))
    app.links["Download data"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.alerts.matching(identifier: "Export ready").count, 1)
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForNonExistence(timeout: 10))
    app.terminate()
  }

  func testExternalLinkSuspendsRetainedPreviewAndResumesOneExport() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--native-lab", "--browser-readiness"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Native integration lab"].waitForExistence(timeout: 20))
    let source = app.buttons.matching(
      NSPredicate(format: "selected == true AND identifier BEGINSWITH 'tab-'")
    ).firstMatch.identifier
    XCTAssertFalse(source.isEmpty)
    app.buttons["Download PNG"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 15))
    app.alerts.buttons["Downloads"].tap()
    let row = app.tables["folioDownloadList"].cells.containing(
      .staticText, identifier: "local-fixture.png"
    ).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    app.buttons["Open"].tap()
    let preview = app.otherElements["folioDownloadPreview"]
    XCTAssertTrue(preview.waitForExistence(timeout: 10))
    XCTAssertTrue(preview.isHittable, app.debugDescription)
    XCTAssertTrue(b3AssertRenderedPNG(in: preview))
    XCTAssertTrue(app.buttons["folioDownloadPreviewClose"].isHittable, app.debugDescription)
    preview.tap()
    XCTAssertTrue(app.buttons["folioDownloadPreviewClose"].isHittable, app.debugDescription)
    XCTAssertTrue(b3AssertRenderedPNG(in: preview))
    b3CaptureDownloadHierarchy(app, stage: "retained QuickLook before delivery")
    app.open(try XCTUnwrap(URL(string: "folio://open?url=https%3A%2F%2Fwww.figma.com%2Ffiles")))
    XCTAssertTrue(preview.waitForNonExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(app.buttons["folioDownloadPreviewClose"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.tables["folioDownloadList"].waitForNonExistence(timeout: 10))
    let destination = app.buttons.matching(
      NSPredicate(format: "selected == true AND identifier BEGINSWITH 'tab-'")
    ).firstMatch
    XCTAssertTrue(destination.exists, app.debugDescription)
    XCTAssertNotEqual(destination.identifier, source, app.debugDescription)
    b3CaptureDownloadHierarchy(app, stage: "retained QuickLook destination, ancestors gone")
    app.buttons[source].tap()
    XCTAssertTrue(app.buttons[source].isSelected, app.debugDescription)
    b3CaptureDownloadHierarchy(app, stage: "retained QuickLook source selected")
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 10))
    b3CaptureDownloadHierarchy(app, stage: "retained QuickLook resumed choice attached")
    XCTAssertEqual(app.alerts.matching(identifier: "Export ready").count, 1)
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForNonExistence(timeout: 10))
    app.links["Download data"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.alerts.matching(identifier: "Export ready").count, 1)
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForNonExistence(timeout: 10))
  }

  func testColdAndWarmSchemeDelivery() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    var link = URLComponents()
    link.scheme = "folio"
    link.host = "open"
    link.queryItems = [
      URLQueryItem(name: "url", value: "https://www.figma.com/files?node-id=1%3A2#linkLoadFragment")
    ]
    let url = try XCTUnwrap(link.url)
    app.launchArguments = ["--native-lab", "--browser-readiness"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Native integration lab"].waitForExistence(timeout: 20))
    app.open(url)
    app.buttons["Open diagnostics"].tap()
    let report = app.textViews["diagnosticsReport"]
    XCTAssertTrue(report.waitForExistence(timeout: 10))
    let text = try XCTUnwrap(report.value as? String)
    XCTAssertTrue(text.contains("External link: www.figma.com/files"))
    XCTAssertFalse(text.contains("node-id"))
    XCTAssertFalse(text.contains("linkLoadFragment"))
    app.terminate()
    app.launchArguments = []
    app.open(url)
    XCTAssertTrue(app.buttons["Open diagnostics"].waitForExistence(timeout: 15))
    app.buttons["Open diagnostics"].tap()
    XCTAssertTrue(report.waitForExistence(timeout: 10))
    let coldText = try XCTUnwrap(report.value as? String)
    XCTAssertTrue(coldText.contains("External link: www.figma.com/files"))
    XCTAssertFalse(coldText.contains("node-id"))
    XCTAssertFalse(coldText.contains("linkLoadFragment"))
  }

  func testFileInputPresentsSystemChoices() {
    let app = XCUIApplication()
    app.launchArguments = ["--native-lab", "--browser-readiness"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Native integration lab"].waitForExistence(timeout: 20))
    app.webViews.buttons["Import image"].tap()
    // Device checklist verifies exact Photos/Files choices and successful import.
    XCTAssertTrue(app.buttons["Choose File"].waitForExistence(timeout: 10))
  }
}
