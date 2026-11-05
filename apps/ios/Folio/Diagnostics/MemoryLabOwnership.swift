import Foundation

/// One explicitly opened memory lab may write the shared archive at a time.
@MainActor
final class MemoryLabOwnership {
  var tabID: UUID?
}
