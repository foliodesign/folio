import UIKit
import XCTest

/// Evidence from composited screen pixels, never QuickLook's private view tree.
/// Call only for the first-party 160x160 #1769e0/#ff9e24 native-lab PNG.
@MainActor
extension XCTestCase {
  func b3CaptureDownloadHierarchy(_ app: XCUIApplication, stage: String) {
    let diagnostics = app.buttons["Open diagnostics"].firstMatch
    let readiness =
      diagnostics.exists ? diagnostics.value as? String ?? "unavailable" : "not exposed"
    let hierarchy = XCTAttachment(string: app.debugDescription + "\nNative readiness: " + readiness)
    hierarchy.name = "Download delivery " + stage
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
  }

  /// The dismiss region can span the entire window. Its center can fall inside
  /// the Share sheet, so choose a returned point outside the actual remote sheet.
  func b3DismissShare(
    _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    let sheet = app.otherElements["ShareSheet.RemoteContainerView"]
    XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
    b3CaptureDownloadHierarchy(app, stage: "Share before outside dismissal")
    let dismissRegions = app.otherElements.matching(identifier: "PopoverDismissRegion")
    XCTAssertTrue(
      dismissRegions.firstMatch.waitForExistence(timeout: 10), app.debugDescription,
      file: file, line: line)
    let regions = dismissRegions.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
    let visibleWindow = app.windows.firstMatch.frame
    for region in regions {
      let frame = region.frame
      let points = [
        CGPoint(x: frame.minX + 12, y: frame.midY),
        CGPoint(x: frame.minX + 12, y: frame.minY + 12),
        CGPoint(x: frame.maxX - 12, y: frame.minY + 12),
        CGPoint(x: frame.minX + 12, y: frame.maxY - 12),
        CGPoint(x: frame.maxX - 12, y: frame.maxY - 12),
      ]
      if let point = points.first(where: {
        frame.contains($0) && visibleWindow.contains($0) && !sheet.frame.contains($0)
      }) {
        let geometry = XCTAttachment(
          string: "sheet=\(sheet.frame) region=\(frame) outsideTap=\(point)")
        geometry.name = "Share outside dismissal geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        region.coordinate(withNormalizedOffset: .zero)
          .withOffset(CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY)).tap()
        XCTAssertTrue(
          sheet.waitForNonExistence(timeout: 10), app.debugDescription, file: file, line: line)
        b3CaptureDownloadHierarchy(app, stage: "Share after outside dismissal")
        return
      }
    }
    XCTFail(
      "No returned hittable dismissal point outside the Share sheet: " + app.debugDescription,
      file: file, line: line)
  }

  @discardableResult
  func b3AssertRenderedPNG(
    in preview: XCUIElement, timeout: TimeInterval = 10,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var last: XCUIScreenshot?
    while Date() < deadline {
      guard preview.exists, preview.isHittable else { break }
      let screenshot = preview.screenshot()
      last = screenshot
      if B3DownloadsRenderEvidence.containsFixture(screenshot.image) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "B3 rendered blue-orange PNG, preview pixels"
        attachment.lifetime = .keepAlways
        add(attachment)
        return true
      }
      // A bounded render poll. Container existence and image decoding cannot pass.
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if let last {
      let attachment = XCTAttachment(screenshot: last)
      attachment.name = "B3 PNG render deadline, unverified content"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    XCTFail(
      "QuickLook did not render both local PNG halves before the deadline", file: file, line: line)
    return false
  }
}

enum B3DownloadsRenderEvidence {
  static func containsFixture(_ image: UIImage) -> Bool {
    let size = CGSize(width: 320, height: max(1, 320 * image.size.height / image.size.width))
    let upright = UIGraphicsImageRenderer(size: size).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
    guard let source = upright.cgImage else { return false }
    let width = 320
    let height = max(1, Int(Double(source.height) * Double(width) / Double(source.width)))
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    return pixels.withUnsafeMutableBytes { bytes in
      guard
        let context = CGContext(
          data: bytes.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
      let data = bytes.bindMemory(to: UInt8.self)
      var blue = 0
      var orange = 0
      var blueX = 0
      var orangeX = 0
      var blueY = 0
      var orangeY = 0
      for y in 0..<height {
        for x in 0..<width {
          let offset = (y * width + x) * 4
          let red = Int(data[offset])
          let green = Int(data[offset + 1])
          let value = Int(data[offset + 2])
          if abs(red - 23) < 24 && abs(green - 105) < 24 && abs(value - 224) < 24 {
            blue += 1
            blueX += x
            blueY += y
          }
          if abs(red - 255) < 24 && abs(green - 158) < 24 && abs(value - 36) < 24 {
            orange += 1
            orangeX += x
            orangeY += y
          }
        }
      }
      // Substantial adjacent halves on the same horizontal band. A blue Close
      // button, white spinner, text or a single colored icon cannot satisfy this.
      guard blue >= 60, orange >= 60, blue < orange * 2, orange < blue * 2 else { return false }
      return orangeX / orange - blueX / blue >= 8
        && abs(orangeY / orange - blueY / blue) <= 4
    }
  }
}
