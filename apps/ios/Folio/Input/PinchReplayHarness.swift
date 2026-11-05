#if DEBUG
  import QuartzCore
  import UIKit
  import WebKit

  // Opt-in device instrumentation. Observes zoom UI only, never canvas/document data.
  @MainActor
  final class PinchReplayHarness {
    static let scratchName = "Folio automation (safe to delete)"
    private weak var webView: WKWebView?
    private let trackpad: TrackpadPinch
    private let transport: PinchTransport
    private let allowed: () -> Bool
    private let status = UILabel()
    private var controls: UIStackView?
    private var operation = UUID()
    private var task: Task<Void, Never>?
    private var lastTrace: CallbackTrace?
    private var currentTrace: CallbackTrace?
    private var captureURL: URL?
    private var observerToken: UUID?
    var onSave: ((CallbackTrace) -> Void)?

    final class CallbackTrace: Encodable {
      static let limit = 4096
      let source: String
      let origin: Double
      var callbacks: [PinchCallbackSample] = []
      var dispatches: [Timing] = []
      var completions: [Timing] = []
      var dropped = 0
      var liftTimes: [Double] = []
      var response: String?
      var observerStartBefore = 0.0
      var observerStartAfter = 0.0
      struct Timing: Encodable {
        let time: Double
        let sentAt: Double
        let scale: Double
        let phase: String
      }
      init(source: String, origin: Double) {
        self.source = source
        self.origin = origin
      }
      func append(_ sample: PinchCallbackSample) {
        if callbacks.count < Self.limit { callbacks.append(sample) } else { dropped += 1 }
      }
      func timing(_ update: PinchUpdate, sentAt: Double, time: Double, completion: Bool) {
        let sample = Timing(
          time: time, sentAt: sentAt, scale: update.scale, phase: update.phase.rawValue)
        if completion {
          if completions.count < Self.limit { completions.append(sample) } else { dropped += 1 }
        } else {
          if dispatches.count < Self.limit { dispatches.append(sample) } else { dropped += 1 }
        }
      }
    }

    init(
      webView: WKWebView, trackpad: TrackpadPinch, transport: PinchTransport,
      allowed: @escaping () -> Bool
    ) {
      self.webView = webView
      self.trackpad = trackpad
      self.transport = transport
      self.allowed = allowed
    }

    func install(in view: UIView) {
      controls?.removeFromSuperview()
      let row = UIStackView()
      controls = row
      row.axis = .vertical
      row.backgroundColor = .systemBackground
      row.translatesAutoresizingMaskIntoConstraints = false
      status.text = "Pinch harness ready"
      status.accessibilityIdentifier = "pinch-harness-status"
      status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
      row.addArrangedSubview(status)
      let buttons = UIStackView()
      for route in ["wheel", "gesture"] {
        let button = UIButton(type: .system)
        button.setTitle("Replay \(route)", for: .normal)
        button.accessibilityIdentifier = "pinch-replay-\(route)"
        let names =
          route == "wheel"
          ? ["map-10", "map-25", "map-50", "map-100", "map+25", "out-hold", "flick", "slow-in"]
          : ["out-hold", "flick", "slow-in"]
        button.menu = UIMenu(
          children: names.map { name in
            UIAction(title: name) { [weak self] _ in self?.run(route: route, name: name) }
          })
        button.showsMenuAsPrimaryAction = true
        buttons.addArrangedSubview(button)
      }
      for (title, identifier) in [
        ("Record real pinch (15s)", "pinch-record-real"),
        ("Mark lift", "pinch-record-lift"),
        ("Stop recording", "pinch-record-stop"), ("Replay last real trace", "pinch-replay-real"),
      ] {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = identifier
        button.addAction(
          UIAction { [weak self] _ in
            if identifier == "pinch-record-lift" {
              self?.markLift()
            } else if identifier == "pinch-record-stop" {
              self?.cancel()
            } else {
              self?.recordCallbacks(replay: identifier == "pinch-replay-real")
            }
          }, for: .touchUpInside)
        row.addArrangedSubview(button)
      }
      let drawing = UIButton(type: .system)
      drawing.setTitle("Scratch drawing setup", for: .normal)
      drawing.addAction(
        UIAction { [weak self] _ in
          guard let self, self.allowed(),
            TabSession.documentTitle(self.webView?.title) == Self.scratchName
          else { return }
          self.webView?.evaluateJavaScript(
            "globalThis.__folio?.setCanvasWheel?.(false); void 0", in: nil, in: ScriptBridge.world
          ) { _ in }
        }, for: .touchUpInside)
      row.addArrangedSubview(drawing)
      row.addArrangedSubview(buttons)
      view.addSubview(row)
      NSLayoutConstraint.activate([
        row.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        row.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        row.widthAnchor.constraint(equalToConstant: 260),
      ])
    }

    func markLift() {
      guard trackpad.onCallback != nil, let trace = currentTrace else { return }
      if trace.liftTimes.count < CallbackTrace.limit {
        trace.liftTimes.append(CACurrentMediaTime())
      } else {
        trace.dropped += 1
      }
    }

    func isBound(to browser: WKWebView) -> Bool { webView === browser }

    func uninstall() {
      cancel(captureBrowser: false)
      controls?.removeFromSuperview()
      controls = nil
      webView = nil
    }

    func cancel(captureBrowser: Bool = true) {
      operation = UUID()
      let stopToken = operation
      if let currentTrace {
        // Native partial output is synchronous even if WebContent cannot reply.
        save(currentTrace)
        if captureBrowser, currentTrace.observerStartAfter > 0, allowed(), let browser = webView,
          let observerToken,
          browser.url == captureURL,
          TabSession.documentTitle(browser.title) == Self.scratchName
        {
          let sourceURL = captureURL
          // One evaluation, submitted before invalidation. Never probe a successor/inactive view.
          browser.evaluateJavaScript(
            "(() => { const p = globalThis.__folioPinchProbe; if (!p || p.captureToken !== '\(observerToken.uuidString)') return null; const result = p.finish(); p.dispose(); delete globalThis.__folioPinchProbe; return result; })()",
            in: nil, in: ScriptBridge.world
          ) { [weak self, weak browser] result in
            guard let self, let browser, self.operation == stopToken,
              self.webView === browser, self.allowed(), browser.url == sourceURL,
              TabSession.documentTitle(browser.title) == Self.scratchName,
              case .success(let value) = result, let response = value as? String,
              response.utf8.count <= 2_000_000
            else { return }
            currentTrace.response = response
            self.save(currentTrace)
          }
        }
      }
      currentTrace = nil
      trackpad.cancelReplay()
      transport.reset()
      trackpad.onCallback = nil
      transport.onDispatch = nil
      transport.onCompletion = nil
      task?.cancel()
      task = nil
    }

    func recordCallbacks(replay: Bool) {
      guard task == nil else { return }
      guard allowed(), let webView,
        TabSession.documentTitle(webView.title) == Self.scratchName
      else {
        status.text = "Blocked: active Normal/Compatibility scratch required"
        return
      }
      captureURL = webView.url
      let recorded = lastTrace
      if replay && recorded == nil { return }
      operation = UUID()
      let token = operation
      observerToken = token
      task = Task { [weak self] in
        guard let self, operation == token, !Task.isCancelled else { return }
        let trace = CallbackTrace(
          source: replay ? "recorded-replay" : "real-callbacks",
          origin: CACurrentMediaTime())
        currentTrace = trace
        defer {
          if operation == token {
            trackpad.onCallback = nil
            transport.onDispatch = nil
            transport.onCompletion = nil
            task = nil
            currentTrace = nil
          }
        }
        do {
          trace.observerStartBefore = CACurrentMediaTime()
          _ = try await evaluate(
            Self.observer
              + "\n globalThis.__folioPinchProbe.captureToken = '\(token.uuidString)'; globalThis.__folioPinchProbe.start(); 'started'"
          )
          trace.observerStartAfter = CACurrentMediaTime()
          try Task.checkCancellation()
          guard allowed() else { throw CocoaError(.userCancelled) }
          transport.onDispatch = { update, time in
            trace.timing(update, sentAt: time, time: time, completion: false)
          }
          transport.onCompletion = { update, sentAt, time in
            trace.timing(update, sentAt: sentAt, time: time, completion: true)
          }
          status.text = replay ? "Replaying recorded callbacks" : "Recording real callbacks for 15s"
          if replay, let recorded {
            transport.reset()
            let start = CACurrentMediaTime()
            for sample in recorded.callbacks {
              let wait = start + sample.time - recorded.origin - CACurrentMediaTime()
              if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
              try Task.checkCancellation()
              guard allowed(), TabSession.documentTitle(webView.title) == Self.scratchName else {
                throw CocoaError(.userCancelled)
              }
              var emitted = sample
              emitted.time = CACurrentMediaTime()
              trace.append(emitted)
              trackpad.replayCallback(sample)
            }
            try await Task.sleep(for: .seconds(1.2))
          } else {
            lastTrace = trace
            trackpad.onCallback = { trace.append($0) }
            try await Task.sleep(for: .seconds(15))
          }
        } catch {
          // Stop/disable/tab cancellation still exports the bounded partial trace.
        }
        // cancel() already saved the native partial trace synchronously.
        // Late work cannot clear successor callbacks or overwrite its output.
        guard operation == token else { return }
        trackpad.onCallback = nil
        transport.onDispatch = nil
        transport.onCompletion = nil
        if replay && operation == token {
          trackpad.cancelReplay()
          transport.reset()
          _ = try? await evaluate("globalThis.__folio?.resetTrackpadPinch?.(); 'reset'")
        }
        trace.response = try? await evaluate(
          "globalThis.__folioPinchProbe.finish()")
        _ = try? await evaluate(
          "globalThis.__folioPinchProbe?.dispose(); delete globalThis.__folioPinchProbe; 'disposed'"
        )
        if operation == token { save(trace) }
      }
    }

    private func save(_ trace: CallbackTrace) {
      if let onSave {
        onSave(trace)
        return
      }
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try encoder.encode(trace).write(
          to: directory.appendingPathComponent(
            trace.source == "recorded-replay"
              ? "pinch-real-replay.json" : "pinch-real-callbacks.json"),
          options: .atomic)
        status.text = "Saved \(trace.source), dropped \(trace.dropped)"
      } catch { status.text = "Recording save failed" }
    }

    func evaluate(_ script: String) async throws -> String {
      try Task.checkCancellation()
      guard allowed(), let webView,
        captureURL == nil || webView.url == captureURL,
        TabSession.documentTitle(webView.title) == Self.scratchName
      else { throw CocoaError(.userCancelled) }
      let result = try await webView.evaluateJavaScript(
        script, in: nil, contentWorld: ScriptBridge.world)
      try Task.checkCancellation()
      guard allowed(), self.webView === webView,
        captureURL == nil || webView.url == captureURL
      else { throw CocoaError(.userCancelled) }
      guard let string = result as? String else { throw CocoaError(.coderInvalidValue) }
      return string
    }

    private func run(route: String, name: String) {
      guard task == nil else { return }
      guard allowed(), let webView else {
        status.text = "Blocked: active Normal/Compatibility scratch required"
        return
      }
      // Never send automation input to any other file, even after a navigation.
      guard
        webView.title == Self.scratchName + " – Figma"
          || webView.title == Self.scratchName + " - Figma"
          || webView.title == Self.scratchName
      else {
        status.text = "Blocked: open automation scratch file"
        return
      }
      captureURL = webView.url
      status.text = "Running \(route)"
      operation = UUID()
      let token = operation
      task = Task { [weak self] in
        guard let self, operation == token, !Task.isCancelled else { return }
        defer {
          if operation == token {
            task = nil
            transport.onDispatch = nil
          }
        }
        var routeToRestore: String?
        do {
          let previousRoute = try await evaluate(
            "JSON.stringify(globalThis.__folio?.trackpadPinchStats?.().route ?? 'wheel')")
          routeToRestore = previousRoute
          let setup = try await evaluate(
            Self.observer + "\n globalThis.__folio?.setTrackpadPinchRoute?.('\(route)'); 'ready'")
          guard setup == "ready" else { return }
          let gainString = try await evaluate(
            "String(globalThis.__folio?.trackpadPinchGain?.() ?? 0.35)")
          guard let gain = Double(gainString), gain.isFinite, gain > 0 else {
            throw CocoaError(.coderInvalidValue)
          }
          let origin = CACurrentMediaTime()
          var inputs: [NativeSample] = []
          var sends: [NativeSample] = []
          transport.reset()
          transport.onDispatch = { update, time in
            sends.append(
              NativeSample(
                t: (time - origin) * 1000, scale: update.scale, phase: update.phase.rawValue))
          }
          // Mapping probes then 120 Hz movement/hold/release, flick, slow pinch-in.
          let mappings: [String: Double] = [
            "map-10": -10, "map-25": -25, "map-50": -50, "map-100": -100, "map+25": 25,
          ]
          let sequences: [(String, Double, Double, Double)]
          if let dy = mappings[name] {
            sequences = [(name, 1.0 / 120, exp(-dy / (100 * gain)), 0)]
          } else if name == "out-hold" {
            sequences = [(name, 0.6, 1.6, 1.0)]
          } else if name == "flick" {
            sequences = [(name, 0.08, 1.25, 0)]
          } else {
            sequences = [(name, 1.2, 0.8, 0)]
          }
          var records: [[String: String]] = []
          for (name, duration, finalScale, hold) in sequences {
            guard TabSession.documentTitle(webView.title) == Self.scratchName else {
              throw CocoaError(.userCancelled)
            }
            let start = CACurrentMediaTime()
            let anchor = CGPoint(x: webView.bounds.width * 0.5, y: webView.bounds.height * 0.5)
            _ = try await evaluate("globalThis.__folioPinchProbe.start(); 'started'")
            inputs.append(
              NativeSample(t: (CACurrentMediaTime() - origin) * 1000, scale: 1, phase: "began"))
            trackpad.replay(.began, cumulativeScale: 1, location: anchor)
            let frames = max(1, Int((duration * 120).rounded()))
            for frame in 1...frames {
              let deadline = start + duration * Double(frame) / Double(frames)
              let wait = deadline - CACurrentMediaTime()
              if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
              guard allowed(), TabSession.documentTitle(webView.title) == Self.scratchName else {
                throw CocoaError(.userCancelled)
              }
              let scale = exp(log(finalScale) * Double(frame) / Double(frames))
              inputs.append(
                NativeSample(
                  t: (CACurrentMediaTime() - origin) * 1000, scale: scale, phase: "changed"))
              trackpad.replay(.changed, cumulativeScale: scale, location: anchor)
            }
            if hold > 0 { try await Task.sleep(for: .seconds(hold)) }
            try Task.checkCancellation()
            guard allowed() else { throw CocoaError(.userCancelled) }
            let released = (CACurrentMediaTime() - start) * 1000
            inputs.append(
              NativeSample(
                t: (CACurrentMediaTime() - origin) * 1000, scale: finalScale, phase: "ended"))
            trackpad.replay(.ended, cumulativeScale: finalScale, location: anchor)
            try await Task.sleep(for: .seconds(1.2))
            let response = try await evaluate("globalThis.__folioPinchProbe.finish()")
            records.append([
              "name": name, "durationMs": "\(duration * 1000)", "releaseMs": "\(released)",
              "targetScale": "\(finalScale)", "response": response,
              "nativeStartMs": "\((start - origin) * 1000)", "anchorX": "\(anchor.x)",
              "anchorY": "\(anchor.y)",
            ])
          }
          _ = try await evaluate(
            "globalThis.__folioPinchProbe.dispose(); delete globalThis.__folioPinchProbe; 'disposed'"
          )
          let payload = Payload(
            route: route, records: records, inputs: inputs, sends: sends,
            device: UIDevice.current.model, os: UIDevice.current.systemVersion, gain: gain,
            sourceRevision: ProcessInfo.processInfo.environment["FOLIO_SOURCE_REVISION"]
              ?? "unrecorded")
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          let data = try encoder.encode(payload)
          let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          try data.write(
            to: directory.appendingPathComponent("pinch-harness-\(route)-\(name).json"),
            options: .atomic)
          _ = try await evaluate(
            "globalThis.__folio?.setTrackpadPinchRoute?.(\(previousRoute)); 'restored'")
          status.text = "Complete \(route) \(name)"
        } catch {
          _ = try? await evaluate(
            "globalThis.__folioPinchProbe?.dispose(); delete globalThis.__folioPinchProbe; 'disposed'"
          )
          if let routeToRestore {
            _ = try? await evaluate(
              "globalThis.__folio?.setTrackpadPinchRoute?.(\(routeToRestore)); 'restored'")
          }
          if operation == token { status.text = "Harness failed: \(error.localizedDescription)" }
        }
      }
    }

    private struct NativeSample: Encodable {
      let t: Double
      let scale: Double
      let phase: String
    }

    private struct Payload: Encodable {
      let route: String
      let records: [[String: String]]
      let inputs: [NativeSample]
      let sends: [NativeSample]
      let device: String
      let os: String
      let gain: Double
      let sourceRevision: String
    }

    static let observer = #"""
      (() => {
        globalThis.__folioPinchProbe?.dispose();
        let samples = [], events = [], started = 0, raf = 0, dropped = 0;
        const limit = 4096;
        const bounded = (list, item) => { if (list.length < limit) list.push(item); else dropped++; };
        const finite = value => Number.isFinite(value) ? value : null;
        const capabilities = {constructor: typeof globalThis.GestureEvent === 'function', legacyInitializer: false, constructorScale: null, constructorError: null, legacyError: null};
        try { capabilities.legacyInitializer = typeof document.createEvent('GestureEvent').initGestureEvent === 'function'; } catch (e) { capabilities.legacyError = e.name; }
        if (capabilities.constructor) try { capabilities.constructorScale = new globalThis.GestureEvent('gesturechange', {scale:1.25}).scale; } catch (e) { capabilities.constructorError = e.name; }

        // Only toolbar zoom controls. Never walk canvas/layer text or editor inputs.
        const zoom = () => {
          for (const button of Array.from(document.querySelectorAll('button[aria-label*="zoom"],button[title*="zoom"]')).slice(0,32)) {
            const label = button.getAttribute('aria-label') || '';
            const text = button.textContent?.trim() || '';
            // FRAGILE_FIGMA_DEPENDENCY: DEBUG observation of the zoom toolbar label only.
            const match = /^(\d+(?:\.\d+)?)%$/.exec(text)
              || /^(\d+(?:\.\d+)?)%.*zoom/i.exec(label);
            if (match) { const value = Number(match[1]); if (Number.isFinite(value) && value > 0 && value <= 100000) return value; }
          }
          return null;
        };
        const onEvent = e => {
          if (e.type !== 'wheel' || e.ctrlKey)
            bounded(events,{t:performance.now()-started,type:e.type,trusted:e.isTrusted,dy:finite(e.deltaY),scale:finite(e.scale)});
        };
        const names = ['wheel','gesturestart','gesturechange','gestureend'];
        const born = performance.now();
        const onVisibility = () => { if (document.hidden) dispose(); };
        const dispose = () => {
          cancelAnimationFrame(raf);
          for (const name of names) window.removeEventListener(name,onEvent,true);
          window.removeEventListener('pagehide',dispose);
          window.removeEventListener('visibilitychange',onVisibility);
        };
        window.addEventListener('pagehide',dispose);
        window.addEventListener('visibilitychange',onVisibility);
        // Cancellation never runs scripts in another generation. Old observers self-expire.

        for (const name of names) window.addEventListener(name,onEvent,true);
        const tick = () => { if (performance.now()-born >= 20000 || document.hidden) { dispose(); return; } bounded(samples,{t:performance.now()-started,zoom:zoom()}); raf=requestAnimationFrame(tick); };
        globalThis.__folioPinchProbe = {
          start() { cancelAnimationFrame(raf); samples=[]; events=[]; dropped=0; started=performance.now(); tick(); },
          finish() { cancelAnimationFrame(raf); return JSON.stringify({samples,events,dropped,capabilities,stats:globalThis.__folio?.trackpadPinchStats?.()}); },
          dispose
        };
      })();
      """#
  }
#endif
