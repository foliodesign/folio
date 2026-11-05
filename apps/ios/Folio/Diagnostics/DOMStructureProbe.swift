#if DEBUG
  import Foundation
  import WebKit

  /// Local structure-only capture. No script is installed, and this code is absent in Release.
  @MainActor
  extension FigmaWebViewController {
    func scheduleDOMProbe() {
      guard ProcessInfo.processInfo.arguments.contains("--folio-dom-probe") else { return }
      guard domProbeEligible else {
        writeDOMProbeStatus("ineligible")
        return
      }
      guard !domProbeAutoCaptured, domProbeTask == nil else { return }
      let browser = webView
      let file = domProbeFile
      domProbeTask = Task { [weak self, weak browser] in
        do { try await Task.sleep(for: .seconds(15)) } catch { return }
        guard let self else { return }
        self.domProbeTask = nil
        guard self.webView === browser, self.domProbeFile == file, self.domProbeEligible else {
          self.writeDOMProbeStatus("state-changed")
          self.scheduleDOMProbe()
          return
        }
        self.domProbeAutoCaptured = true
        self.captureDOMProbe()
      }
      writeDOMProbeStatus("scheduled")
    }

    // File identity stays in memory. Figma's SPA can change the title, query and fragment
    // after didFinish; those changes must not silently discard the delayed capture.
    private var domProbeFile: TabNavigationRouter.Destination? {
      guard let url = webView?.url,
        ["design", "file"].contains(url.path.split(separator: "/").first.map(String.init) ?? ""),
        case .file = TabNavigationRouter.classify(url)
      else { return nil }
      return TabNavigationRouter.classify(url)
    }

    private var domProbeEligible: Bool {
      isTabActive && initialPageReady && session.mode != .safe && !scriptFreeRelated
        && tabSession.kind == .document && domProbeFile != nil
        && viewIfLoaded?.window != nil
    }

    func captureDOMProbe() {
      writeDOMProbeStatus("requested")
      guard domProbeEligible, !domProbeRunning, domProbeCaptureCount < 20,
        let browser = webView,
        let url = Bundle.main.url(
          forResource: "dom-probe", withExtension: "js", subdirectory: "Compat"),
        let script = try? String(contentsOf: url, encoding: .utf8)
      else { return }
      domProbeRunning = true
      writeDOMProbeStatus("capturing")
      domProbeCaptureCount += 1
      let tools = ProcessInfo.processInfo.arguments.contains("--folio-dom-probe-tools")
      let file = domProbeFile
      browser.callAsyncJavaScript(
        script + "\nreturn await globalThis.__folioCaptureDOMStructure(tools);",
        arguments: ["tools": tools], in: nil, in: ScriptBridge.world
      ) { [weak self, weak browser] result in
        guard let self else { return }
        self.domProbeRunning = false
        guard self.webView === browser, self.domProbeFile == file, self.domProbeEligible else {
          self.writeDOMProbeStatus("state-changed")
          return
        }
        let data: Data
        switch result {
        case .success(let value):
          guard let string = value as? String, let bytes = string.data(using: .utf8),
            bytes.count <= 2_000_000,
            (try? JSONSerialization.jsonObject(with: bytes)) != nil
          else {
            self.writeDOMProbe(
              Data("{\"schema\":1,\"error\":\"invalid-or-oversized-result\"}".utf8))
            return
          }
          data = bytes
        case .failure:
          // WebKit error messages can contain URLs. Export only this fixed status.
          data = Data("{\"schema\":1,\"error\":\"evaluation-failed\"}".utf8)
        }
        self.writeDOMProbe(data)
        self.writeDOMProbeStatus("completed")
      }
    }

    private struct ProbeStatus: Encodable {
      let schema = 1
      let status: String
      let active: Bool
      let pageReady: Bool
      let attached: Bool
      let documentTab: Bool
      let fileRoute: Bool
      let safe: Bool
      let scriptFree: Bool
      let resourcePresent: Bool
      let scheduled: Bool
    }

    private func writeDOMProbeStatus(_ status: String) {
      let value = ProbeStatus(
        status: status, active: isTabActive, pageReady: initialPageReady,
        attached: viewIfLoaded?.window != nil, documentTab: tabSession.kind == .document,
        fileRoute: domProbeFile != nil, safe: session.mode == .safe,
        scriptFree: scriptFreeRelated,
        resourcePresent: Bundle.main.url(
          forResource: "dom-probe", withExtension: "js", subdirectory: "Compat") != nil,
        scheduled: domProbeTask != nil)
      if let data = try? JSONEncoder().encode(value) { writeDOMProbe(data, status: true) }
    }

    private func writeDOMProbe(_ data: Data, status: Bool = false) {
      do {
        let folder = try FileManager.default.url(
          for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("dom-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(
          status ? "status-\(domProbeStatusID.uuidString).json" : "probe-\(UUID().uuidString).json")
        try data.write(to: file, options: .atomic)
        diagnostics.lifecycle("DOM structure probe saved locally")
      } catch {
        diagnostics.lifecycle("DOM structure probe could not be saved")
      }
    }
  }
#endif
