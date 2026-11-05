import Photos
import UIKit
import XCTest

@testable import Folio

@MainActor
final class PhotosExportTests: XCTestCase {
  private func fixture() throws -> (DownloadCenterCatalog, UUID, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let catalog = DownloadCenterCatalog(root: root)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let id = try catalog.begin()
    let url = try catalog.destination(id: id, suggested: "export.png", expectedBytes: 100)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
    try XCTUnwrap(image.pngData()).write(to: url)
    _ = try catalog.finish(id: id)
    return (catalog, id, url)
  }

  func testAllowedOriginalResourceAndDuplicateCallbacksReleaseExactlyOnce() throws {
    let (catalog, id, url) = try fixture()
    var permission: (@MainActor @Sendable (PHAuthorizationStatus) -> Void)?
    var write: (@MainActor @Sendable (Bool) -> Void)?
    var writes = 0
    var results: [PhotosExportService.Outcome] = []
    let service = PhotosExportService(
      permission: { permission = $0 },
      write: { original, callback in
        XCTAssertEqual(original, url)
        writes += 1
        write = callback
      })
    XCTAssertNotNil(service.save(id: id, catalog: catalog) { results.append($0) })
    XCTAssertTrue(catalog.isProtected(id))
    XCTAssertFalse(catalog.delete(id))
    permission?(.authorized)
    permission?(.authorized)
    XCTAssertEqual(writes, 1)
    XCTAssertTrue(catalog.isProtected(id))
    write?(true)
    write?(false)
    permission?(.denied)
    XCTAssertEqual(results, [.saved])
    XCTAssertFalse(catalog.isProtected(id))
    XCTAssertEqual(catalog.completedURL(id: id), url)
  }

