import XCTest

@testable import Folio

@MainActor
final class DebugLabConfigurationTests: XCTestCase {
  func testOfflineLaunchRejectsSceneTabsWhileNormalLaunchRestoresThem() throws {
    let sourceName = "folio.scene-source.\(UUID())"
    let source = UserDefaults(suiteName: sourceName)!
    defer { source.removePersistentDomain(forName: sourceName) }
    let previous = WindowSession(defaults: source, migrateLegacy: false)
    let file = previous.add(url: URL(string: "https://www.figma.com/design/previous")!)
    let archive = try XCTUnwrap(previous.restorationData())

    for arguments in [[], ["--tabs-lab"], ["--native-lab"], ["--interface-zoom-lab"]] {
      let name = "folio.scene-destination.\(UUID())"
      let defaults = UserDefaults(suiteName: name)!
      defer { defaults.removePersistentDomain(forName: name) }
      let restored = WindowSession(
        defaults: defaults, migrateLegacy: false,
        restorationData: DebugLabConfiguration.sceneRestorationData(archive, arguments: arguments))
      if arguments.isEmpty {
        XCTAssertEqual(restored.tabs.map(\.id), [restored.home.id, file.id])
        XCTAssertEqual(restored.selectedID, file.id)
      } else {
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.selectedID, restored.home.id)
      }
    }
  }
}
