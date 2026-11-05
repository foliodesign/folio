import ImageIO
import Photos
import UniformTypeIdentifiers

/// Original local raster resources only. No Photos reads, enumeration or conversion.
@MainActor
final class PhotosExportService {
  enum Outcome: Equatable {
    case saved, denied, restricted, failed, unsupported

    var message: String {
      switch self {
      case .saved: "Saved to Photos. Saving again will create another copy."
      case .denied:
        "Photos access was denied. You can allow adding photos in Settings, or use Files or Share."
      case .restricted: "Adding to Photos is restricted on this device. Use Files or Share."
      case .failed:
        "The photo could not be saved. Your download is still available. Try again, or use Files or Share."
      case .unsupported:
        "Save to Photos supports validated PNG and JPEG downloads. Use Files or Share for this file."
      }
    }
  }
  typealias Permission = (@escaping @MainActor @Sendable (PHAuthorizationStatus) -> Void) -> Void
  typealias Write = (URL, @escaping @MainActor @Sendable (Bool) -> Void) -> Void
  static let shared = PhotosExportService()

  private struct Operation {
    let token: UUID
    let catalog: DownloadCenterCatalog
    let item: UUID
    let protection: UUID
    var writing = false
    var completion: (@MainActor (Outcome) -> Void)?
  }
  private var operations: [URL: Operation] = [:]
  private let permission: Permission
  private let write: Write

  init(
    permission: @escaping Permission = { completion in
      // XcodeGen must preserve the add-only usage key. Fail without invoking
      // Photos if a generated configuration accidentally omitted it.
      guard
        let text = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription")
          as? String,
        !text.isEmpty
      else {
        completion(.notDetermined)
        return
      }
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        Task { @MainActor in completion(status) }
      }
    },
    write: @escaping Write = { url, completion in
      PHPhotoLibrary.shared().performChanges {
        let options = PHAssetResourceCreationOptions()
        options.shouldMoveFile = false
        PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: options)
      } completionHandler: { success, _ in
        // Never put Photos error descriptions or export paths in diagnostics.
        Task { @MainActor in completion(success) }
      }
    }
  ) {
    self.permission = permission
    self.write = write
  }

  isolated deinit {
    for operation in operations.values where !operation.writing {
      operation.catalog.release(operation.item, token: operation.protection)
    }
  }

  static func supports(_ url: URL) -> Bool {
    guard url.isFileURL,
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ]),
      values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size > 0, Int64(size) <= DownloadCenterCatalog.maximumFileBytes,
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      CGImageSourceGetStatus(source) == .statusComplete,
      let type = CGImageSourceGetType(source) as String?,
      [UTType.png.identifier, UTType.jpeg.identifier].contains(type),
      CGImageSourceGetCount(source) == 1,
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber, width.intValue > 0,
      height.intValue > 0
    else { return false }
    return true
  }

  /// Nil means no operation was started, including a repeated tap while busy.
  @discardableResult
  func save(
    id: UUID, catalog: DownloadCenterCatalog, completion: @escaping @MainActor (Outcome) -> Void
  )
    -> UUID?
  {
    guard let url = catalog.completedURL(id: id) else { return nil }
    guard operations[url] == nil else { return nil }
    guard Self.supports(url) else {
      completion(.unsupported)
      return nil
    }
    let token = UUID()
    operations[url] = Operation(
      token: token, catalog: catalog, item: id, protection: catalog.protect(id, presentation: true),
      completion: completion)
    permission { [weak self] status in
      guard let self, let operation = self.operations[url], operation.token == token,
        !operation.writing
      else { return }
      switch status {
      case .authorized:
        guard Self.supports(url), catalog.completedURL(id: id) == url else {
          self.finish(url: url, token: token, outcome: .failed)
          return
        }
        self.operations[url]?.writing = true
        self.write(url) { [weak self] success in
          if let self {
            self.finish(url: url, token: token, outcome: success ? .saved : .failed)
          } else {
            // An injected service can be released with its controller. The
            // transaction's callback still owns the file lease until completion.
            catalog.release(id, token: operation.protection)
          }
        }
      case .restricted: self.finish(url: url, token: token, outcome: .restricted)
      case .denied: self.finish(url: url, token: token, outcome: .denied)
      default: self.finish(url: url, token: token, outcome: .failed)
      }
    }
    return token
  }

  func cancel(_ token: UUID) {
    guard let (url, operation) = operations.first(where: { $0.value.token == token }) else {
      return
    }
    if operation.writing {
      // Public Photos transactions cannot be cancelled after submission. Keep
      // the file protected until its acknowledgement, but detach the closed UI.
      operations[url]?.completion = nil
    } else {
      operations[url] = nil
      operation.catalog.release(operation.item, token: operation.protection)
    }
  }

  private func finish(url: URL, token: UUID, outcome: Outcome) {
    guard let operation = operations[url], operation.token == token else { return }
    operations[url] = nil
    operation.catalog.release(operation.item, token: operation.protection)
    operation.completion?(outcome)
  }
}