  func testDeniedRestrictedAndWriteFailureKeepActionableFile() throws {
    for status in [
      PHAuthorizationStatus.denied, .restricted, .authorized, .notDetermined, .limited,
    ] {
      let (catalog, id, url) = try fixture()
      var results: [PhotosExportService.Outcome] = []
      var writes = 0
      let service = PhotosExportService(
        permission: { $0(status) },
        write: { _, completion in
          writes += 1
          completion(false)
        })
      service.save(id: id, catalog: catalog) { results.append($0) }
      let expected: PhotosExportService.Outcome =
        status == .denied ? .denied : status == .restricted ? .restricted : .failed
      XCTAssertEqual(results, [expected])
      XCTAssertEqual(writes, status == .authorized ? 1 : 0)
      XCTAssertFalse(catalog.isProtected(id))
      XCTAssertEqual(catalog.completedURL(id: id), url)
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
  }

  func testRepeatedTapIsOneOperationButUserCanIntentionallySaveAgain() throws {
    let (catalog, id, _) = try fixture()
    var permission: (@MainActor @Sendable (PHAuthorizationStatus) -> Void)?
    var write: (@MainActor @Sendable (Bool) -> Void)?
    var requests = 0
    var writes = 0
    var results: [PhotosExportService.Outcome] = []
    let service = PhotosExportService(
      permission: {
        requests += 1
        permission = $0
      },
      write: { _, callback in
        writes += 1
        write = callback
      })
    XCTAssertNotNil(service.save(id: id, catalog: catalog) { results.append($0) })
    XCTAssertNil(service.save(id: id, catalog: catalog) { results.append($0) })
    permission?(.authorized)
    XCTAssertNil(service.save(id: id, catalog: catalog) { results.append($0) })
    write?(true)
    XCTAssertNotNil(service.save(id: id, catalog: catalog) { results.append($0) })
    permission?(.authorized)
    write?(true)
    XCTAssertEqual(requests, 2)
    XCTAssertEqual(writes, 2)
    XCTAssertEqual(results, [.saved, .saved])
  }

  func testTabCloseBeforePermissionPreventsWriteAndLateCallbacks() throws {
    let (catalog, id, _) = try fixture()
    var permission: (@MainActor @Sendable (PHAuthorizationStatus) -> Void)?
    var writes = 0
    var results = 0
    let service = PhotosExportService(
      permission: { permission = $0 }, write: { _, _ in writes += 1 })
    let token = try XCTUnwrap(service.save(id: id, catalog: catalog) { _ in results += 1 })
    service.cancel(token)
    service.cancel(token)
    permission?(.authorized)
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(results, 0)
    XCTAssertFalse(catalog.isProtected(id))
  }

  func testCloseDuringSubmittedWriteProtectsFileUntilAcknowledgedWithoutClosedUI() throws {
    let (catalog, id, _) = try fixture()
    var write: (@MainActor @Sendable (Bool) -> Void)?
    var results = 0
    let service = PhotosExportService(
      permission: { $0(.authorized) }, write: { _, callback in write = callback })
    let token = try XCTUnwrap(service.save(id: id, catalog: catalog) { _ in results += 1 })
    service.cancel(token)
    XCTAssertTrue(catalog.isProtected(id))
    XCTAssertFalse(catalog.delete(id))
    XCTAssertNil(service.save(id: id, catalog: catalog) { _ in results += 1 })
    write?(true)
    write?(true)
    XCTAssertEqual(results, 0)
    XCTAssertFalse(catalog.isProtected(id))
  }

  func testCancelledPermissionCannotStartAReplacementSaveFromItsStaleGrant() throws {
    let (catalog, id, _) = try fixture()
    var callbacks: [@MainActor @Sendable (PHAuthorizationStatus) -> Void] = []
    var writes = 0
    var results: [PhotosExportService.Outcome] = []
    let service = PhotosExportService(
      permission: { callbacks.append($0) },
      write: { _, done in
        writes += 1
        done(true)
      })
    let first = try XCTUnwrap(service.save(id: id, catalog: catalog) { results.append($0) })
    service.cancel(first)
    XCTAssertNotNil(service.save(id: id, catalog: catalog) { results.append($0) })
    callbacks[0](.authorized)
    XCTAssertEqual(writes, 0)
    XCTAssertTrue(catalog.isProtected(id))
    callbacks[1](.authorized)
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(results, [.saved])
    XCTAssertFalse(catalog.isProtected(id))
    XCTAssertNotNil(DownloadCenterCatalog(root: catalog.root).completedURL(id: id))
  }

  func testInjectedServiceReleaseDuringWriteKeepsLeaseUntilCompletion() throws {
    let (catalog, id, _) = try fixture()
    var write: (@MainActor @Sendable (Bool) -> Void)?
    var service: PhotosExportService? = PhotosExportService(
      permission: { $0(.authorized) }, write: { _, done in write = done })
    weak var weakService = service
    service?.save(id: id, catalog: catalog) { _ in
      XCTFail("Released service must not deliver to UI")
    }
    service = nil
    XCTAssertNil(weakService)
    XCTAssertTrue(catalog.isProtected(id))
    write?(true)
    write?(false)
    XCTAssertFalse(catalog.isProtected(id))
  }

  func testUnsupportedOrSpoofedRasterDoesNotRequestPermission() throws {
    let (catalog, id, url) = try fixture()
    var permissions = 0
    var writes = 0
    var result: PhotosExportService.Outcome?
    let service = PhotosExportService(
      permission: { _ in permissions += 1 }, write: { _, _ in writes += 1 })
    for data in [Data("<svg/>".utf8), Data("%PDF".utf8), Data([0x50, 0x4B, 0x03, 0x04]), Data()] {
      try data.write(to: url)
      XCTAssertFalse(PhotosExportService.supports(url))
      XCTAssertNil(service.save(id: id, catalog: catalog) { result = $0 })
      XCTAssertEqual(result, .unsupported)
    }
    XCTAssertEqual(permissions, 0)
    XCTAssertEqual(writes, 0)
    XCTAssertFalse(catalog.isProtected(id))
  }
}
