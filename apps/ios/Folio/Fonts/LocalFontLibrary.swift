import CoreText
import Foundation
import UIKit

/// One face in the helper catalogue: OS/2 weight class (100–900) and width class (1–9).
struct LocalFontFace: Encodable {
  let family: String
  let style: String
  let postscript: String
  let weight: Int
  let stretch: Int
  let italic: Bool
  let modifiedAt: Int
  let userInstalled = true

  enum CodingKeys: String, CodingKey {
    case family, style, postscript, weight, stretch, italic
    case modifiedAt = "modified_at"
    case userInstalled = "user_installed"
  }
}

struct LocalFontFile {
  let id: String
  let url: URL
  let faces: [LocalFontFace]
}

/// Only explicitly imported originals. No installed-font enumeration or registration.
@MainActor
final class LocalFontLibrary {
  static let shared = LocalFontLibrary()
  nonisolated static let maximumFileBytes = 32 * 1024 * 1024
  private(set) var files: [LocalFontFile] = []
  private(set) var modifiedAt = Date()
  private(set) var issue: String?
  private let directory: URL
  var faces: [LocalFontFace] { files.flatMap(\.faces) }

  private init() {
    directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("LocalFonts", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var directory = directory
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try directory.setResourceValues(values)
      let urls = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(64) {
        guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else {
          continue
        }
        do { files.append(try inspect(url, id: url.lastPathComponent)) } catch {
          issue = "An imported file could not be read. Import its original again."
        }
      }
    } catch { issue = "The font library could not be opened." }
  }

  func importFile(_ source: URL) async throws {
    let ext = source.pathExtension.lowercased()
    guard ["ttf", "otf", "ttc"].contains(ext) else {
      throw Failure("Choose a TTF, OTF or TTC original.")
    }
    let data = try await Task.detached(priority: .userInitiated) {
      try Self.importData(source)
    }.value
    guard files.count < 64 else { throw Failure("The library is limited to 64 font files.") }
    let id = UUID().uuidString + "." + ext
    let inspected = try inspect(data, url: source, id: id)
    let existingNames = Set(faces.map(\.postscript))
    guard !inspected.faces.contains(where: { existingNames.contains($0.postscript) }) else {
      throw Failure(
        "A face with this PostScript name is already imported. Delete it before replacing.")
    }
    let existingBytes = files.reduce(0) {
      $0 + ((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    guard existingBytes + data.count <= 128 * 1024 * 1024 else {
      throw Failure("The font library is limited to 128 MiB.")
    }
    let destination = directory.appendingPathComponent(id)
    try data.write(to: destination, options: [.atomic, .completeFileProtection])
    files.append(LocalFontFile(id: id, url: destination, faces: inspected.faces))
    modifiedAt = Date()
    issue = nil
    LocalFontService.shared.libraryChanged()
  }

  nonisolated private static func importData(_ source: URL) throws -> Data {
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    // File providers may download here; keep coordination off the UI thread.
    var coordinationError: NSError?
    var result: Result<Data, Error>?
    NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) {
      url in result = Result { try read(url) }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw Failure("The selected file could not be read.") }
    return try result.get()
  }

  func delete(_ file: LocalFontFile) throws {
    try FileManager.default.removeItem(at: file.url)
    files.removeAll { $0.id == file.id }
    modifiedAt = Date()
    issue = nil
    LocalFontService.shared.libraryChanged()
  }

  func bytes(for id: String) throws -> Data? {
    guard let file = files.first(where: { $0.id == id }) else { return nil }
    return try Self.read(file.url)
  }

  nonisolated private static func read(_ url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size > 0, size <= Self.maximumFileBytes
    else { throw Failure("Choose a regular font file smaller than 32 MiB.") }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    while data.count <= Self.maximumFileBytes {
      let chunk =
        try handle.read(upToCount: min(1024 * 1024, Self.maximumFileBytes + 1 - data.count))
        ?? Data()
      if chunk.isEmpty { break }
      data.append(chunk)
    }
    guard !data.isEmpty, data.count <= Self.maximumFileBytes else {
      throw Failure("The font file is empty or too large.")
    }
    return data
  }

  private func inspect(_ url: URL, id: String) throws -> LocalFontFile {
    try inspect(Self.read(url), url: url, id: id)
  }

  private func inspect(_ data: Data, url: URL, id: String) throws -> LocalFontFile {
    let modified =
      (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? Date()
    guard
      let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData)
        as? [CTFontDescriptor], !descriptors.isEmpty, descriptors.count <= 64
    else { throw Failure("Core Text could not read this font file.") }
    let faces = try descriptors.map { descriptor in
      let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
      if let axes = CTFontCopyVariationAxes(font), CFArrayGetCount(axes) > 0 {
        throw Failure(
          "Variable fonts are not supported by this minimal experiment. Import a static face.")
      }
      let traits = CTFontCopyTraits(font) as NSDictionary
      let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
      let width = (traits[kCTFontWidthTrait] as? NSNumber)?.doubleValue ?? 0
      let points: [(Double, Double)] = [
        (-1, 1), (Double(UIFont.Weight.ultraLight.rawValue), 100),
        (Double(UIFont.Weight.thin.rawValue), 200), (Double(UIFont.Weight.light.rawValue), 300),
        (Double(UIFont.Weight.regular.rawValue), 400), (Double(UIFont.Weight.medium.rawValue), 500),
        (Double(UIFont.Weight.semibold.rawValue), 600), (Double(UIFont.Weight.bold.rawValue), 700),
        (Double(UIFont.Weight.heavy.rawValue), 800), (Double(UIFont.Weight.black.rawValue), 900),
        (1, 1000),
      ]
      var cssWeight = 400.0
      for index in 1..<points.count where weight <= points[index].0 {
        let lower = points[index - 1]
        let upper = points[index]
        cssWeight =
          lower.1 + (max(lower.0, weight) - lower.0)
          / (upper.0 - lower.0) * (upper.1 - lower.1)
        break
      }
      // Prefer the font's own OS/2 classes; fall back to Core Text's normalized traits.
      var stretch = min(9, max(1, Int((5 + width * 4).rounded())))
      if let os2 = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?,
        os2.count >= 8
      {
        let weightClass = Int(os2[os2.startIndex + 4]) << 8 | Int(os2[os2.startIndex + 5])
        let widthClass = Int(os2[os2.startIndex + 6]) << 8 | Int(os2[os2.startIndex + 7])
        if (1...1000).contains(weightClass) { cssWeight = Double(weightClass) }
        if (1...9).contains(widthClass) { stretch = widthClass }
      }
      return LocalFontFace(
        family: CTFontCopyFamilyName(font) as String,
        style: CTFontCopyName(font, kCTFontStyleNameKey) as String? ?? "Regular",
        postscript: CTFontCopyPostScriptName(font) as String,
        weight: Int(cssWeight.rounded()), stretch: stretch,
        italic: CTFontGetSymbolicTraits(font).contains(.traitItalic),
        modifiedAt: Int(modified.timeIntervalSince1970))
    }
    return LocalFontFile(id: id, url: url, faces: faces)
  }

  struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
