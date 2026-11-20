import StoreKit
import UIKit

/// App Store ratings (maintainer, 2026-11-20). Apple's native star prompt appears on its own once
/// someone has used Folio for a while, at a calm moment: back on Home after a file, never while
/// editing. The ⋯ menu's "Rate Folio" opens the App Store's write-a-review page instead, because
/// Apple's prompt may show nothing when asked for from a button. Only local counters, no network.
@MainActor
enum ReviewPrompt {
  static let writeReviewURL = URL(
    string: "https://apps.apple.com/app/id6828007211?action=write-review")!

  /// Due once files were open on this many different days…
  static let minimumFileDays = 5
  /// …the first of them at least this many days ago…
  static let minimumDaysInUse = 10
  /// …and not asked in this version or within this many days. iOS also shows the prompt at most
  /// three times a year and never once the person has rated or turned ratings off.
  static let minimumDaysBetween = 120

  private static let fileDaysKey = "folio.review.fileDays"
  private static let lastFileDayKey = "folio.review.lastFileDay"
  private static let firstFileDayKey = "folio.review.firstFileDay"
  private static let askedVersionKey = "folio.review.askedVersion"
  private static let askedAtKey = "folio.review.askedAt"

  /// A file tab is showing: counts today once.
  static func noteFileShown(defaults: UserDefaults = .standard, now: Date = Date()) {
    let today = Calendar.current.startOfDay(for: now).timeIntervalSince1970
    guard defaults.double(forKey: lastFileDayKey) != today else { return }
    defaults.set(today, forKey: lastFileDayKey)
    defaults.set(defaults.integer(forKey: fileDaysKey) + 1, forKey: fileDaysKey)
    if defaults.object(forKey: firstFileDayKey) == nil {
      defaults.set(today, forKey: firstFileDayKey)
    }
  }

  static func isDue(
    defaults: UserDefaults = .standard, now: Date = Date(), version: String = appVersion
  ) -> Bool {
    let day: TimeInterval = 24 * 60 * 60
    guard defaults.integer(forKey: fileDaysKey) >= minimumFileDays,
      let first = defaults.object(forKey: firstFileDayKey) as? TimeInterval,
      now.timeIntervalSince1970 - first >= Double(minimumDaysInUse) * day,
      defaults.string(forKey: askedVersionKey) != version
    else { return false }
    let asked = defaults.double(forKey: askedAtKey)
    return asked == 0 || now.timeIntervalSince1970 - asked >= Double(minimumDaysBetween) * day
  }

  /// Back on Home after a file: asks for a rating when due, a moment later, if the window is
  /// still on Home and nothing is presented over it.
  static func askIfDue(
    in scene: UIWindowScene?, stillCalm: @escaping @MainActor () -> Bool,
    defaults: UserDefaults = .standard
  ) {
    guard let scene, isDue(defaults: defaults), !isTesting else { return }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1))
      guard scene.activationState == .foregroundActive, stillCalm(), isDue(defaults: defaults)
      else { return }
      defaults.set(appVersion, forKey: askedVersionKey)
      defaults.set(Date().timeIntervalSince1970, forKey: askedAtKey)
      AppStore.requestReview(in: scene)
    }
  }

  /// The ⋯ menu's "Rate Folio": the App Store's write-a-review page.
  static func openWriteReview() {
    UIApplication.shared.open(writeReviewURL)
  }

  private static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }

  private static var isTesting: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }
}
