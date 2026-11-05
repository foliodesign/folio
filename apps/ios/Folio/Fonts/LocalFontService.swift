#if DEBUG
  import Foundation
  import Network

  /// Tier 1, font bytes only. No proxy, WebKit configuration changes or TLS bypass.
  @MainActor
  final class LocalFontService {
    static let shared = LocalFontService()
    static let port: UInt16 = 44950
    /// The desktop helper's HTTPS port. Folio has no trusted identity for the host Figma uses there,
    /// so this listener only records connection attempts and closes them.
    static let tlsProbePort: UInt16 = 44960
    /// Helper protocol level observed from the desktop helper's version route on 2026-10-09.
    nonisolated static let protocolVersion = 24
    static let changed = Notification.Name("FolioLocalFontsChanged")
    private let defaults = UserDefaults.standard
    private var activeScenes: Set<String> = []
    private var listeners: [NWListener] = []
    private var connections: [UUID: NWConnection] = [:]
    private(set) var status = "Stopped"
    private(set) var requestCount = 0
    /// Newest first: time, method, fixed route or path (never query), status and rejection cause.
    private(set) var recent: [String] = []
    private var generation = UUID()

    var enabled: Bool {
      get {
        #if DEBUG
          defaults.bool(forKey: "folio.localFontsExperimental")
        #else
          false
        #endif
      }
      set {
        #if DEBUG
          defaults.set(newValue, forKey: "folio.localFontsExperimental")
          reconcile()
        #endif
      }
    }

    /// Debug-only diagnostic: new tabs present a desktop Chrome 141 user agent so a device test can
    /// show whether Figma then uses the HTTP port instead of its HTTPS-only route for WebKit.
    /// Browser-brand spoofing: Figma may enable Chrome-only paths, and Google's embedded-sign-in
    /// block may not trigger. Not a shipping route.
    nonisolated static let chromeProbeUserAgent =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    private init() {
      // The diagnostic UA probe never survives a relaunch.
      defaults.removeObject(forKey: "folio.localFontsChromeUserAgentProbe")
    }

    var chromeUserAgentProbe: Bool {
      get {
        #if DEBUG
          enabled && defaults.bool(forKey: "folio.localFontsChromeUserAgentProbe")
        #else
          false
        #endif
      }
      set {
        #if DEBUG
          defaults.set(newValue, forKey: "folio.localFontsChromeUserAgentProbe")
          publish()
        #endif
      }
    }

    func setActive(_ scene: String, _ active: Bool) {
      if active { activeScenes.insert(scene) } else { activeScenes.remove(scene) }
      reconcile()
    }

    func libraryChanged() {
      // Removal/replacement also closes in-flight responses containing old font bytes.
      if !listeners.isEmpty { stop() }
      reconcile()
      publish()
    }

    private func reconcile() {
      guard enabled, !activeScenes.isEmpty else {
        stop()
        status = enabled ? "Paused (no active window)" : "Stopped"
        publish()
        return
      }
      guard listeners.isEmpty else { return }
      let generation = UUID()
      self.generation = generation
      status = "Starting"
      // IPv6 loopback on the HTTP port lets the page probe compare localhost and [::1] with 127.0.0.1.
      let endpoints: [(host: NWEndpoint.Host, port: UInt16)] = [
        ("127.0.0.1", Self.port), ("::1", Self.port), ("127.0.0.1", Self.tlsProbePort),
      ]
      for (index, (host, port)) in endpoints.enumerated() {
        do {
          let parameters = NWParameters.tcp
          parameters.requiredLocalEndpoint = .hostPort(
            host: host, port: NWEndpoint.Port(rawValue: port)!)
          parameters.allowLocalEndpointReuse = false
          let listener = try NWListener(using: parameters)
          listeners.append(listener)
          listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
              guard let self, self.generation == generation else { return }
              switch state {
              case .ready where index == 0: self.status = "Running (HTTP)"
              case .failed where index == 0:
                self.stop()
                self.status = "Unavailable (port or listener error)"
              case .failed: self.log("Listener \(host):\(port) unavailable")
              default: break
              }
              self.publish()
            }
          }
          listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection, port: port) }
          }
          listener.start(queue: .main)
        } catch {
          if index == 0 {
            stop()
            status = "Unavailable (port or listener error)"
          }
        }
      }
      publish()
    }

    /// Records the result of Folio's own loopback fetch probe from the current page.
    func note(_ entry: String) { log(entry) }

    private func log(_ entry: String) {
      let time = Date().formatted(date: .omitted, time: .standard)
      recent.insert("\(time) \(entry)", at: 0)
      recent = Array(recent.prefix(12))
      publish()
    }

    private func stop() {
      generation = UUID()
      for listener in listeners { listener.cancel() }
      listeners.removeAll()
      for connection in connections.values { connection.cancel() }
      connections.removeAll()
    }

    private func accept(_ connection: NWConnection, port: UInt16) {
      guard port == Self.port else {
        // Figma's desktop helper serves HTTPS here; record the attempt, serve nothing.
        log("Connection on \(port) (HTTPS route, not served)")
        connection.cancel()
        return
      }
      guard enabled, !activeScenes.isEmpty, connections.count < 4 else {
        log("Connection dropped (limit or inactive)")
        connection.cancel()
        return
      }
      let id = UUID()
      connections[id] = connection
      connection.start(queue: .main)
      DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
        self?.finish(id)
      }
      receive(id, buffer: Data())
    }

    private func finish(_ id: UUID) {
      connections.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ id: UUID, buffer: Data) {
      guard let connection = connections[id] else { return }
      connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
        [weak self] data, _, complete, error in
        MainActor.assumeIsolated {
          guard let self, self.connections[id] != nil else { return }
          var buffer = buffer
          if let data { buffer.append(data) }
          if buffer.first == 0x16 {
            self.log("TLS handshake on \(Self.port) (page tried HTTPS)")
            self.finish(id)
            return
          }
          guard buffer.count <= 16384 else {
            self.finish(id)
            return
          }
          if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
            guard end.upperBound == buffer.count,
              let request = String(data: buffer, encoding: .utf8)
            else {
              self.finish(id)
              return
            }
            self.respond(id, request: request)
          } else if complete || error != nil {
            if buffer.isEmpty { self.log("Connection closed before a request") }
            self.finish(id)
          } else {
            self.receive(id, buffer: buffer)
          }
        }
      }
    }

    /// `package` is Folio's own version, not a desktop-helper build number.
    nonisolated private static let package =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private struct Version: Encodable {
      let version = LocalFontService.protocolVersion
      let package = LocalFontService.package
    }
    /// Same shape as the desktop helper's catalogue: font files keyed by file identifier.
    private struct Catalogue: Encodable {
      let version = LocalFontService.protocolVersion
      let package = LocalFontService.package
      let modifiedAt: Int
      let modifiedFonts: [String: [LocalFontFace]] = [:]
      let fontFiles: [String: [LocalFontFace]]

      enum CodingKeys: String, CodingKey {
        case version, package, fontFiles
        case modifiedAt = "modified_at"
        case modifiedFonts = "modified_fonts"
      }
    }

    private func respond(_ id: UUID, request: String) {
      let lines = request.components(separatedBy: "\r\n")
      let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
      let method = first.first.map(String.init) ?? "?"
      let pathOnly = first.count > 1 ? String(first[1].prefix { $0 != "?" }.prefix(48)) : "?"
      var entry = method + " " + pathOnly
      guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "OPTIONS"].contains(method) else {
        send(id, code: "405 Method Not Allowed", log: entry)
        return
      }
      var headers: [String: String] = [:]
      for line in lines.dropFirst() where !line.isEmpty {
        guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t")
        else {
          send(id, code: "400 Bad Request", log: entry)
          return
        }
        let key = line[..<colon].lowercased()
        guard headers[key] == nil else {
          send(id, code: "400 Bad Request", log: entry)
          return
        }
        headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      }
      let origin = headers["origin"]
      guard ["127.0.0.1:44950", "localhost:44950", "[::1]:44950"].contains(headers["host"] ?? "")
      else {
        send(id, code: "403 Forbidden", log: entry + " (host)")
        return
      }
      guard origin == "https://www.figma.com" else {
        send(id, code: "403 Forbidden", log: entry + (origin == nil ? " (no origin)" : " (origin)"))
        return
      }
      guard headers["transfer-encoding"] == nil,
        headers["content-length"] == nil || headers["content-length"] == "0"
      else {
        send(id, code: "403 Forbidden", log: entry + " (body)")
        return
      }
      let target = String(first[1])
      guard target.hasPrefix("/"), !target.hasPrefix("//"),
        let components = URLComponents(string: target), components.scheme == nil,
        components.host == nil, components.fragment == nil
      else {
        send(id, code: "400 Bad Request", cors: true, log: entry)
        return
      }
      let path =
        components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
      entry = method + " " + path  // Path only; query values (font identifiers) are never logged.
      guard ["/figma/version", "/figma/font-files", "/figma/font-file"].contains(path) else {
        send(id, code: "404 Not Found", cors: true, log: entry)
        return
      }
      if method == "OPTIONS" {
        let requestedHeaders = (headers["access-control-request-headers"] ?? "")
          .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard headers["access-control-request-method"] == "GET",
          requestedHeaders.allSatisfy({ ["content-type", "accept"].contains($0) }),
          headers["access-control-request-private-network"] == nil
            || headers["access-control-request-private-network"] == "true"
        else {
          send(id, code: "403 Forbidden", log: entry + " (preflight)")
          return
        }
        send(id, code: "204 No Content", cors: true, preflight: true, log: entry)
        return
      }
      do {
        switch path {
        case "/figma/version":
          send(id, body: try JSONEncoder().encode(Version()), cors: true, log: entry)
        case "/figma/font-files":
          let library = LocalFontLibrary.shared
          let catalogue = Catalogue(
            modifiedAt: Int(library.modifiedAt.timeIntervalSince1970),
            fontFiles: Dictionary(uniqueKeysWithValues: library.files.map { ($0.id, $0.faces) }))
          send(
            id, body: try JSONEncoder().encode(catalogue), cors: true,
            log: entry + " [\(library.faces.count) faces]")
        default:
          guard let items = components.queryItems, items.count == 1,
            items[0].name == "file", let value = items[0].value,
            let data = try LocalFontLibrary.shared.bytes(for: value)
          else {
            send(id, code: "404 Not Found", cors: true, log: entry)
            return
          }
          send(id, body: data, type: "application/octet-stream", cors: true, log: entry)
        }
      } catch { send(id, code: "500 Internal Server Error", cors: true, log: entry) }
    }

    private func send(
      _ id: UUID, code: String = "200 OK", body: Data = Data(),
      type: String = "application/json", cors: Bool = false, preflight: Bool = false,
      log entry: String
    ) {
      guard let connection = connections[id] else { return }
      requestCount += 1
      log(entry + " → " + code.prefix { $0 != " " })
      var header = "HTTP/1.1 \(code)\r\nContent-Length: \(body.count)\r\nContent-Type: \(type)\r\n"
      header += "Connection: close\r\nCache-Control: no-store\r\nServer: Folio/0.1.0\r\n"
      if cors {
        header += "Access-Control-Allow-Origin: https://www.figma.com\r\nVary: Origin\r\n"
      }
      if preflight {
        header +=
          "Access-Control-Allow-Methods: GET, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Accept\r\n"
        header += "Access-Control-Max-Age: 600\r\n"
        header += "Access-Control-Allow-Private-Network: true\r\n"
      }
      var response = Data((header + "\r\n").utf8)
      response.append(body)
      connection.send(
        content: response,
        completion: .contentProcessed { [weak self] _ in
          MainActor.assumeIsolated { self?.finish(id) }
        })
    }

    private func publish() {
      NotificationCenter.default.post(name: Self.changed, object: nil)
    }
  }

#else
  import Foundation

  @MainActor
  final class LocalFontService {
    static let shared = LocalFontService()
    static let changed = Notification.Name("FolioLocalFontsChanged")
    func setActive(_ scene: String, _ active: Bool) {}
    func libraryChanged() {
      NotificationCenter.default.post(name: Self.changed, object: nil)
    }
  }
#endif
