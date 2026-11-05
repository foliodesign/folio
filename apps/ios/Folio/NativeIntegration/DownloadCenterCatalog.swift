import Foundation
import UniformTypeIdentifiers

// Local export files only. No source URL, credentials, resume data or previews are stored.
// The source tab (id and title) and transfer progress are kept in memory only.
@MainActor
final class DownloadCenterCatalog {
  enum Status: String, Codable { case transferring, completed, failed, cancelled }
  struct Source {
    let tabID: UUID
    let title: String?
  }
  struct Item: Codable, Identifiable, Equatable {
    let id: UUID
    var basename: String
    var type: String
    var status: Status
    var size: Int64
    let created: Date
    var updated: Date
  }
  private struct Archive: Codable {
    let version: Int
    let items: [Item]
  }
  enum CatalogError: Error { case full, invalidFile, unavailable }

  static let maximumCount = 32
  static let maximumBytes: Int64 = 128 * 1024 * 1024
  static let maximumFileBytes: Int64 = 32 * 1024 * 1024
  #if DEBUG
    static var fixtureOverride: DownloadCenterCatalog?
  #endif
  static var shared: DownloadCenterCatalog {
    #if DEBUG
      if let fixtureOverride { return fixtureOverride }
    #endif
    return defaultCatalog
  }
  private static let defaultCatalog: DownloadCenterCatalog = {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    #if DEBUG
      // Offline UI fixtures never load the owner's export catalog. The separate
      // fixture catalog survives relaunch so persistence can be tested normally.
      if ProcessInfo.processInfo.arguments.contains("--native-lab") {
        return DownloadCenterCatalog(
          root: support.appendingPathComponent("FolioDownloadFixture", isDirectory: true))
      }
      if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        return DownloadCenterCatalog(
          root: FileManager.default.temporaryDirectory
            .appendingPathComponent("FolioDownloadTests-" + UUID().uuidString, isDirectory: true))
      }
    #endif
    return DownloadCenterCatalog(
      root: support.appendingPathComponent("FolioDownloads", isDirectory: true))
  }()

  let root: URL
  private(set) var items: [Item] = []
  private var protections: [UUID: [UUID: Bool]] = [:]
  private var queueRemovals: [UUID: @MainActor () -> Void] = [:]
  private var cancellations: [UUID: @MainActor () -> Void] = [:]
  private var observers: [UUID: @MainActor () -> Void] = [:]
  private var sources: [UUID: Source] = [:]
  private var progress: [UUID: Progress] = [:]
  private var available = false
  private let manager = FileManager.default
  // One native presentation owner across all handlers using this catalog.
  private(set) var presentationOwner: UUID?

  init(root: URL) {
    self.root = root.standardizedFileURL
    do {
      try manager.createDirectory(at: self.root, withIntermediateDirectories: true)
      guard try self.root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
      else {
        return
      }
      var localRoot = self.root
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try localRoot.setResourceValues(values)
      available = true
      load()
    } catch { available = false }
  }

  static func filename(_ suggested: String) -> String {
    let name = suggested.split(separator: "/").last.map(String.init) ?? "export"
    let scalars = name.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0)
        && !CharacterSet(charactersIn: "\\:").contains($0)
        && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        && $0.value != 0x2028 && $0.value != 0x2029
    }
    // Bound UTF-8 bytes, preserving a short extension for Files and QuickLook.
    let clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean != ".", clean != ".." else { return "export" }
    let ext = (clean as NSString).pathExtension
    let suffix = !ext.isEmpty && ext.utf8.count <= 16 ? "." + ext : ""
    let stem = suffix.isEmpty ? clean : String(clean.dropLast(suffix.count))
    var shortened = ""
    for character in stem {
      guard shortened.utf8.count + String(character).utf8.count <= 180 - suffix.utf8.count else {
        break
      }
      shortened.append(character)
    }
    return (shortened.isEmpty ? "export" : shortened) + suffix
  }

  var reservedBytes: Int64 {
    items.reduce(0) { $0 + ($1.status == .transferring ? Self.maximumFileBytes : $1.size) }
  }

  func begin() throws -> UUID {
    guard available else { throw CatalogError.unavailable }
    try makeRoom(bytes: Self.maximumFileBytes, adding: 1)
    let now = Date()
    let id = UUID()
    items.append(
      Item(
        id: id, basename: "export", type: UTType.data.identifier,
        status: .transferring, size: 0, created: now, updated: now))
    do { try persist() } catch {
      items.removeAll { $0.id == id }
      throw error
    }
    notify()
    return id
  }

  func destination(id: UUID, suggested: String, expectedBytes: Int64) throws -> URL {
    guard let index = items.firstIndex(where: { $0.id == id && $0.status == .transferring }),
      expectedBytes <= Self.maximumFileBytes
    else { throw CatalogError.invalidFile }
    let directory = directory(id)
    try manager.createDirectory(at: directory, withIntermediateDirectories: false)
    guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw CatalogError.invalidFile
    }
    items[index].basename = Self.filename(suggested)
    items[index].type =
      UTType(filenameExtension: (items[index].basename as NSString).pathExtension)?
      .identifier ?? UTType.data.identifier
    items[index].updated = Date()
    try persist()
    notify()
    return directory.appendingPathComponent(items[index].basename)
  }

  func finish(id: UUID) throws -> URL {
    guard let index = items.firstIndex(where: { $0.id == id && $0.status == .transferring }),
      let url = fileURL(id: id), let size = regularFileSize(url),
      size <= Self.maximumFileBytes
    else { throw CatalogError.invalidFile }
    items[index].status = .completed
    progress[id] = nil
    items[index].size = size
    items[index].updated = Date()
    cancellations[id] = nil
    do { try persist() } catch {
      items[index].status = .transferring
      items[index].size = 0
      throw error
    }
    notify()
    return url
  }

  func clearPartial(id: UUID) {
    guard item(id)?.status == .transferring else { return }
    removeDirectory(id)
  }

  func fail(id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id && $0.status == .transferring }) else {
      return
    }
    removeDirectory(id)
    progress[id] = nil
    items[index].status = .failed
    items[index].size = 0
    items[index].updated = Date()
    cancellations[id] = nil
    try? persist()
    notify()
  }

  func item(_ id: UUID) -> Item? { items.first { $0.id == id } }
  func setSource(_ source: Source, for id: UUID) { sources[id] = source }
  func source(_ id: UUID) -> Source? { sources[id] }
  func setProgress(_ value: Progress, for id: UUID) { progress[id] = value }
  /// 0...1 while the size is known, else nil.
  func fractionCompleted(_ id: UUID) -> Double? {
    guard item(id)?.status == .transferring, let value = progress[id],
      value.totalUnitCount > 0
    else { return nil }
    return value.fractionCompleted
  }
  func id(for url: URL) -> UUID? {
    items.first { fileURL(id: $0.id)?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }?
      .id
  }
  func fileURL(id: UUID) -> URL? {
    guard let item = item(id) else { return nil }
    return directory(id).appendingPathComponent(item.basename)
  }
  func completedURL(id: UUID) -> URL? {
    guard item(id)?.status == .completed, let url = fileURL(id: id), regularFileSize(url) != nil
    else {
      return nil
    }
    return url
  }

  @discardableResult
  func protect(_ id: UUID, presentation: Bool = false) -> UUID {
    let token = UUID()
    protections[id, default: [:]][token] = presentation
    return token
  }
  func release(_ id: UUID, token: UUID) {
    protections[id]?[token] = nil
    if protections[id]?.isEmpty == true { protections[id] = nil }
    notify()
  }
  func isProtected(_ id: UUID) -> Bool { protections[id]?.isEmpty == false }

  func canDelete(_ id: UUID) -> Bool {
    guard let item = item(id) else { return false }
    return item.status != .transferring && protections[id]?.values.contains(true) != true
  }
  func registerQueueRemoval(id: UUID, action: @escaping @MainActor () -> Void) {
    queueRemovals[id] = action
  }
  func unregisterQueueRemoval(id: UUID) { queueRemovals[id] = nil }

  func registerCancellation(id: UUID, action: @escaping @MainActor () -> Void) {
    cancellations[id] = action
  }
  func cancel(_ id: UUID) {
    guard item(id)?.status == .transferring else { return }
    cancellations.removeValue(forKey: id)?()
  }
  // A transferring item is removed only by its owner after WKDownload cancellation completes.
  @discardableResult
  func delete(_ id: UUID) -> Bool {
    guard let item = item(id), item.status != .transferring, canDelete(id) else { return false }
    guard removeDirectory(id) else { return false }
    queueRemovals.removeValue(forKey: id)?()
    items.removeAll { $0.id == id }
    sources[id] = nil
    try? persist()
    notify()
    return true
  }
  func cancelled(_ id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id && $0.status == .transferring })
    else { return }
    removeDirectory(id)
    cancellations[id] = nil
    progress[id] = nil
    items[index].status = .cancelled
    items[index].size = 0
    items[index].updated = Date()
    try? persist()
    notify()
  }

  func claimPresentation(_ owner: UUID) -> Bool {
    guard presentationOwner == nil || presentationOwner == owner else { return false }
    presentationOwner = owner
    return true
  }
  func releasePresentation(_ owner: UUID) {
    if presentationOwner == owner { presentationOwner = nil }
  }
  @discardableResult
  func observe(_ action: @escaping @MainActor () -> Void) -> UUID {
    let token = UUID()
    observers[token] = action
    return token
  }
  func removeObserver(_ token: UUID) { observers[token] = nil }
  private func notify() { for observer in Array(observers.values) { observer() } }

  private func directory(_ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString, isDirectory: true)
  }
  @discardableResult
  private func removeDirectory(_ id: UUID) -> Bool {
    do {
      try manager.removeItem(at: directory(id))
      return true
    } catch {
      if (error as NSError).domain == NSCocoaErrorDomain,
        (error as NSError).code == NSFileNoSuchFileError
      {
        return true
      }
      // Do not admit more files if cleanup could not enforce the storage bound.
      available = false
      return false
    }
  }
  private func regularFileSize(_ url: URL) -> Int64? {
    guard
      let directoryValues = try? url.deletingLastPathComponent().resourceValues(forKeys: [
        .isSymbolicLinkKey
      ]),
      directoryValues.isSymbolicLink != true,
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ]),
      values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize
    else { return nil }
    return Int64(size)
  }
  private func makeRoom(bytes: Int64, adding: Int) throws {
    while items.count + adding > Self.maximumCount || reservedBytes + bytes > Self.maximumBytes {
      guard
        let oldest = items.filter({ $0.status != .transferring && !isProtected($0.id) })
          .min(by: { $0.updated < $1.updated })
      else { throw CatalogError.full }
      guard delete(oldest.id) else { throw CatalogError.full }
    }
  }
  private func persist() throws {
    let data = try JSONEncoder().encode(Archive(version: 1, items: items))
    try data.write(
      to: root.appendingPathComponent("catalog.json"),
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
  private func load() {
    let catalog = root.appendingPathComponent("catalog.json")
    let contents: [URL]
    do {
      contents = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    } catch {
      available = false
      return
    }
    if contents.contains(where: { $0.lastPathComponent == "catalog.json" }),
      regularFileSize(catalog) == nil
    {
      available = false
      return
    }
    var readableData: Data?
    if let size = regularFileSize(catalog), size <= 256 * 1024 {
      do { readableData = try Data(contentsOf: catalog) } catch {
        // File protection or I/O failure is not catalog corruption. Keep existing
        // exports untouched and stop admission until a later initialization.
        available = false
        return
      }
    }
    if let data = readableData,
      let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1,
      archive.items.count <= Self.maximumCount
    {
      var seen: Set<UUID> = []
      for var item in archive.items {
        guard seen.insert(item.id).inserted, item.basename == Self.filename(item.basename),
          item.basename.utf8.count <= 180, item.size >= 0, item.size <= Self.maximumFileBytes,
          item.created.timeIntervalSince1970.isFinite, item.updated.timeIntervalSince1970.isFinite,
          item.created <= item.updated, item.updated <= Date().addingTimeInterval(300),
          item.type
            == (UTType(filenameExtension: (item.basename as NSString).pathExtension)?.identifier
              ?? UTType.data.identifier)
        else { continue }
        items.append(item)
        if item.status == .transferring {
          removeDirectory(item.id)
          item.status = .failed
          item.size = 0
          item.updated = Date()
          items[items.count - 1] = item
        } else if item.status == .completed {
          guard let url = fileURL(id: item.id), regularFileSize(url) == item.size else {
            items.removeLast()
            continue
          }
        } else {
          removeDirectory(item.id)
        }
      }
    }
    // Only this service's direct children. removeItem unlinks symlinks, never follows them.
    let retained = Set(items.filter { $0.status == .completed }.map { $0.id.uuidString })
    for url in contents {
      if url.lastPathComponent != "catalog.json" && !retained.contains(url.lastPathComponent) {
        do { try manager.removeItem(at: url) } catch { available = false }
      }
    }
    // Remove extra files inside validated completed-item directories, without recursion through links.
    for item in items where item.status == .completed {
      for url
        in (try? manager.contentsOfDirectory(
          at: directory(item.id), includingPropertiesForKeys: nil)) ?? []
      {
        if url.lastPathComponent != item.basename {
          do { try manager.removeItem(at: url) } catch { available = false }
        }
      }
    }
    try? makeRoom(bytes: 0, adding: 0)
    try? persist()
  }
}
