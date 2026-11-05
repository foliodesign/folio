#if DEBUG
  import WebKit

  @MainActor
  final class MemoryLabBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var webView: WKWebView?
    var persist: ((MemoryProgress) throws -> Void)?
    static var url: URL? {
      Bundle.main.url(forResource: "memory-lab", withExtension: "html", subdirectory: "Compat")
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage,
      replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
      guard message.name == "memoryProgress", message.webView === webView,
        message.frameInfo.isMainFrame, message.frameInfo.request.url == Self.url,
        message.frameInfo.securityOrigin.protocol == "file",
        let progress = Self.validate(message.body), let persist
      else {
        replyHandler(nil, "Invalid memory lab message")
        return
      }
      do {
        try persist(progress)
        replyHandler(true, nil)
      } catch { replyHandler(nil, "Native persistence failed; allocation stopped") }
    }

    static func validate(_ body: Any) -> MemoryProgress? {
      guard let object = body as? [String: Any],
        Set(object.keys) == [
          "runID", "kind", "stepMiB", "limitMiB", "delayMS", "timeoutSeconds", "touchPages",
          "successfulMiB", "attemptedMiB", "status",
        ],
        JSONSerialization.isValidJSONObject(object),
        let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 1024,
        let progress = try? JSONDecoder().decode(MemoryProgress.self, from: data), progress.isValid
      else { return nil }
      return progress
    }
  }

#else
  import WebKit

  @MainActor
  final class MemoryLabBridge {
    weak var webView: WKWebView?
    static var url: URL? { nil }
  }
#endif
