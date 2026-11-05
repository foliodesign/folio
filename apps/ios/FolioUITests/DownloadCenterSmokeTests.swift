import UIKit
import XCTest

@MainActor
final class DownloadCenterSmokeTests: XCTestCase {
  override func tearDownWithError() throws {
    let app = XCUIApplication()
    if let testRun, testRun.failureCount > 0 {
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "Download Center system hierarchy"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
      add(XCTAttachment(screenshot: app.screenshot()))
    }
    app.terminate()
    try super.tearDownWithError()
  }

  private func launchLab(_ app: XCUIApplication) {
    app.launchArguments = ["--native-lab", "--browser-readiness"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Native integration lab"].waitForExistence(timeout: 20))
  }
  private func openFromChoice(_ app: XCUIApplication) {
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 15))
    app.alerts.buttons["Downloads"].tap()
    XCTAssertTrue(app.tables["folioDownloadList"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.alerts["Export ready"].waitForNonExistence(timeout: 10))
  }
  private func row(_ app: XCUIApplication, name: String) -> XCUIElement {
    app.tables["folioDownloadList"].cells.containing(.staticText, identifier: name).firstMatch
  }
  private func cancelSystemSheet(_ app: XCUIApplication, action: String) {
    if action == "Open" {
      let preview = app.otherElements["folioDownloadPreview"]
      XCTAssertTrue(preview.exists && preview.isHittable, app.debugDescription)
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "Attached local QuickLook before close"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
      let rendered = XCTAttachment(screenshot: app.screenshot())
      rendered.name = "Attached local QuickLook render"
      rendered.lifetime = .keepAlways
      add(rendered)
      // Close is outside QuickLook's optional tap-to-hide chrome.
      let close = app.buttons["folioDownloadPreviewClose"]
      XCTAssertTrue(close.waitForExistence(timeout: 10), app.debugDescription)
      XCTAssertTrue(close.isHittable, app.debugDescription)
      XCTAssertFalse(app.buttons["folioDownloadsDone"].isHittable, app.debugDescription)
      // Tapping the rendered content must not hide Folio's dismissal control.
      preview.tap()
      XCTAssertTrue(close.isHittable, app.debugDescription)
      close.tap()
    } else if action == "Share" {
      b3DismissShare(app)
    } else {
      let cancel = app.buttons["Cancel"].firstMatch
      XCTAssertTrue(cancel.waitForExistence(timeout: 10))
      cancel.tap()
    }
  }

