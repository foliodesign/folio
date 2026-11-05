import XCTest

@testable import Folio

@MainActor
final class FixtureIsolationTests: XCTestCase {
  func testEveryOfflineLabIsRecognizedWithoutChangingNormalLaunch() {
    XCTAssertFalse(DebugLabConfiguration.isOffline([]))
    for flag in [
      "--tabs-lab", "--native-lab", "--auth-lab", "--input-lab", "--focus-lab",
      "--memory-lab", "--interface-zoom-lab",
    ] {
      XCTAssertTrue(DebugLabConfiguration.isOffline([flag]), flag)
    }
  }

  func testInjectedTabDefaultsKeepOwnerSentinelUntouched() {
    let ownerName = "folio.fixture.owner.\(UUID())"
    let fixtureName = "folio.fixture.tabs.\(UUID())"
    let owner = UserDefaults(suiteName: ownerName)!
    let fixture = UserDefaults(suiteName: fixtureName)!
    defer {
      owner.removePersistentDomain(forName: ownerName)
      fixture.removePersistentDomain(forName: fixtureName)
    }
    owner.set("owner-sentinel", forKey: "folio.lastSelectedRoute")
    let before = owner.dictionaryRepresentation()
    let session = WindowSession(defaults: fixture, migrateLegacy: false)
    session.home.strategies.editorScrollLock = true
    session.home.strategies.pencil = .gestureReroute
    let document = session.add(url: URL(string: "https://figma.com/design/Controlled")!)
    document.strategies.focusViewportLimit = true
    session.select(session.home.id)
    XCTAssertEqual(owner.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
    XCTAssertNotNil(fixture.object(forKey: "folio.editorScrollLock"))
  }
}
