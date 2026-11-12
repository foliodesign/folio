import GameController
import UIKit
import os

@MainActor
final class DiagnosticsStore {
  static let compatVersion = "0.1.0"
  let session: SessionState
  let strategies: InputStrategies
  var tabID: UUID?
  var windowID: UUID?
  var labResults: [String: String] = [:]
  var recognizersChanged = 0
  var isInputLab = false
  var isMemoryLab = false
  var activeLab: DeveloperLab?
  let memory: MemoryLabStore
  var availableMemory: UInt64 { UInt64(os_proc_available_memory()) }

  func memoryEvent(_ event: String) {
    do { try memory.append(event: event, availableBytes: availableMemory) } catch {
      lifecycle("Memory report persistence failed")
    }
    writeSmokeReportIfRequested()
  }
  var screen: UIScreen?
  var environment: EnvironmentCapture?
  var currentURL: URL?
  var windowRouteReport: (() -> [String])?
  var pinchReport: (() -> String)?
  var focusState = "awaiting sample"
  var inputLogging = false
  var uiDragLogging = false
  private var generalEvents: [String] = []
  private var uiDragEvents: [String] = []
  var events: [String] { generalEvents + uiDragEvents }
  private let logger = Logger(subsystem: "app.foliodesign.folio", category: "diagnostics")

  init(
    session: SessionState, strategies: InputStrategies = InputStrategies(),
    memory: MemoryLabStore = MemoryLabStore()
  ) {
    self.session = session
    self.strategies = strategies
    self.memory = memory
  }

  func log(_ message: String) {
    let clean = Privacy.sanitize(message)
    generalEvents.append("\(ISO8601DateFormatter().string(from: Date())) \(clean)")
    if generalEvents.count > 500 { generalEvents.removeFirst(generalEvents.count - 500) }
    // No input data in system logs, even when the in-memory input ring is enabled.
  }

  func clearEvents() {
    generalEvents.removeAll()
    uiDragEvents.removeAll()
  }

