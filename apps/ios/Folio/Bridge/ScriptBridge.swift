import Foundation
import WebKit

@MainActor
final class ScriptBridge: NSObject, WKScriptMessageHandler {
  static let world = WKContentWorld.world(name: "FolioDiagnostics")
  weak var webView: WKWebView?
  var visibleTextEditing = false
  var domEditorFocused = true
  var shortcutState: ((Int) -> Void)?
  var resizeEdges: ((String) -> Void)?
  var receive: ((BridgeMessage) -> Void)?

  static var labURL: URL? {
    Bundle.main.url(forResource: "input-lab", withExtension: "html", subdirectory: "Compat")
  }
  static var focusLabURL: URL? {
    Bundle.main.url(forResource: "focus-lab", withExtension: "html", subdirectory: "Compat")
  }
  static func acceptsFrame(url: URL?, protocolName: String) -> Bool {
    guard let url, url.scheme == protocolName else { return false }
    return (protocolName == "https" && url.host != nil)
      || ([labURL, focusLabURL, MemoryLabBridge.url].contains(url) && protocolName == "file")
  }

  static func acceptsSender(isMainFrame: Bool, sender: WKWebView?, current: WKWebView?) -> Bool {
    isMainFrame && sender != nil && sender === current
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    if message.name == "folioDOMEditorFocused" {
      guard
        Self.acceptsSender(
          isMainFrame: message.frameInfo.isMainFrame, sender: message.webView, current: webView),
        Self.acceptsFrame(
          url: message.frameInfo.request.url,
          protocolName: message.frameInfo.securityOrigin.protocol),
        let editing = message.body as? Bool
      else { return }
      domEditorFocused = editing
      return
    }
    if message.name == "folioVisibleTextEditing" {
      guard
        Self.acceptsSender(
          isMainFrame: message.frameInfo.isMainFrame, sender: message.webView, current: webView),
        Self.acceptsFrame(
          url: message.frameInfo.request.url,
          protocolName: message.frameInfo.securityOrigin.protocol),
        let editing = message.body as? Bool
      else { return }
      visibleTextEditing = editing
      return
    }
    if message.name == "folioResize" {
      guard
        Self.acceptsSender(
          isMainFrame: message.frameInfo.isMainFrame, sender: message.webView, current: webView),
        Self.acceptsFrame(
          url: message.frameInfo.request.url,
          protocolName: message.frameInfo.securityOrigin.protocol),
        message.body as? String == "grab"
      else { return }
      resizeEdges?("grab")
      return
    }
    if message.name == "touchShortcutState" {
      guard
        Self.acceptsSender(
          isMainFrame: message.frameInfo.isMainFrame, sender: message.webView, current: webView),
        Self.acceptsFrame(
          url: message.frameInfo.request.url,
          protocolName: message.frameInfo.securityOrigin.protocol),
        let mask = message.body as? Int, (0...170).contains(mask)
      else { return }
      shortcutState?(mask)
      return
    }
    guard message.name == "folio",
      Self.acceptsSender(
        isMainFrame: message.frameInfo.isMainFrame, sender: message.webView, current: webView),
      Self.acceptsFrame(
        url: message.frameInfo.request.url, protocolName: message.frameInfo.securityOrigin.protocol),
      let value = BridgeMessage.validate(message.body)
    else { return }
    if case .labResults = value, message.frameInfo.request.url != Self.labURL { return }
    receive?(value)
  }
}

