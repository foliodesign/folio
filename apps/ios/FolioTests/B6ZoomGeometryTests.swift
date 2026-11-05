import UIKit
import WebKit
import XCTest

@testable import Folio

@MainActor
final class B6ZoomGeometryTests: XCTestCase {
  private let scales = [0.5, 0.75, 1.25, 1.5, 2.0]

  func testFiveScaleViewportFillReflowAndNativeContainmentAtThreeSizes() throws {
    try withContainer { window, container, store in
      let web = try selected(container)
      waitUntil { self.value(web, "typeof folioB6Geometry === 'function'") == true }
      let token: String = try XCTUnwrap(value(web, "token"))
      let seeded: Bool? = value(web, "edit.value='retained'; true")
      XCTAssertEqual(seeded, true)
      let history = web.backForwardList.backList.count
      for size in [
        CGSize(width: 768, height: 1024), CGSize(width: 1024, height: 768),
        CGSize(width: 320, height: 700),
      ] {
        window.frame.size = size
        container.view.setNeedsLayout()
        container.view.layoutIfNeeded()
        for scale in scales {
          store.setScale(scale)
          settle(web)
          let g: [String: Double] = try XCTUnwrap(value(web, "folioB6Geometry()"))
          evidence(web, container, g, "\(size) scale=\(scale)")
          XCTAssertTrue(try selected(container) === web)
          XCTAssertEqual(web.pageZoom, 1)
          XCTAssertEqual(web.transform.a, scale)
          XCTAssertEqual(web.transform.d, scale)
          XCTAssertEqual(
            container.browser.view.frame.width, container.view.bounds.width, accuracy: 0.5)
          XCTAssertEqual(
            container.browser.view.frame.maxY, container.view.bounds.maxY, accuracy: 0.5)
          XCTAssertEqual(web.frame.minX, 0, accuracy: 0.5)
          XCTAssertEqual(web.frame.maxX, try XCTUnwrap(web.superview).bounds.maxX, accuracy: 0.5)
          XCTAssertEqual(
            web.frame.minY, try XCTUnwrap(web.superview).safeAreaLayoutGuide.layoutFrame.minY,
            accuracy: 0.5)
          XCTAssertEqual(web.frame.maxY, try XCTUnwrap(web.superview).bounds.maxY, accuracy: 0.5)
          XCTAssertEqual(try metric(g, "innerWidth"), web.bounds.width, accuracy: 2)
          XCTAssertEqual(try metric(g, "innerHeight"), web.bounds.height, accuracy: 2)
          XCTAssertEqual(try metric(g, "x"), try metric(g, "left"), accuracy: 1)
          XCTAssertEqual(try metric(g, "y"), try metric(g, "top"), accuracy: 1)
          XCTAssertEqual(try metric(g, "width"), try metric(g, "viewportWidth"), accuracy: 1)
          XCTAssertEqual(try metric(g, "height"), try metric(g, "viewportHeight"), accuracy: 1)
          XCTAssertEqual(value(web, "token") as String?, token)
          XCTAssertEqual(value(web, "edit.value") as String?, "retained")
          XCTAssertEqual(web.backForwardList.backList.count, history)
          // Geometry conversion only. Native action delivery is separately tested by UI tests.
          for (x, y) in [
            (0.01, 0.01), (0.5, 0.01), (0.99, 0.01), (0.01, 0.5),
            (0.5, 0.5), (0.99, 0.5), (0.01, 0.99), (0.5, 0.99), (0.99, 0.99),
          ] {
            let point = CGPoint(x: web.bounds.width * x, y: web.bounds.height * y)
            XCTAssertTrue(web.hitTest(point, with: nil)?.isDescendant(of: web) == true)
            let css = PinchTransport.cssPoint(point, bounds: web.bounds)
            let covered: Bool? = value(
              web, "viewport.contains(document.elementFromPoint(\(css)))")
            XCTAssertEqual(covered, true, "CSS/native coverage \(scale): \(point)")
          }
        }
      }
    }
  }

  func testContainerControlsHaveAccessible44PointTargetsInNarrowWindow() throws {
    try withContainer { window, container, _ in
      window.frame.size = CGSize(width: 320, height: 700)
      container.view.layoutIfNeeded()
      let target = try XCTUnwrap(button("browser-more", in: container.view))
      let frame = target.convert(target.bounds, to: container.view)
      // The flat strip extends native hit areas beyond its 40-point visible bar.
      for offset in [
        CGPoint(x: -21.9, y: 0), CGPoint(x: 21.9, y: 0),
        CGPoint(x: 0, y: -21.9), CGPoint(x: 0, y: 21.9),
      ] {
        XCTAssertTrue(
          target.point(
            inside: CGPoint(x: target.bounds.midX + offset.x, y: target.bounds.midY + offset.y),
            with: nil))
      }
      XCTAssertTrue(container.view.bounds.contains(frame))
      XCTAssertFalse(target.accessibilityLabel?.isEmpty ?? true)
    }
  }