  /// Short label/value pairs for the Developer Tools overview.
  var overview: [(String, String)] {
    var system = utsname()
    uname(&system)
    let identifier = withUnsafeBytes(of: &system.machine) { bytes in
      String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    let ua = environment?.userAgent ?? ""
    let webkit =
      ua.range(of: #"AppleWebKit/[^\s]+"#, options: .regularExpression).map { String(ua[$0]) }
      ?? "Not captured yet"
    let gib = { (bytes: UInt64) in String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
    let page = activeLab?.title ?? Privacy.redactedURL(currentURL)
    return [
      ("Device", identifier), (UIDevice.current.systemName, UIDevice.current.systemVersion),
      ("WebKit", webkit),
      ("Memory", gib(ProcessInfo.processInfo.physicalMemory)),
      ("Available to Folio", gib(availableMemory)),
      ("Folio", DeveloperToolsController.version), ("Compat scripts", Self.compatVersion),
      ("Mode", session.mode.rawValue), ("WebContent crashes", String(session.crashCount)),
      ("Page", page),
    ]
  }

  func lifecycle(_ message: String) {
    log(message)
    logger.info("\(Privacy.sanitize(message), privacy: .public)")
  }

  func record(_ input: InputCapture) {
    guard inputLogging else { return }
    log(
      "JS \(input.type) pointer=\(input.pointerType) trusted=\(input.isTrusted) button=\(input.button) buttons=\(input.buttons) prevented=\(input.prevented) coalesced=\(input.coalesced) pressure=\(input.pressure) tilt=\(input.tiltX),\(input.tiltY) xy=\(input.x),\(input.y) wheel=\(input.deltaX),\(input.deltaY) key=\(input.key) alt=\(input.alt) ctrl=\(input.ctrl) meta=\(input.meta) shift=\(input.shift)"
    )
  }
  func record(_ routing: KeyboardRoutingCapture) {
    guard inputLogging else { return }
    log(
      "JS keyboard \(routing.event.rawValue) chord=\(routing.chord.rawValue) phase=\(routing.phase.rawValue) history=\(routing.history.rawValue) seq=\(routing.sequence) jsMS=\(routing.time) meta=\(routing.meta) shift=\(routing.shift) alt=\(routing.alt) ctrl=\(routing.ctrl) repeat=\(routing.repeat) composing=\(routing.isComposing) trusted=\(routing.isTrusted) prevented=\(routing.defaultPrevented) documentFocus=\(routing.documentFocus) tag=\(routing.tag) type=\(routing.inputType) editable=\(routing.editable) iframe=\(routing.iframe)"
    )
  }

  func record(_ focus: FocusCapture) {
    guard inputLogging else { return }
    if ["revealguard", "innerscroll"].contains(focus.event) {
      log(
        "JS \(focus.event) tag=\(focus.tag) container=\(focus.width),\(focus.height) scrollOrDelta=\(focus.offsetLeft),\(focus.offsetTop) jsMS=\(focus.time)"
      )
      return
    }
    log(
      "JS focus \(focus.event) tag=\(focus.tag) type=\(focus.inputType) inner=\(focus.innerWidth),\(focus.innerHeight) visualViewport=\(focus.width),\(focus.height) offset=\(focus.offsetLeft),\(focus.offsetTop) scale=\(focus.scale) windowScroll=\(focus.scrollX),\(focus.scrollY) jsMS=\(focus.time)"
    )
  }

  func record(_ drag: UIDragCapture) {
    guard uiDragLogging else { return }
    uiDragEvents.append(
      Privacy.sanitize(
        "UI drag #\(drag.drag) \(drag.kind) \(drag.type) target=\(drag.target) xy=\(drag.x),\(drag.y) buttons=\(drag.buttons) pointerId=\(drag.pointerId) pointerType=\(drag.pointerType) isPrimary=\(drag.isPrimary) defaultPrevented=\(drag.defaultPrevented) trusted=\(drag.trusted) detail=\(drag.detail) jsMS=\(drag.time)"
      ))
    if uiDragEvents.count > 2000 { uiDragEvents.removeFirst(uiDragEvents.count - 2000) }
  }

  var report: String {
    var system = utsname()
    uname(&system)
    let identifier = withUnsafeBytes(of: &system.machine) { bytes in
      String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    let screenDescription =
      screen.map { "\($0.bounds.width) x \($0.bounds.height) points; scale \($0.scale)" }
      ?? "unavailable"
    let ua = environment?.userAgent ?? "unavailable (Safe mode or awaiting capture)"
    let webkit =
      ua.range(of: #"AppleWebKit/[^\s]+"#, options: .regularExpression).map { String(ua[$0]) }
      ?? "unavailable"
    var lines = [
      "Folio diagnostics",
      "Window: \(windowID?.uuidString ?? "standalone"); tab: \(tabID?.uuidString ?? "standalone")",
      "Device identifier: \(identifier)",
      "Simulator model: \(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "not simulator")",
      "\(UIDevice.current.systemName): \(UIDevice.current.systemVersion)", "WebKit: \(webkit)",
      "Screen: \(screenDescription)",
      "RAM: \(ProcessInfo.processInfo.physicalMemory) bytes", "Mode: \(session.mode.rawValue)",
      "Compat version: \(Self.compatVersion)\(session.mode == .safe ? " (disabled)" : "")",
      "WebContent crashes: \(session.crashCount)", "URL: \(Privacy.redactedURL(currentURL))",
    ]
    lines += [
      "Page: \(isMemoryLab ? "Bundled memory lab" : isInputLab ? "Bundled input lab" : "Network browser")",
      "Input strategies: \(strategies.label)",
      "trackpad pinch: \(pinchReport?() ?? "unavailable")",
      "Focus controls (configured): \(strategies.focusLabel)",
      "Reveal guard: restored=\(environment?.focusRevealGuard?.restored ?? 0) ignored=\(environment?.focusRevealGuard?.ignored ?? 0); captured=\(environment?.focusRevealGuard != nil)",
      "Keyboard ownership observation: Tier 2 WEBKIT_INTERNAL, input-logging toggle only; unknown includes non-view responders; action targets are probes",
      "Focus native state: \(focusState)",
      "GCKeyboard detected: \(GCKeyboard.coalesced != nil)",
      "Native Pencil interaction/hover: Tier 1; tap=\(strategies.tapAction.rawValue); squeeze=\(strategies.squeezeAction.rawValue)",
      "WEBKIT_INTERNAL changed recognizers: \(recognizersChanged); Pencil and Figma effects require device verification",
      "Adaptations: \(session.mode == .safe ? "disabled in Safe mode" : "enabled according to switches")",
      "Keyboard: Folio window commands request system priority and yield during composition or native/auth presentation; Safe mode command does not request priority; other keys use web/system routing",
      "Lab verdicts for current strategy, memory only:",
    ]
    if strategies.focusLabel != strategies.savedFocusLabel {
      lines.append("Focus controls (app default): \(strategies.savedFocusLabel)")
    }
    for group in ["Touch", "Mouse", "Trackpad", "Pencil", "Keyboard", "Text"] {
      let items = BridgeMessage.labItems.filter { item in
        group == "Touch"
          ? ["finger tap", "one-finger drag", "two-finger pan", "pinch"].contains(item)
          : item.lowercased().hasPrefix(group.lowercased())
      }.sorted()
      lines.append(
        "\(group) tests: "
          + items.map { "\(labResults[$0] ?? "NOT TESTED"): \($0)" }.joined(separator: "; "))
    }
    if let capture = environment {
      lines += [
        "userAgent: \(capture.userAgent)", "navigator.gpu: \(capture.gpuPresent)",
        "requestAdapter: \(capture.adapterResult)", "Adapter info: \(capture.adapterInfo)",
        "WebGL: \(capture.webgl.available); UNMASKED_RENDERER: \(capture.webgl.renderer); MAX_TEXTURE_SIZE: \(capture.webgl.maxTextureSize)",
        "WebGL2: \(capture.webgl2.available); UNMASKED_RENDERER: \(capture.webgl2.renderer); MAX_TEXTURE_SIZE: \(capture.webgl2.maxTextureSize)",
        "devicePixelRatio: \(capture.devicePixelRatio)",
        "Viewport: \(capture.viewportWidth) x \(capture.viewportHeight)",
        "maxTouchPoints: \(capture.maxTouchPoints)",
      ]
      lines += capture.media.keys.sorted().map { "matchMedia \($0): \(capture.media[$0] == true)" }
    }
    if let pinch = environment?.trackpadPinch {
      lines.append(
        "trackpad pinch JS (last capture): route=\(pinch.route.rawValue) dispatched=\(pinch.dispatched) prevented=\(pinch.prevented) gestureSupported=\(pinch.gestureSupported)"
      )
    }
    lines += ["Folio available memory now: \(availableMemory) bytes", memory.report]
    lines += [
      "UI drag logging: \(uiDragLogging)",
      "UI capture observation: got/lost capture and uncaught errors only. setPointerCapture/hasPointerCapture calls and caught exceptions cannot be observed without patching; absence of events proves nothing.",
      "UI drag labels: fixed UI labels only; other aria-labels redacted, no text/filenames/URLs or error messages.",
    ]
    lines +=
      [
        "Input logging: \(inputLogging)",
        "Events (latest 500 general + 2000 UI drag, memory only):",
      ] + events
    lines +=
      ["Window tab routes (latest 128, all tabs, input logging only):"]
      + (windowRouteReport?() ?? [])
    return Privacy.sanitize(lines.joined(separator: "\n"))
  }

  func writeSmokeReportIfRequested() {
    #if DEBUG
      guard ProcessInfo.processInfo.arguments.contains("--smoke-report"),
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      else { return }
      do {
        try report.write(
          to: folder.appendingPathComponent("simulator-report.txt"), atomically: true,
          encoding: .utf8)
      } catch { logger.error("Could not write simulator report") }
    #endif
  }
}