@MainActor
enum WebViewConfiguration {
  private static func labScript(_ source: String, url: URL?) -> String {
    guard let url,
      let data = try? JSONEncoder().encode(url.absoluteString),
      let literal = String(data: data, encoding: .utf8)
    else { preconditionFailure("Missing bundled lab URL") }
    // The suffix check in the bundle is not an origin boundary. Only our exact resource runs it.
    return "if (location.href === \(literal)) {\n\(source)\n}"
  }
  static func make(
    mode: BrowserMode, bridge: ScriptBridge, memoryBridge: MemoryLabBridge? = nil,
    uaButtonColor: Bool = InputStrategies().uaButtonColor,
    hideGoogle: Bool = InputStrategies().hideGoogle,
    phoneLayout: Bool = false, phoneMinimize: Bool = true, phoneWide: Bool = false,
    phoneNumbers: Bool = false, phoneSides: Bool = false,
    focusRevealGuard: Bool = InputStrategies().focusRevealGuard,
    focusViewportLimit: Bool = InputStrategies().focusViewportLimit,
    hardwareKeyboardAssistant: Bool = InputStrategies().hardwareKeyboardAssistant,
    websiteDataStore: WKWebsiteDataStore = .default(),
    touchGestures: Bool = InputStrategies().touchGestures, home: Bool = false,
    fingerCanvasWheel: Bool = InputStrategies().fingerCanvasWheel,
    trackpadZoom: Bool = InputStrategies().trackpadPinchZoom,
    resizeHelper: Bool? = nil, touchMode: TouchMode = InputStrategies().touchMode
  )
    -> WKWebViewConfiguration
  {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = websiteDataStore
    // Public setting: respect viewport scale limits. Default is already false.
    config.ignoresViewportScaleLimits = false
    // iPhone: request the desktop website, as Safari's "Request Desktop Website" does.
    // Public WebKit API; WebKit picks its own desktop user agent. Already the iPad default.
    if PhoneExperiencePolicy.isPhone {
      config.defaultWebpagePreferences.preferredContentMode = .desktop
    }
    if mode != .safe {
      config.userContentController.add(bridge, contentWorld: ScriptBridge.world, name: "folio")
      config.userContentController.add(
        bridge, contentWorld: ScriptBridge.world, name: "touchShortcutState")
      config.userContentController.add(
        bridge, contentWorld: ScriptBridge.world, name: "folioResize")
      config.userContentController.add(
        bridge, contentWorld: ScriptBridge.world, name: "folioVisibleTextEditing")
      config.userContentController.add(
        bridge, contentWorld: ScriptBridge.world, name: "folioDOMEditorFocused")
      #if DEBUG
        if let memoryBridge {
          config.userContentController.addScriptMessageHandler(
            memoryBridge, contentWorld: ScriptBridge.world, name: "memoryProgress")
          guard
            let url = Bundle.main.url(
              forResource: "memory-lab", withExtension: "js", subdirectory: "Compat"),
            let source = try? String(contentsOf: url, encoding: .utf8)
          else { preconditionFailure("Missing memory lab script") }
          config.userContentController.addUserScript(
            WKUserScript(
              source: labScript(source, url: MemoryLabBridge.url), injectionTime: .atDocumentStart,
              forMainFrameOnly: true, in: ScriptBridge.world))
        }
      #endif
      for name in [
        "bridge", "diagnostics", "input-log", "focus-environment", "focus-reveal-guard",
        "touch-shortcuts", "resize-edges", "touch-gestures", "pencil",
        "canvas-wheel",
        "ua-button-color",
        "hide-google",
        "input-lab",
        // Inert until native enables it for a compact-layout file tab (any device).
        "phone-layout",
      ] {
        guard
          let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "Compat"),
          let source = try? String(contentsOf: url, encoding: .utf8)
        else { preconditionFailure("Missing bundled Folio script: \(name)") }
        let configuredSource =
          name == "touch-gestures"
          ? source + "\nglobalThis.__folio?.setTouchGestures?.(\(touchGestures), \(home));"
          : name == "resize-edges"
            ? source + "\nglobalThis.__folio?.setResizeEdges?.(\(resizeHelper ?? touchGestures));"
            : name == "focus-reveal-guard"
              ? source + "\nglobalThis.__folio?.setFocusRevealGuard?.(\(focusRevealGuard));"
              : name == "focus-environment"
                ? source
                  + "\nglobalThis.__folio?.setFocusEnvironment?.(\(focusViewportLimit), \(hardwareKeyboardAssistant));"
                : name == "canvas-wheel"
                  ? source
                    + "\nglobalThis.__folio?.setCanvasWheel?.(\(fingerCanvasWheel));"
                    + "\nglobalThis.__folio?.setTrackpadZoom?.(\(trackpadZoom));"
                  : name == "ua-button-color"
                    ? source + "\nglobalThis.__folio?.setUAButtonColor?.(\(uaButtonColor));"
                    : name == "hide-google"
                      ? source + "\nglobalThis.__folio?.setHideGoogle?.(\(hideGoogle));"
                      : name == "phone-layout"
                        ? source
                          + "\nglobalThis.__folio?.setPhoneLayout?.(\(phoneLayout), \(phoneMinimize), \(phoneWide), \(phoneNumbers), \(phoneSides));"
                        : source
        config.userContentController.addUserScript(
          WKUserScript(
            source: name == "input-lab"
              ? labScript(source, url: ScriptBridge.labURL) : configuredSource,
            injectionTime: .atDocumentStart, forMainFrameOnly: true,
            in: ScriptBridge.world))
      }
    }
    if mode != .safe {
      config.userContentController.addUserScript(
        WKUserScript(
          source: touchModeSource(touchMode), injectionTime: .atDocumentStart,
          forMainFrameOnly: true, in: ScriptBridge.world))
    }
    return config
  }
  static let touchModeMarker = "// Folio touch mode\n"
  static func touchModeSource(_ mode: TouchMode) -> String {
    touchModeMarker + "globalThis.__folio?.setTouchMode?.('\(mode.rawValue)'); void 0"
  }
}
