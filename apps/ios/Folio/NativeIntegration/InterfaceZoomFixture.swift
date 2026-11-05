import WebKit

#if DEBUG
  /// First-party offline fixture only. No shared launch fixture or production page is changed.
  @MainActor
  enum InterfaceZoomFixture {
    static func makeContainer(store: InterfaceZoomStore) -> InterfaceZoomContainerController {
      let container = InterfaceZoomContainerController(store: store) { _ in
        BrowserWindowController(
          useFixture: true,
          makeWebView: { configuration in
            let view = InterfaceZoomFixtureWebView(frame: .zero, configuration: configuration)
            store.registerMainWebView(view)
            return view
          })
      }
      container.loadViewIfNeeded()
      for number in 1...3 {
        container.browser.addTab(url: URL(string: "https://www.figma.com/design/zoom\(number)")!)
      }
      if ProcessInfo.processInfo.arguments.contains("--interface-zoom-safe") {
        let browser = container.browser
        for tab in browser.session.tabs {
          browser.session.select(tab.id)
          browser.showSelectedTab()
          tab.session.mode = .safe
          (browser.children.first as? FigmaWebViewController)?.rebuildWebView()
        }
      }
      return container
    }

    /// Separate from the strict post-edit fixture. Root covers the CSS viewport;
    /// native tests compare it with the WebView, including every edge and corner.
    static let geometryHTML = """
      <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
      <style>
      html,body { margin:0; width:100%; height:100%; overflow:hidden; }
      #viewport { position:absolute; inset:0; display:grid;
        grid-template-columns:repeat(3,minmax(0,1fr)); grid-template-rows:repeat(3,minmax(0,1fr)); }
      button { min-width:0; min-height:0; width:100%; height:100%; }
      #middle { min-width:0; min-height:0; display:flex; flex-direction:column; }
      #middle button { flex:1; height:auto; } input { box-sizing:border-box; width:100%; }
      output { font:8px system-ui; overflow-wrap:anywhere; flex-shrink:0; }
      </style></head><body><main id="viewport">
      <button id="nw">B6 northwest 0</button><button id="n">B6 north 0</button><button id="ne">B6 northeast 0</button>
      <button id="w">B6 west 0</button><div id="middle"><button id="c">B6 center 0</button>
      <input id="edit" aria-label="B6 note"><output id="metrics"></output><output id="identity"></output></div><button id="e">B6 east 0</button>
      <button id="sw">B6 southwest 0</button><button id="s">B6 south 0</button><button id="se">B6 southeast 0</button>
      </main><script>
      const token=Date.now()+'-'+Math.random();
      identity.textContent='B6 token '+token;
      const counts={};
      for(const button of document.querySelectorAll('button')) {
        counts[button.id]=0;const label=button.textContent.replace(/ 0$/,'');
        button.onclick=()=>{counts[button.id]++;button.textContent=label+' '+counts[button.id]};
      }
      window.folioB6Geometry=()=>{
        const v=visualViewport,r=document.getElementById('viewport').getBoundingClientRect();
        return {innerWidth,innerHeight,viewportWidth:v?.width??innerWidth,
          viewportHeight:v?.height??innerHeight,left:v?.offsetLeft??0,top:v?.offsetTop??0,
          viewportScale:v?.scale??1,scrollX,scrollY,x:r.x,y:r.y,width:r.width,height:r.height,
          documentWidth:document.documentElement.clientWidth,documentHeight:document.documentElement.clientHeight};
      };
      const report=()=>{
        const g=folioB6Geometry();
        metrics.textContent='B6 metrics '+[g.innerWidth,g.innerHeight,g.viewportWidth,g.viewportHeight,g.left,g.top,g.width,g.height].map(n=>n.toFixed(2)).join(' ');
      };
      addEventListener('resize',report);visualViewport?.addEventListener('resize',report);
      visualViewport?.addEventListener('scroll',report);report();
      </script></body></html>
      """

    static let html = """
      <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
      <style>
      body { margin: 8px; font: 14px system-ui; }
      p { margin:4px 0; }
      button,input { min-height: 44px; font: inherit; }
      input { width:120px; }
      canvas { display:inline-block; vertical-align:middle; width:120px; height:44px; }
      #scroll { height:240px; max-width:480px; overflow:auto; border:1px solid; }
      #space > p { margin:0; min-height:40px; } #bottom { padding:8px; }
      </style></head><body>
      <p id="token"></p><button id="hit">Zoom target</button>
      <canvas id="canvas" width="120" height="44" role="button" aria-label="Zoom canvas" tabindex="0"></canvas>
      <p id="state">Hits 0; canvas 0</p>
      <label>Zoom note <input id="note" aria-label="Zoom note"></label>
      <button id="blur">End editing</button>
      <div id="scroll" role="region" aria-label="Zoom scroll" tabindex="0"><div id="space"></div><button id="bottom">Scroll end</button></div>
      <p id="focus">Focus none</p><p id="scrolled">Scroll 0</p>
      <p id="geometry"></p><p id="touches"></p>
      <script>
      token.textContent='Zoom token '+Date.now()+'-'+Math.random();
      let hits=0, canvases=0;
      const draw=()=>state.textContent='Hits '+hits+'; canvas '+canvases;
      hit.onclick=()=>{hits++;draw()}; canvas.onclick=()=>{canvases++;draw()};
      const context=canvas.getContext('2d');context.strokeRect(2,2,116,40);
      context.font='14px system-ui';context.fillText('Zoom canvas',8,26);
      note.onfocus=()=>document.getElementById('focus').textContent='Focus note';
      note.onblur=()=>document.getElementById('focus').textContent='Focus none';
      const panel=document.getElementById('scroll');
      // Keep this offline scroll target focusable, with content at every offset.
      // Native post-edit accessibility hit testing is verified by the UI cases.
      for(let row=0;row<30;row++) {
        const line=document.createElement('p');line.textContent='Scroll row '+row;
        document.getElementById('space').append(line);
      }
      const touch={starts:0,moves:0,ends:0,cancels:0,trusted:0,startX:0,startY:0,lastX:0,lastY:0};
      // Offline fixture metadata only. Observe native delivery without preventing defaults.
      window.folioZoomGeometry=()=>{
        const v=visualViewport,r=panel.getBoundingClientRect();
        return {innerWidth,innerHeight,viewportWidth:v?.width??innerWidth,
          viewportHeight:v?.height??innerHeight,left:v?.offsetLeft??0,top:v?.offsetTop??0,
          scrollX,scrollY,x:r.x,y:r.y,width:r.width,height:r.height,
          clientHeight:panel.clientHeight,scrollHeight:panel.scrollHeight,scrollTop:panel.scrollTop,
          viewportScale:v?.scale??1,activeNote:document.activeElement===note?1:0,
          centerInPanel:panel.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2))?1:0,
          ...touch};
      };
      const report=()=>{
        const g=folioZoomGeometry();
        geometry.textContent='Scroll geometry '+Math.round(g.height)+' / '+g.clientHeight+' / '+g.scrollHeight;
        touches.textContent='Scroll touches '+touch.starts+' / '+touch.moves+' / '+touch.ends+' / '+touch.cancels+'; trusted '+touch.trusted+'; y '+Math.round(touch.startY)+' / '+Math.round(touch.lastY);
      };
      for(const [type,key] of [['touchstart','starts'],['touchmove','moves'],['touchend','ends'],['touchcancel','cancels']]) {
        panel.addEventListener(type,event=>{
          touch[key]++;if(event.isTrusted)touch.trusted++;
          const t=event.changedTouches[0];
          if(t){touch.lastX=t.clientX;touch.lastY=t.clientY;
            if(type==='touchstart'){touch.startX=t.clientX;touch.startY=t.clientY;}}
          report();
        },{passive:true});
      }
      document.getElementById('blur').onclick=()=>note.blur();
      panel.onscroll=()=>{scrolled.textContent='Scroll '+Math.round(panel.scrollTop);report()};
      addEventListener('resize',report);visualViewport?.addEventListener('resize',report);report();
      </script></body></html>
      """
  }

  @MainActor
  final class InterfaceZoomFixtureWebView: WKWebView {
    override func load(_ request: URLRequest) -> WKNavigation? { nil }

    override func loadSimulatedRequest(
      _ request: URLRequest, responseHTML string: String
    ) -> WKNavigation {
      // Match the tab host's visible-history loader, keeping the zoom page offline.
      super.loadSimulatedRequest(
        request,
        responseHTML: ProcessInfo.processInfo.arguments.contains("--b6-zoom-geometry")
          ? InterfaceZoomFixture.geometryHTML : InterfaceZoomFixture.html)
    }
  }
#endif
