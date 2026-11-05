import Foundation

/// Dependency selection only. Never resets or copies the owner's defaults/inbox.
@MainActor
enum DebugLabConfiguration {
  static func isOffline(_ arguments: [String]) -> Bool {
    #if DEBUG
      return arguments.contains { argument in
        [
          "--tabs-lab", "--native-lab", "--auth-lab", "--input-lab", "--focus-lab",
          "--memory-lab", "--interface-zoom-lab",
        ].contains(argument)
      }
    #else
      return false
    #endif
  }

  static var usesExistingZoomFixture: Bool {
    #if DEBUG
      return ProcessInfo.processInfo.arguments.contains("--interface-zoom-lab")
        || ProcessInfo.processInfo.arguments.contains("--browser-chrome-visibility")
    #else
      return false
    #endif
  }

  static var offline: Bool { isOffline(ProcessInfo.processInfo.arguments) }
  /// UIKit scene activities outlive a process and are separate from UserDefaults.
  /// Offline labs must not import a previous app or fixture session through that channel.
  static func sceneRestorationData(
    _ data: Data?, arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> Data? {
    isOffline(arguments) ? nil : data
  }

  static let defaults: UserDefaults = {
    guard offline else { return .standard }
    // A fresh domain per process; unrelated tests and warm scheme delivery share this instance.
    return UserDefaults(suiteName: "folio.offline.\(UUID())")!
  }()
  static var acceptsScheme: Bool {
    !offline || ProcessInfo.processInfo.arguments.contains("--native-lab")
  }
  static var inbox: SharedLinkInbox? {
    if offline {
      return ProcessInfo.processInfo.arguments.contains("--native-lab")
        ? SharedLinkInbox(defaults: defaults) : nil
    }
    return .shared
  }
}
