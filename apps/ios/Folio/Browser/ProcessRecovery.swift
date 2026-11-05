import Foundation

struct ProcessRecovery {
  private var attempts: [TimeInterval] = []

  mutating func shouldReload(
    now: TimeInterval = ProcessInfo.processInfo.systemUptime, limit: Int = 3
  ) -> Bool {
    attempts.removeAll { now - $0 >= 120 }
    attempts.append(now)
    return attempts.count < limit
  }
}