  func testPhotosActionIsGatedWithoutRequestingPermission() {
    continueAfterFailure = false
    let app = XCUIApplication()
    launchLab(app)
    app.buttons["Download blob"].tap()
    openFromChoice(app)
    row(app, name: "blob-export.txt").tap()
    XCTAssertTrue(app.buttons["Save to Files"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["Save to Photos"].exists)
    dismissCenterActions(app)
    app.buttons["folioDownloadsDone"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 10))
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForNonExistence(timeout: 10))
    app.buttons["Download PNG"].tap()
    openFromChoice(app)
    row(app, name: "local-fixture.png").tap()
    XCTAssertTrue(app.buttons["Save to Photos"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Save to Photos"].isHittable)
    // Permission decisions belong to the owner. Native tests inject outcomes.
    dismissCenterActions(app)
    app.buttons["folioDownloadsDone"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 10))
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForNonExistence(timeout: 10))
  }

  func testB3RenderEvidenceRejectsBlankAndSingleColor() {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160))
    let blank = renderer.image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
    }
    XCTAssertFalse(B3DownloadsRenderEvidence.containsFixture(blank))
    let blue = renderer.image { context in
      UIColor(red: 23 / 255, green: 105 / 255, blue: 224 / 255, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
    }
    XCTAssertFalse(B3DownloadsRenderEvidence.containsFixture(blue))
    let fixture = renderer.image { context in
      UIColor(red: 23 / 255, green: 105 / 255, blue: 224 / 255, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 80, height: 160))
      UIColor(red: 1, green: 158 / 255, blue: 36 / 255, alpha: 1).setFill()
      context.fill(CGRect(x: 80, y: 0, width: 80, height: 160))
    }
    XCTAssertTrue(B3DownloadsRenderEvidence.containsFixture(fixture))
  }

  func testOpenShareFilesCancellationKeepsFixtureAndDeleteClearsChoice() {
    continueAfterFailure = false
    let app = XCUIApplication()
    launchLab(app)
    app.buttons["Download blob"].tap()
    openFromChoice(app)
    let fixture = row(app, name: "blob-export.txt")
    XCTAssertTrue(fixture.waitForExistence(timeout: 10))
    let id = fixture.identifier
    XCTAssertFalse(id.isEmpty)
    for action in ["Open", "Share", "Save to Files"] {
      app.cells[id].tap()
      XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 10))
      app.buttons[action].tap()
      let sheet: XCUIElement
      if action == "Open" {
        sheet = app.otherElements["folioDownloadPreview"]
      } else if action == "Share" {
        sheet = app.otherElements["ShareSheet.RemoteContainerView"]
      } else {
        sheet = app.otherElements["folioDownloadFiles"]
      }
      XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription)
      b3CaptureDownloadHierarchy(app, stage: "Center " + action + " attached")
      cancelSystemSheet(app, action: action)
      XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
      XCTAssertTrue(app.cells[id].exists)
      XCTAssertTrue(app.cells[id].isHittable, app.debugDescription)
      XCTAssertTrue(app.buttons["folioDownloadsDone"].isHittable, app.debugDescription)
    }
    app.cells[id].tap()
    app.buttons["Delete"].tap()
    XCTAssertTrue(app.cells[id].waitForNonExistence(timeout: 10))
    app.buttons["folioDownloadsDone"].tap()
    XCTAssertTrue(app.tables["folioDownloadList"].waitForNonExistence(timeout: 10))
    XCTAssertFalse(app.alerts["Export ready"].exists)
    app.links["Download data"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 15))
    app.alerts.buttons["Cancel"].tap()
  }

  func testCompletedLocalIDSurvivesRelaunchAndOpensWithoutEditorPreview() {
    continueAfterFailure = false
    let app = XCUIApplication()
    launchLab(app)
    let sourceTab = app.buttons.matching(
      NSPredicate(format: "selected == true AND identifier BEGINSWITH 'tab-'")
    ).firstMatch.identifier
    XCTAssertFalse(sourceTab.isEmpty)
    app.buttons["Download PNG"].tap()
    openFromChoice(app)
    let png = row(app, name: "local-fixture.png")
    XCTAssertTrue(png.waitForExistence(timeout: 10))
    let id = png.identifier
    XCTAssertFalse(id.isEmpty)
    app.terminate()
    launchLab(app)
    let restoredSource = app.buttons.matching(
      NSPredicate(format: "selected == true AND identifier BEGINSWITH 'tab-'")
    ).firstMatch.identifier
    XCTAssertFalse(restoredSource.isEmpty)
    // This branch supplies a callable host entry, but does not own host chrome.
    // A fresh local export gives the test access through its Downloads action.
    app.links["Download data"].tap()
    openFromChoice(app)
    XCTAssertTrue(app.cells[id].waitForExistence(timeout: 10))
    app.cells[id].tap()
    app.buttons["Open"].tap()
    XCTAssertTrue(
      app.otherElements["folioDownloadPreview"].waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(b3AssertRenderedPNG(in: app.otherElements["folioDownloadPreview"]))
    cancelSystemSheet(app, action: "Open")
    XCTAssertTrue(app.otherElements["folioDownloadPreview"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.buttons["folioDownloadPreviewClose"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.cells[id].isHittable, app.debugDescription)
    for action in ["Share", "Save to Files"] {
      app.cells[id].tap()
      app.buttons[action].tap()
      let sheet =
        action == "Share"
        ? app.otherElements["ShareSheet.RemoteContainerView"]
        : app.otherElements["folioDownloadFiles"]
      XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription)
      cancelSystemSheet(app, action: action)
      XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), app.debugDescription)
      XCTAssertTrue(app.cells[id].exists)
      XCTAssertTrue(app.cells[id].isHittable, app.debugDescription)
      XCTAssertTrue(app.buttons["folioDownloadsDone"].isHittable, app.debugDescription)
    }
    app.cells[id].tap()
    app.buttons["Delete"].tap()
    XCTAssertTrue(app.cells[id].waitForNonExistence(timeout: 10))
    app.buttons["folioDownloadsDone"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 10))
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.buttons[restoredSource].isSelected)
    XCTAssertTrue(app.staticTexts["Native integration lab"].exists)
    app.buttons["Download blob"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.alerts.matching(identifier: "Export ready").count, 1)
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForNonExistence(timeout: 10))
    XCTAssertEqual(
      app.buttons.matching(
        NSPredicate(format: "selected == true AND identifier BEGINSWITH 'tab-'")
      ).count, 1)
  }

  func testCenterCloseResumesExactlyOnePendingChoiceAndSecondExport() {
    continueAfterFailure = false
    let app = XCUIApplication()
    launchLab(app)
    app.buttons["Download blob"].tap()
    openFromChoice(app)
    app.buttons["folioDownloadsDone"].tap()
    XCTAssertTrue(app.tables["folioDownloadList"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.alerts.matching(identifier: "Export ready").count, 1)
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForNonExistence(timeout: 10))
    app.links["Download data"].tap()
    XCTAssertTrue(app.alerts["Export ready"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.alerts.matching(identifier: "Export ready").count, 1)
    app.alerts.buttons["Cancel"].tap()
  }
  func testOverLimitFixtureAppearsFailedAndCanBeDeleted() {
    continueAfterFailure = false
    let app = XCUIApplication()
    launchLab(app)
    app.buttons["Download over limit"].tap()
    app.buttons["Download blob"].tap()
    openFromChoice(app)
    let failed = app.tables["folioDownloadList"].cells.containing(.staticText, identifier: "Failed")
      .firstMatch
    XCTAssertTrue(failed.waitForExistence(timeout: 15))
    let id = failed.identifier
    XCTAssertFalse(id.isEmpty)
    failed.tap()
    app.buttons["Delete"].tap()
    XCTAssertTrue(app.cells[id].waitForNonExistence(timeout: 10))
  }

  private func dismissCenterActions(_ app: XCUIApplication) {
    app.navigationBars["Downloads"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .tap()
    XCTAssertTrue(app.buttons["Save to Files"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.otherElements["folioDownloadCenter"].exists)
    XCTAssertTrue(app.buttons["folioDownloadsDone"].isHittable)
  }

}
