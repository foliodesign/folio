import XCTest

@testable import Folio

@MainActor
final class PhoneToolPillTests: XCTestCase {
  func testGroupCyclesFollowMenuOrderWithoutImage() {
    XCTAssertEqual(
      PhoneToolPill.cycles,
      [
        [.move, .hand, .scale], [.move], [.frame, .section, .slice],
        [.rectangle, .line, .arrow, .ellipse], [.pen, .pencil], [.text], [.measurement],
        [.annotation], [.comment],
      ])
  }

  func testLayoutMirrorsFigmasRowForTheMode() {
    let design = Set(PhonePillLogic.designTools)
    let dev = Set(PhonePillLogic.devTools)
    // No row yet: the mode's verified row, Design when unknown.
    XCTAssertTrue(PhonePillLogic.layout(reported: [], mode: .unknown) == (design, false))
    XCTAssertTrue(PhonePillLogic.layout(reported: [], mode: .dev) == (dev, true))
    // The reported row wins when it agrees; Hand replaces Move's button.
    XCTAssertTrue(
      PhonePillLogic.layout(reported: [.hand, .measurement, .comment], mode: .dev)
        == ([.move, .measurement, .comment], true))
    XCTAssertTrue(
      PhonePillLogic.layout(reported: [.move, .comment], mode: .design)
        == ([.move, .comment], false))
    // An unknown mode follows the row's own markers.
    XCTAssertTrue(
      PhonePillLogic.layout(reported: PhonePillLogic.devTools, mode: .unknown) == (dev, true))
    // A Dev tap not yet confirmed: the stale Design row gives way to Dev's.
    XCTAssertTrue(
      PhonePillLogic.layout(reported: PhonePillLogic.designTools, mode: .dev) == (dev, true))
    XCTAssertTrue(
      PhonePillLogic.layout(reported: PhonePillLogic.devTools, mode: .design) == (design, false))
  }

  func testTappingTheActiveGroupStepsThroughItsCycleAndWraps() {
    for cycle in PhoneToolPill.cycles where cycle.count > 1 {
      var tool = cycle[0]
      var seen: [PhoneTool] = []
      for _ in cycle {
        seen.append(tool)
        tool = PhonePillLogic.tap(face: tool, current: tool, cycle: cycle)
      }
      XCTAssertEqual(seen, cycle)
      XCTAssertEqual(tool, cycle[0])
    }
  }

  func testAnInactiveGroupSelectsItsShownTool() {
    let shapes: [PhoneTool] = [.rectangle, .line, .arrow, .ellipse]
    XCTAssertEqual(PhonePillLogic.tap(face: .arrow, current: .move, cycle: shapes), .arrow)
    XCTAssertEqual(PhonePillLogic.tap(face: .arrow, current: nil, cycle: shapes), .arrow)
    XCTAssertEqual(PhonePillLogic.tap(face: .text, current: .text, cycle: [.text]), .text)
  }

  func testModeSegmentSendsShiftDOnlyForAChange() {
    XCTAssertFalse(PhonePillLogic.sendsToggle(tapped: .design, current: .design))
    XCTAssertFalse(PhonePillLogic.sendsToggle(tapped: .dev, current: .dev))
    XCTAssertTrue(PhonePillLogic.sendsToggle(tapped: .dev, current: .design))
    XCTAssertTrue(PhonePillLogic.sendsToggle(tapped: .design, current: .dev))
    XCTAssertTrue(PhonePillLogic.sendsToggle(tapped: .design, current: .unknown))
    XCTAssertTrue(PhonePillLogic.sendsToggle(tapped: .dev, current: .unknown))
  }

