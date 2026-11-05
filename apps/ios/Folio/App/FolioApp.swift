import UIKit

@main
@MainActor
final class FolioApp: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication, configurationForConnecting session: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Browser", sessionRole: session.role)
    configuration.delegateClass = FolioSceneDelegate.self
    return configuration
  }

  func application(
    _ application: UIApplication, didDiscardSceneSessions sessions: Set<UISceneSession>
  ) {
    for session in sessions { WindowSession.removeArchive(session.persistentIdentifier) }
  }
}