  private func withContainer(
    _ body: (UIWindow, InterfaceZoomContainerController, InterfaceZoomStore) throws -> Void
  ) throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }
    let name = "folio.b6.zoom.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    let memory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    let store = InterfaceZoomStore(defaults: defaults)
    let container = InterfaceZoomContainerController(store: store) { _ in
      BrowserWindowController(
        session: WindowSession(defaults: defaults, migrateLegacy: false),
        websiteDataStore: .nonPersistent(), memory: MemoryLabStore(url: memory), useFixture: true,
        makeWebView: { configuration in
          let web = B6ZoomFixtureWebView(frame: .zero, configuration: configuration)
          store.registerMainWebView(web)
          return web
        })
    }
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 768, height: 1024)
    window.rootViewController = container
    window.makeKeyAndVisible()
    container.browser.addTab(url: URL(string: "https://www.figma.com/design/b6zoom")!)
    container.view.layoutIfNeeded()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
      defaults.removePersistentDomain(forName: name)
      try? FileManager.default.removeItem(at: memory)
    }
    try body(window, container, store)
  }

  private func selected(_ container: InterfaceZoomContainerController) throws -> WKWebView {
    try XCTUnwrap((container.browser.children.first as? FigmaWebViewController)?.webView)
  }

  private func metric(_ g: [String: Double], _ key: String) throws -> Double {
    try XCTUnwrap(g[key])
  }

  private func button(_ id: String, in view: UIView) -> UIButton? {
    if let button = view as? UIButton, button.accessibilityIdentifier == id { return button }
    return view.subviews.lazy.compactMap { self.button(id, in: $0) }.first
  }

  private func evidence(
    _ web: WKWebView, _ container: InterfaceZoomContainerController,
    _ g: [String: Double], _ context: String
  ) {
    let attachment = XCTAttachment(
      string: "\(context)\n\(InterfaceZoomGeometry.describe(web, in: container.view))\nCSS=\(g)")
    attachment.name = "B6 numeric geometry \(context)"
    attachment.lifetime = .keepAlways
    add(attachment)
    let hierarchy = XCTAttachment(string: hierarchy(container.view))
    hierarchy.name = "B6 native hierarchy \(context)"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
  }

  private func hierarchy(_ view: UIView) -> String {
    ([
      "\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) safe=\(view.safeAreaInsets) hidden=\(view.isHidden)"
    ]
      + view.subviews.map { hierarchy($0) }).joined(separator: "\n")
  }

  private func settle(_ web: WKWebView) {
    var done = false
    web.callAsyncJavaScript(
      "await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame); return true",
      arguments: [:], in: nil, in: .page
    ) { result in
      if case .failure(let error) = result { XCTFail("Layout: \(error)") }
      done = true
    }
    waitUntil { done }
    // 6c6f99a resizes native bounds and lets WebKit deliver its normal resize.
    // Two page animation frames do not acknowledge the UI-process geometry
    // message. Await the actual viewport, with the same deadline/tolerances as
    // the assertions below. A viewport that never fills still fails.
    waitUntil {
      guard let g: [String: Double] = self.value(web, "folioB6Geometry()"),
        let width = g["innerWidth"], let height = g["innerHeight"],
        let renderedWidth = g["width"], let renderedHeight = g["height"],
        let visibleWidth = g["viewportWidth"], let visibleHeight = g["viewportHeight"]
      else { return false }
      return abs(width - web.bounds.width) <= 2 && abs(height - web.bounds.height) <= 2
        && abs(renderedWidth - visibleWidth) <= 1 && abs(renderedHeight - visibleHeight) <= 1
    }
  }

  private func value<T>(_ web: WKWebView, _ script: String) -> T? {
    var done = false
    var returned: T?
    web.evaluateJavaScript(script) { result, error in
      if let error { XCTFail("First-party fixture: \(error)") }
      returned = result as? T
      done = true
    }
    waitUntil { done }
    return returned
  }

  private func waitUntil(_ condition: () -> Bool) {
    let end = Date().addingTimeInterval(10)
    while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    XCTAssertTrue(condition(), "Bounded fixture readiness")
  }
}

@MainActor
private final class B6ZoomFixtureWebView: WKWebView {
  private(set) var responderRequests = 0
  override func becomeFirstResponder() -> Bool {
    responderRequests += 1
    return super.becomeFirstResponder()
  }
  override func load(_ request: URLRequest) -> WKNavigation? { nil }
  override func loadSimulatedRequest(_ request: URLRequest, responseHTML string: String)
    -> WKNavigation
  {
    super.loadSimulatedRequest(request, responseHTML: InterfaceZoomFixture.geometryHTML)
  }
}
