import Foundation
import WebKit

#if DEBUG
  enum TabFixture {
    /// A first-party response with a visible, committed browser-history entry.
    /// loadHTMLString follows WebKit's hidden substitute-data history path.
    @MainActor
    static func load(in browser: WKWebView, number: Int, url: URL) {
      let destination =
        TabNavigationRouter.classify(url) == .creation
        ? URL(string: "https://www.figma.com/design/created\(number)")! : url
      let editor =
        ProcessInfo.processInfo.arguments.contains("--phone-editor-fixture")
        && destination.path.hasPrefix("/design/")
      browser.loadSimulatedRequest(
        URLRequest(url: destination),
        responseHTML: editor ? editorHTML : html(number: number))
    }

    /// iPhone layout check: a synthetic page shaped like the editor's structure as measured on
    /// 2026-10-11 (rail 49, Layers 240 + 1, Properties 241, renderer-reserved canvas, hidden
    /// tool bar). No Figma code, markup copy or artwork; just the test ids and geometry the
    /// phone layout reads, plus a grid canvas sized like a renderer would on resize.
    static let editorHTML = """
      <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
      <title>Layout fixture – Figma</title>
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
      <style>
      html,body{margin:0;height:100%;overflow:hidden;background:#1e1e1e;font:11px system-ui;color:#e6e6e6}
      .panel{position:absolute;top:0;bottom:0;background:#2c2c2c;overflow:auto}
      .row{height:32px;display:flex;align-items:center;padding:0 12px;gap:8px}
      .row.sel{background:#4a5878}.head{font-weight:600;border-bottom:1px solid #444}
      .field{display:flex;gap:8px;padding:4px 12px}.field input{width:80px;background:#383838;border:0;border-radius:5px;color:#fff;font:11px system-ui;padding:7px}
      .swatch{width:14px;height:14px;border-radius:3px;background:#0d99ff}
      </style></head><body>
      <nav data-testid="navigation-bar" class="panel" style="left:0;width:49px;border-right:1px solid #444"><div data-testid="navigation-bar-top-section"></div></nav>
      <div class="left_panel_positioner--leftPanelPositioner--f" style="position:absolute;left:49px;top:0;bottom:0">
       <div class="left_panel_container--positionContainer--f panel" style="left:0;width:240px;border-right:1px solid #444">
        <div class="left_panel_container--sizeContainer--f" style="width:240px">
         <div class="row head">Layers <button aria-label="Minimize UI" style="margin-left:auto">–</button></div>
         <div class="row sel">▢ Frame 1</div><div class="row">&nbsp;&nbsp;◯ Ellipse</div><div class="row">&nbsp;&nbsp;T Title</div>
         <div class="row">▢ Frame 2</div><div class="row">▭ Rectangle</div>
        </div></div></div>
      <div class="fullscreen_view--page--f" style="position:absolute;inset:0">
       <div class="view container-view" style="position:absolute;top:0;bottom:0;left:0;right:241px">
        <div class="view container-view" style="position:absolute;top:0;bottom:0;left:290px;right:0">
         <div class="view" style="position:absolute;inset:0"><div class="gpu-view-content" style="position:absolute;inset:0"><canvas style="display:block"></canvas></div></div>
        </div></div></div>
      <div data-testid="properties-panel" class="properties_panel--drillDownContainer--f panel" style="right:0;width:240px;border-left:1px solid #444">
       <div class="row head">Design <span style="opacity:.6">Prototype</span></div>
       <div class="row">Position</div>
       <div class="field"><input value="120" aria-label="X"><input value="80" aria-label="Y"></div>
       <div class="row">Layout</div>
       <div class="field"><input value="320" aria-label="W"><input value="240" aria-label="H"></div>
       <div class="row">Fill</div><div class="row"><span class="swatch"></span> 0D99FF</div>
      </div>
      <div data-testid="positioned-design-toolbelt" style="position:fixed;left:0;right:0;bottom:8px;height:48px">
       <div class="toolbelt_left_side--visibleCarouselRow--f">
        <button data-testid="Move-tool" aria-pressed="true">V</button><button data-testid="Frame-tool" aria-pressed="false">F</button>
       </div></div>
      <script>
      // Renderer stand-in: the canvas fills its reserved box and draws a grid plus two frames
      // anchored at its top-left, redrawn on every window resize like a real renderer.
      const canvas = document.querySelector('canvas');
      const draw = () => {
        const box = canvas.parentElement.getBoundingClientRect(), dpr = devicePixelRatio;
        canvas.width = Math.max(1, box.width * dpr); canvas.height = Math.max(1, box.height * dpr);
        canvas.style.width = box.width + 'px'; canvas.style.height = box.height + 'px';
        const c = canvas.getContext('2d'); c.scale(dpr, dpr);
        c.fillStyle = '#1e1e1e'; c.fillRect(0, 0, box.width, box.height);
        c.strokeStyle = '#2a2a2a';
        for (let x = 0; x < box.width; x += 24) { c.beginPath(); c.moveTo(x + .5, 0); c.lineTo(x + .5, box.height); c.stroke(); }
        for (let y = 0; y < box.height; y += 24) { c.beginPath(); c.moveTo(0, y + .5); c.lineTo(box.width, y + .5); c.stroke(); }
        c.fillStyle = '#fff'; c.fillRect(48, 48, 240, 160); c.fillStyle = '#0d99ff'; c.fillRect(312, 72, 160, 120);
        c.strokeStyle = '#0d99ff'; c.lineWidth = 1; c.strokeRect(47.5, 47.5, 241, 161);
        c.fillStyle = '#9a9a9a'; c.fillText('Frame 1', 48, 42); c.fillText('Frame 2', 312, 66);
      };
      addEventListener('resize', draw); draw();
      </script></body></html>
      """

    static func html(number: Int) -> String {
      """
      <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
      <title>Local document \(number) – Figma</title>
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; navigate-to https://www.figma.com">
      <style>body { font: 20px system-ui; padding: 160px 20px 20px; }
      #fixture-tools { position:fixed; top:8px; left:8px; z-index:2; background:white; display:flex; flex-wrap:wrap; align-items:center; gap:4px; max-width:calc(100vw - 56px); }
      #fixture-tools input { width:120px; } #fixture-tools input,#fixture-tools button { font:16px system-ui; margin:0; min-height:44px; }
       input,button { font: inherit; margin: 12px; min-height: 44px; } nav { display:flex; flex-wrap:wrap; gap:16px; align-items:center; } nav a { display:inline-flex; align-items:center; min-height:44px; padding:8px; }</style>
      </head><body>
      <section id="fixture-tools">
      <button id="increment">Increment</button><label>Tab note <input aria-label="Tab note"></label>
      <button id="undo">Fixture undo</button><button id="redo">Fixture redo</button>
      </section><h1>Local tab \(number)</h1>
      <nav>
      <a id="b3-route-file" href="https://www.figma.com/design/fixture1">Open file 1</a>
      <a href="https://www.figma.com/design/fixture2" target="_blank">Open file 2 popup</a>
      <button onclick="window.history.pushState({}, '', '/design/fixture3')">Open file 3 SPA</button>
      <a href="https://www.figma.com/design/fixture3" id="spa-link">Open file 3 SPA link</a>
      <div id="b6-routes" hidden>
      <button onclick="setTimeout(() => window.open('https://www.figma.com/design/fixture8'), 350)">Duplicate after delay</button>
      <button onclick="location.assign('https://www.figma.com/design/fixture4')">Open ordinary location</button>
      <button onclick="location.replace('https://www.figma.com/design/fixture7')">Open location replace</button>
      <button onclick="window.open('https://www.figma.com/design/fixture5')">Open window file</button>
      <button onclick="const child=window.open('about:blank'); if(child) child.location='https://www.figma.com/design/fixture6'">Open blank child</button>
      </div>
      <a href="https://www.figma.com/files/project/fixture">Open project folder</a>
      <a href="https://www.figma.com/files">Return dashboard</a>
      </nav><button onclick="document.title='Renamed document \(number) – Figma'">Rename local title</button><p id="load"></p>
      <div id="canvas" tabindex="0" role="button" aria-label="History canvas">History canvas</div>
      <div contenteditable="true" role="textbox" aria-label="Editable note">Local editable note</div>
      <p id="count">Count 0</p>
      <p id="history"></p><p id="cursor"></p><p id="clicks"></p><p id="fixture-keys"></p>
      <canvas id="sink-focus" width="320" height="80" role="button" tabindex="0" aria-label="Keyboard canvas"></canvas>
      <input id="sink" aria-label="Keyboard sink" value="xy" style="position:absolute;opacity:0;width:1px;height:1px">
      <div id="editor" contenteditable="true" role="textbox" aria-label="Keyboard editor">xy</div>
      <p id="keys">Keys none</p><p id="changes">Sink xy; editor xy; deleted false</p>
      <script>
      document.getElementById('b6-routes').hidden = \(ProcessInfo.processInfo.arguments.contains("--b6-routes") ? "false" : "true");
      document.getElementById('load').textContent = 'Load token ' + Date.now() + '-' + Math.random();
      // First-party fixture history only. Never installed into a network page.
      const sink = document.getElementById('sink'), editor = document.getElementById('editor');
      const canvas = document.getElementById('sink-focus'), context = canvas.getContext('2d');
      context.font = '20px system-ui'; context.fillText('Keyboard canvas', 12, 24);
      context.strokeRect(12, 36, 80, 30);
      const keys = [], counts = {}; let deleted = false;
      const changes = () => document.getElementById('changes').textContent =
        'Sink ' + sink.value + '; editor ' + editor.textContent + '; deleted ' + deleted;
      document.getElementById('sink-focus').onclick = () => {
        sink.focus({preventScroll:true}); sink.setSelectionRange(sink.value.length, sink.value.length);
      };
      sink.oninput = editor.oninput = changes;
      if (\(ProcessInfo.processInfo.arguments.contains("--keyboard-cold") ? "true" : "false")) {
        sink.focus({preventScroll:true}); sink.setSelectionRange(2, 2);
      }
      document.addEventListener('keydown', event => {
        const label = (event.ctrlKey ? 'Ctrl+' : '') + (event.metaKey ? 'Cmd+' : '')
          + (event.shiftKey ? 'Shift+' : '') + (event.key.length === 1 ? event.key.toLowerCase() : event.key);
        counts[label] = (counts[label] || 0) + 1;
        if(event.target === sink && event.key === 'Backspace') {
          deleted = true; context.clearRect(0, 30, 110, 50);
        }
        queueMicrotask(() => {
          keys.push(label + ':' + counts[label] + ':prevented=' + event.defaultPrevented);
          document.getElementById('keys').textContent = 'Keys ' + keys.join(' | ');
          changes();
        });
      });
      let fixtureHistory = [0], cursor = 0;
      const clicks = { increment: 0, undo: 0, redo: 0 };
      const keyCalls = { undo: 0, redo: 0 };
      const render = () => {
        document.getElementById('fixture-keys').textContent = 'Fixture keys undo ' + keyCalls.undo + ' redo ' + keyCalls.redo;
        document.getElementById('count').textContent = 'Count ' + fixtureHistory[cursor];
        document.getElementById('history').textContent = 'History ' + fixtureHistory.join(',');
        document.getElementById('cursor').textContent = 'Cursor ' + cursor;
        document.getElementById('clicks').textContent = 'Fixture clicks increment ' + clicks.increment + ' undo ' + clicks.undo + ' redo ' + clicks.redo;
      };
      const undo = () => { if(cursor > 0) { cursor--; render(); } };
      const redo = () => { if(cursor < fixtureHistory.length - 1) { cursor++; render(); } };
      document.getElementById('increment').onclick = () => {
        clicks.increment++; fixtureHistory = fixtureHistory.slice(0, cursor + 1); fixtureHistory.push(fixtureHistory[cursor] + 1); cursor++; render();
      };
      document.getElementById('undo').onclick = () => { clicks.undo++; undo(); render(); };
      document.getElementById('redo').onclick = () => { clicks.redo++; redo(); render(); };
      sink.onkeydown = event => {
        if(event.metaKey && event.key.toLowerCase() === 'z') {
          event.preventDefault(); undo();
        }
      };
      document.getElementById('canvas').onkeydown = event => {
        if(!event.metaKey || event.altKey || event.ctrlKey || event.isComposing) return;
        if(event.key.toLowerCase() === 'z') { event.preventDefault(); keyCalls[event.shiftKey ? 'redo' : 'undo']++; event.shiftKey ? redo() : undo(); render(); }
        else if(event.key.toLowerCase() === 'y' && !event.shiftKey) { event.preventDefault(); keyCalls.redo++; redo(); render(); }
      };
      document.getElementById('spa-link').onclick = event => {
        event.preventDefault(); window.history.pushState({}, '', '/design/fixture3');
      };
      // No-interaction canvas model, separate from the editable WebKit undo route.
      let coldPresent = true, coldUndo = 0, coldRedo = 0;
      const coldState = document.createElement('p'); document.body.append(coldState);
      const renderCold = () => {
        coldState.textContent = 'Cold shape present ' + coldPresent + ' undo ' + coldUndo + ' redo ' + coldRedo;
      };
      const shortcuts = { v: 0, t: 0, all: 0 };
      const tools = document.createElement('p'); tools.id = 'tools'; document.body.append(tools);
      const renderTools = () => { tools.textContent = 'Fixture tools V ' + shortcuts.v + ' T ' + shortcuts.t + ' Ctrl+A ' + shortcuts.all; };
      window.addEventListener('keydown', event => {
        const target = event.target;
        if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target.isContentEditable) return;
        const key = event.key.toLowerCase();
        if (key === 'backspace' && !event.metaKey && !event.ctrlKey && !event.altKey) {
          event.preventDefault(); coldPresent = false; renderCold();
        }
        if (key === 'z' && event.metaKey && !event.ctrlKey && !event.altKey) {
          event.preventDefault();
          if (event.shiftKey) { coldPresent = false; coldRedo++; }
          else { coldPresent = true; coldUndo++; }
          renderCold();
        }
        if (!event.metaKey && !event.altKey && !event.shiftKey) {
          if (event.ctrlKey && key === 'a') { event.preventDefault(); shortcuts.all++; }
          else if (!event.ctrlKey && (key === 'v' || key === 't')) { shortcuts[key]++; }
          renderTools();
        }
      });
      // First-party hit evidence only. No network injection or document text capture.
      const hitSignature = document.createElement('p'); hitSignature.id = 'b3-hit-signature';
      document.body.append(hitSignature);
      const incrementGeometry = document.createElement('p'); document.body.append(incrementGeometry);
      const hit = () => {
        const link = document.getElementById('b3-route-file'), r = link.getBoundingClientRect();
        const x = r.left + r.width / 2, y = r.top + r.height / 2;
        const target = document.elementFromPoint(x,y);
        hitSignature.textContent = 'B3 hit ' + [r.x,r.y,r.width,r.height,innerWidth,innerHeight,scrollX,scrollY].map(n => Math.round(n*100)/100).join(',') + ' dom=' + (target === link || link.contains(target));
        const increment = document.getElementById('increment'), ir = increment.getBoundingClientRect();
        const it = document.elementFromPoint(ir.x+ir.width/2, ir.y+ir.height/2);
        incrementGeometry.textContent = 'B6 increment ' + [ir.x,ir.y,ir.width,ir.height,innerWidth,innerHeight,visualViewport?.height ?? 0,scrollX,scrollY].map(n=>Math.round(n*100)/100).join(',') + ' dom=' + (it===increment || increment.contains(it));
      };
      window.addEventListener('resize', hit); window.addEventListener('scroll', hit);
      visualViewport?.addEventListener('resize', hit); visualViewport?.addEventListener('scroll', hit);
      requestAnimationFrame(hit);
      const browserHistory = document.createElement('p'); browserHistory.id = 'browser-history';
      document.body.append(browserHistory);
      const renderBrowserHistory = () => {
        browserHistory.textContent = 'Browser history ' + window.history.length;
      };
      window.addEventListener('popstate', renderBrowserHistory);
      document.addEventListener('click', () => queueMicrotask(renderBrowserHistory));
      renderCold(); renderBrowserHistory(); renderTools(); render();
      </script></body></html>
      """
    }
  }
#endif