  func testPhoneStateCarriesAFixedMode() {
    var payload: [String: Any] = [
      "panel": "none", "tool": "move", "mode": "dev", "minimize": true, "overlay": false,
      "visibleTools": ["Move-tool", "Hand tool-tool", "Measurement-tool", "Annotation-tool"],
      "left": 0, "right": 0, "panelLeft": 0, "panelRight": 0,
    ]
    XCTAssertEqual(PhoneLayoutState.validate(payload)?.mode, .dev)
    XCTAssertEqual(
      PhoneLayoutState.validate(payload)?.visibleTools, [.move, .hand, .measurement, .annotation])
    payload["visibleTools"] = ["Move-tool", "Move-tool"]
    XCTAssertNil(PhoneLayoutState.validate(payload))
    payload["visibleTools"] = ["arbitrary-document-text"]
    XCTAssertNil(PhoneLayoutState.validate(payload))
    payload["visibleTools"] = ["Move-tool"]
    XCTAssertEqual(PhoneLayoutState.validate(payload)?.overlay, false)
    payload["overlay"] = true
    XCTAssertEqual(PhoneLayoutState.validate(payload)?.overlay, true)
    payload["overlay"] = "yes"
    XCTAssertNil(PhoneLayoutState.validate(payload))
    payload["overlay"] = false
    payload["mode"] = "Dev Mode"
    XCTAssertNil(PhoneLayoutState.validate(payload))
    payload.removeValue(forKey: "mode")
    XCTAssertNil(PhoneLayoutState.validate(payload))
  }

  /// One source for the sheet top: the floor native sends to the page (top = height × (1 − floor),
  /// matching phone-layout.ts) leaves `want` points above the keyboard, capped at 0.85.
  func testSheetFloorLeavesRoomAboveTheKeyboardOnly() {
    XCTAssertEqual(BrowserWindowController.sheetFloor(height: 694, overlap: 0, want: 120), 0)
    let floor = BrowserWindowController.sheetFloor(height: 694, overlap: 300, want: 120)
    XCTAssertEqual(694 * (1 - floor), 694 - 300 - 120, accuracy: 0.001)
    XCTAssertEqual(BrowserWindowController.sheetFloor(height: 694, overlap: 600, want: 172), 0.85)
    // A small overlap gives a floor under the smallest sheet height (0.25), so no raise.
    XCTAssertLessThan(BrowserWindowController.sheetFloor(height: 694, overlap: 10, want: 120), 0.25)
    XCTAssertEqual(
      PhoneFieldState.validate(["numeric": true]), PhoneFieldState(numeric: true))
    XCTAssertNil(PhoneFieldState.validate(["numeric": true, "sheet": 0.5]))
  }

  /// Landscape: the floating pill centres over the canvas between the open side panels and is
  /// capped to that canvas minus 8 pt each side, so it never covers a panel.
  func testPillSpanCentresBetweenOpenSidePanels() {
    let none = BrowserWindowController.pillSpan(contentWidth: 800, left: 0, right: 0)
    XCTAssertEqual(none.offset, 0)
    XCTAssertEqual(none.inset, 16)
    let layers = BrowserWindowController.pillSpan(contentWidth: 800, left: 241, right: 0)
    XCTAssertEqual(layers.offset, 120.5)
    XCTAssertEqual(layers.inset, 257)
    let both = BrowserWindowController.pillSpan(contentWidth: 800, left: 241, right: 241)
    XCTAssertEqual(both.offset, 0)
    XCTAssertEqual(both.inset, 498)
    // Panels wider than the content are clamped.
    let clamped = BrowserWindowController.pillSpan(contentWidth: 300, left: 400, right: 50)
    XCTAssertEqual(clamped.inset, 316)
  }

  func testLandscapeSidePanelsReportBothAndClampedOverscan() {
    var payload: [String: Any] = [
      "panel": "both", "tool": "move", "mode": "design", "minimize": true, "overlay": false,
      "visibleTools": ["Move-tool", "Hand tool-tool", "Measurement-tool", "Annotation-tool"],
      "left": 49, "right": 0, "panelLeft": 241, "panelRight": 241,
    ]
    let state = PhoneLayoutState.validate(payload)
    XCTAssertEqual(state?.panel, "both")
    XCTAssertEqual(state?.left, 49)
    XCTAssertEqual(state?.panelLeft, 241)
    payload["panelRight"] = -3
    XCTAssertEqual(PhoneLayoutState.validate(payload)?.panelRight, 0)
    payload["panelRight"] = "wide"
    XCTAssertNil(PhoneLayoutState.validate(payload))
    payload["panelRight"] = 241
    payload["left"] = 5000
    XCTAssertEqual(PhoneLayoutState.validate(payload)?.left, 1200)
    payload["panel"] = "top"
    XCTAssertNil(PhoneLayoutState.validate(payload))
  }
}
