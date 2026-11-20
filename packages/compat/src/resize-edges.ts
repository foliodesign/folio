// Panel resize helper. Finds Figma's resize handles by reading computed cursors (and resize class
// names) of the page's DOM, widens their grab zone and delivers the drag as standard mouse input
// at the handle's own coordinate, so Figma's code does the resizing. Standard DOM input only;
// nothing in the page is called or changed except one pointer-events:none indicator element.
// Loaded before touch-gestures, pencil and canvas-wheel so a grab hides its events from them.
const runtime = globalThis.__folio;
if (runtime && !runtime.setResizeEdges) {
  type Axis = "x" | "y";
  type Edge = { element: Element; axis: Axis };
  type Grab = {
    edge: Edge;
    pointerId: number;
    last: { x: number; y: number };
    offsetX: number;
    offsetY: number;
  };
  const ZONE = 10;
  const CONTROL =
    'a, button, input, select, textarea, label, [draggable="true"], ' +
    '[role="treeitem"], [role="row"], [role="gridcell"], [role="option"], [role="listitem"], ' +
    '[role="button"], [role="menuitem"], [role="tab"], [role="link"], [role="checkbox"], ' +
    '[role="slider"], [role="textbox"]';
  // Figma's menus, popovers, dialogs and tooltips. The line never shows over or under them.
  const OVERLAY =
    '[role="menu"], [role="menuitem"], [role="menubar"], [role="dialog"], [role="alertdialog"], ' +
    '[role="listbox"], [role="tooltip"], [data-radix-popper-content-wrapper], ' +
    '[data-testid*="popover" i], [data-testid*="dropdown" i]';
  const RESIZE_CURSOR =
    /(?:^|[\s,])(col-resize|ew-resize|e-resize|w-resize|row-resize|ns-resize|n-resize|s-resize)\s*$/;
  let enabled = true;
  let edges: Edge[] = [];
  let grab: Grab | undefined;
  let suppressClickUntil = 0;
  let suppressClickId: number | undefined;
  let scanTimer: ReturnType<typeof setTimeout> | undefined;
  let lastScan = 0;
  let hideTimer: ReturnType<typeof setTimeout> | undefined;
  let frame: number | undefined;
  let shown: Edge | undefined;
  let visible = false;
  let pointerAt: { x: number; y: number } | undefined;

  const line = document.createElement("div");
  line.setAttribute("aria-hidden", "true");
  line.style.cssText =
    "position:fixed;left:0;top:0;width:0;height:0;margin:0;padding:0;border:0;" +
    "border-radius:1px;pointer-events:none;z-index:2147483647;" +
    "opacity:0;transition:opacity 150ms ease-out;";

  const axisOf = (element: Element): Axis | undefined => {
    const match = RESIZE_CURSOR.exec(getComputedStyle(element).cursor);
    if (match) return /^(col|ew|e|w)-/.test(match[1] ?? "") ? "x" : "y";
    const name = element.getAttribute("class") ?? "";
    if (!/resiz/i.test(name)) return undefined;
    const rect = element.getBoundingClientRect();
    return rect.width <= rect.height ? "x" : "y";
  };
  // A panel edge is thin and long. This rules out scrub labels and icon buttons with ew-resize.
  const usable = (edge: Edge, rect: DOMRect) => {
    const across = edge.axis === "x" ? rect.width : rect.height;
    const along = edge.axis === "x" ? rect.height : rect.width;
    return across > 0 && across <= 20 && along >= 60 && along >= across * 3;
  };

  const scan = (duringGrab = false) => {
    scanTimer = undefined;
    if (!enabled || (grab && !duringGrab)) return;
    lastScan = performance.now();
    const found: Edge[] = [];
    const all = document.body?.getElementsByTagName("*") ?? [];
    for (const element of all) {
      if (
        element === line ||
        element.childElementCount > 2 ||
        element instanceof HTMLCanvasElement ||
        element instanceof SVGElement
      )
        continue;
      const axis = axisOf(element);
      if (!axis) continue;
      const edge = { element, axis };
      if (usable(edge, element.getBoundingClientRect())) found.push(edge);
    }
    edges = found;
  };
  // Mutations and resizes refresh the cache at most every 1.5 s; never during a drag.
  const schedule = () => {
    if (!enabled || scanTimer !== undefined || grab) return;
    const wait = Math.max(400, 1500 - (performance.now() - lastScan));
    scanTimer = setTimeout(scan, wait);
  };
  const observer = new MutationObserver((records) => {
    if (records.some((record) => record.target !== line)) schedule();
  });

  const hit = (x: number, y: number) => {
    let best: { edge: Edge; distance: number } | undefined;
    for (const edge of edges) {
      if (!edge.element.isConnected) continue;
      const rect = edge.element.getBoundingClientRect();
      if (!usable(edge, rect)) continue;
      const [along, start, end, across, center] =
        edge.axis === "x"
          ? [y, rect.top, rect.bottom, x, rect.left + rect.width / 2]
          : [x, rect.left, rect.right, y, rect.top + rect.height / 2];
      const distance = Math.abs(across - center);
      if (along < start || along > end || distance > ZONE) continue;
      if (!best || distance < best.distance) best = { edge, distance };
    }
    return best?.edge;
  };

  // Figma re-renders the handle while it resizes; if the grabbed element is gone, take the cached
  // edge of the same axis nearest to the finger.
  const live = (): Edge | undefined => {
    if (grab) {
      // The grabbed handle is what moves. If Figma replaced it, rescan (the cache is frozen during
      // a grab) and continue with the nearest handle of the same axis, also as the event target.
      if (!grab.edge.element.isConnected) {
        if (performance.now() - lastScan > 100) scan(true);
        shown = grab.edge;
      } else {
        shown = grab.edge;
        return shown;
      }
    }
    if (shown?.element.isConnected) return shown;
    if (!shown || !grab) return undefined;
    const { x, y } = grab.last;
    let best: { edge: Edge; distance: number } | undefined;
    for (const edge of edges) {
      if (edge.axis !== shown.axis || !edge.element.isConnected) continue;
      const rect = edge.element.getBoundingClientRect();
      const distance =
        edge.axis === "x"
          ? Math.abs(x - (rect.left + rect.width / 2))
          : Math.abs(y - (rect.top + rect.height / 2));
      if (!best || distance < best.distance) best = { edge, distance };
    }
    if (best) {
      shown = best.edge;
      grab.edge = best.edge;
    }
    return best?.edge;
  };
  // Fallback for a handle the scan missed (cursor set later, extra children, re-rendered): probe the
  // elements under the press and ZONE px to either side of it, on the same terms as the scan.
  const probe = (x: number, y: number) => {
    for (const [dx, dy] of [
      [0, 0],
      [-ZONE, 0],
      [ZONE, 0],
      [0, -ZONE],
      [0, ZONE],
    ] as const)
      for (const element of document.elementsFromPoint(x + dx, y + dy)) {
        if (element === line || element instanceof HTMLCanvasElement) continue;
        const axis = axisOf(element);
        if (!axis) continue;
        const edge = { element, axis };
        if (!usable(edge, element.getBoundingClientRect())) continue;
        if (!edges.some((cached) => cached.element === element))
          edges.push(edge);
        return hit(x, y);
      }
    return undefined;
  };
  // Only a menu, popover, dialog or tooltip on top of the pointer or the handle blocks the helper.
  // Figma's panels, handle wrappers and canvas containers are not checked by structure: an
  // ancestor heuristic rejected the right panel's handle and the canvas side of the zone.
  const topmostOk = (x: number, y: number) => {
    const top = document.elementsFromPoint(x, y).find((el) => el !== line);
    return !top?.closest(OVERLAY);
  };
  // The point on the handle's centre line nearest to (x, y).
  const handleAt = (x: number, y: number, edge: Edge) => {
    const rect = edge.element.getBoundingClientRect();
    return edge.axis === "x"
      ? {
          x: rect.left + rect.width / 2,
          y: Math.min(Math.max(y, rect.top), rect.bottom),
        }
      : {
          x: Math.min(Math.max(x, rect.left), rect.right),
          y: rect.top + rect.height / 2,
        };
  };
  const clear = (x: number, y: number, edge: Edge) => {
    const at = handleAt(x, y, edge);
    return topmostOk(x, y) && topmostOk(at.x, at.y);
  };
  // Maintainer (2026-11-20): something drawn across the handle owns presses on it, so a tap on
  // Figma's floating toolbar where it crosses a panel edge selects the tool instead of resizing.
  // Covered means the handle is not on top at its own centre line, and the pressed element shares
  // an ancestor with what is on top there before reaching an ancestor of the handle.
  const covered = (target: Element, x: number, y: number, edge: Edge) => {
    const at = handleAt(x, y, edge);
    const top = document
      .elementsFromPoint(at.x, at.y)
      .find((el) => el !== line);
    if (!top || edge.element.contains(top) || top.contains(edge.element))
      return false;
    for (let el: Element | null = target; el; el = el.parentElement) {
      if (el.contains(edge.element)) return false;
      if (el.contains(top)) return true;
    }
    return false;
  };

  // Maintainer (2026-11-20): the line sits on top of the page, so it must not cross what Figma
  // draws over the edge (its floating toolbar on a narrow screen). Elements on top along the
  // handle's centre line are sampled every 16 px, at most every 250 ms, and the line is cut out
  // where their live rects cross it.
  const LINE = "#0D99FF";
  let covers: { edge: Edge; elements: Element[]; at: number } | undefined;
  const coversOf = (edge: Edge, rect: DOMRect, center: number) => {
    if (covers?.edge === edge && performance.now() - covers.at < 250)
      return covers.elements;
    const vertical = edge.axis === "x";
    const [start, end] = vertical
      ? [rect.top, rect.bottom]
      : [rect.left, rect.right];
    const found = new Set<Element>();
    for (let along = start; along <= end; along += 16) {
      const [x, y] = vertical ? [center, along] : [along, center];
      const top = document.elementsFromPoint(x, y).find((el) => el !== line);
      if (top && !edge.element.contains(top) && !top.contains(edge.element))
        found.add(top);
    }
    covers = { edge, elements: [...found], at: performance.now() };
    return covers.elements;
  };
  const paint = (edge: Edge, rect: DOMRect, center: number) => {
    const vertical = edge.axis === "x";
    const start = vertical ? rect.top : rect.left;
    const length = vertical ? rect.height : rect.width;
    const gaps: [number, number][] = [];
    for (const element of coversOf(edge, rect, center)) {
      if (!element.isConnected) continue;
      const box = element.getBoundingClientRect();
      const [low, high, from, to] = vertical
        ? [box.left, box.right, box.top, box.bottom]
        : [box.top, box.bottom, box.left, box.right];
      if (center < low || center > high) continue;
      const a = Math.max(0, from - start);
      const b = Math.min(length, to - start);
      if (b > a) gaps.push([a, b]);
    }
    if (!gaps.length) {
      line.style.background = LINE;
      return;
    }
    gaps.sort((p, q) => p[0] - q[0]);
    const stops: string[] = [];
    let at = 0;
    for (const [a, b] of gaps) {
      if (b <= at) continue;
      if (a > at) stops.push(`${LINE} ${at}px`, `${LINE} ${a}px`);
      stops.push(`transparent ${Math.max(a, at)}px`, `transparent ${b}px`);
      at = Math.max(at, b);
    }
    stops.push(`${LINE} ${at}px`, `${LINE} ${length}px`);
    line.style.background = `linear-gradient(${vertical ? "to bottom" : "to right"}, ${stops.join(", ")})`;
  };

  // Keeps measuring every frame while grabbed and during the fade-out, because Figma moves the
  // handle after the drag event, so a single measurement lags behind the live edge.
  const place = () => {
    frame = undefined;
    if (grab || hideTimer !== undefined || visible)
      frame = requestAnimationFrame(place);
    const edge = live();
    if (!edge) return;
    // A menu or popover opened over the line: hide at once. A grab is the handle's own drag.
    if (!grab && pointerAt && !clear(pointerAt.x, pointerAt.y, edge)) {
      hideNow();
      return;
    }
    const rect = edge.element.getBoundingClientRect();
    const vertical = edge.axis === "x";
    const center = vertical
      ? rect.left + rect.width / 2
      : rect.top + rect.height / 2;
    line.style.left = `${vertical ? center - 1 : rect.left}px`;
    line.style.top = `${vertical ? rect.top : center - 1}px`;
    line.style.width = `${vertical ? 2 : rect.width}px`;
    line.style.height = `${vertical ? rect.height : 2}px`;
    paint(edge, rect, center);
  };
  const show = (edge: Edge) => {
    clearTimeout(hideTimer);
    hideTimer = undefined;
    shown = edge;
    visible = true;
    if (!line.isConnected) document.documentElement.append(line);
    if (frame === undefined) frame = requestAnimationFrame(place);
    line.style.opacity = "1";
  };
  const hideNow = () => {
    clearTimeout(hideTimer);
    hideTimer = undefined;
    visible = false;
    shown = undefined;
    line.style.opacity = "0";
  };
  const hide = (delay: number) => {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      hideNow();
    }, delay);
  };

  const editable = (target: EventTarget | null) =>
    target instanceof Element &&
    target.closest(
      'input, textarea, select, [contenteditable]:not([contenteditable="false"])',
    ) !== null;
  const suppress = (event: Event) => {
    event.stopImmediatePropagation();
    if (event.cancelable) event.preventDefault();
  };
  const handlePoint = (sequence: Grab, x: number, y: number) => {
    // Both the press/drag and the handle rect use DOM client CSS pixels. Keep the initial
    // offset fixed; rereading the moving edge here would add its movement a second time.
    return { x: x + sequence.offsetX, y: y + sequence.offsetY };
  };

  const send = (
    target: EventTarget,
    phase: "down" | "move" | "up",
    x: number,
    y: number,
    pointerId: number,
  ) => {
    const init: PointerEventInit = {
      bubbles: true,
      cancelable: true,
      composed: true,
      view: window,
      clientX: x,
      clientY: y,
      screenX: x,
      screenY: y,
      pointerType: "mouse",
      pointerId,
      isPrimary: true,
      button: phase === "move" ? -1 : 0,
      buttons: phase === "up" ? 0 : 1,
      detail: phase === "move" ? 0 : 1,
    };
    target.dispatchEvent(new PointerEvent(`pointer${phase}`, init));
    target.dispatchEvent(
      new MouseEvent(`mouse${phase}`, { ...init, button: 0 }),
    );
  };
  // The drag starts at the handle's exact coordinate; the finger's offset from it is kept.
  const move = (x: number, y: number) => {
    const sequence = grab;
    if (!sequence) return;
    sequence.last = { x, y };
    const point = handlePoint(sequence, x, y);
    send(sequence.edge.element, "move", point.x, point.y, sequence.pointerId);
    show(sequence.edge);
  };
  const finish = () => {
    const sequence = grab;
    if (!sequence) return;
    grab = undefined;
    suppressClickUntil = performance.now() + 600;
    suppressClickId = sequence.pointerId;
    hide(400);
    const point = handlePoint(sequence, sequence.last.x, sequence.last.y);
    send(sequence.edge.element, "up", point.x, point.y, sequence.pointerId);
    schedule();
  };

  const pointer = (event: Event) => {
    if (!enabled || !(event instanceof PointerEvent) || !event.isTrusted)
      return;
    if (event.pointerType === "mouse")
      pointerAt = { x: event.clientX, y: event.clientY };
    // Mouse and trackpad: hover shows the line; a press inside the zone but off the real handle
    // starts a grab exactly like touch. Everything else is left alone.
    if (event.pointerType === "mouse" && !grab) {
      if (event.type === "pointermove" && event.buttons === 0) {
        const edge = hit(event.clientX, event.clientY);
        if (
          edge &&
          clear(event.clientX, event.clientY, edge) &&
          !(
            event.target instanceof Element &&
            covered(event.target, event.clientX, event.clientY, edge)
          )
        )
          show(edge);
        else if (shown && hideTimer === undefined) hideNow();
      }
      if (event.type !== "pointerdown") return;
    } else if (event.pointerType !== "touch" && event.pointerType !== "pen")
      return;
    if (event.type === "click") {
      if (
        event.pointerId === suppressClickId &&
        performance.now() < suppressClickUntil
      )
        suppress(event);
      return;
    }
    if (grab) {
      if (event.pointerId !== grab.pointerId) {
        // A second contact ends the resize; that contact goes on to the page's normal handling.
        if (event.type === "pointerdown") finish();
        return;
      }
      suppress(event);
      if (event.type === "pointermove") {
        move(event.clientX, event.clientY);
      } else if (event.type === "pointerup") {
        move(event.clientX, event.clientY);
        finish();
      } else if (event.type === "pointercancel") finish();
      return;
    }
    if (
      event.type !== "pointerdown" ||
      !event.isPrimary ||
      event.button !== 0 ||
      editable(event.target) ||
      !(event.target instanceof Element)
    )
      return;
    let edge = hit(event.clientX, event.clientY);
    // A handle Figma re-rendered since the last scan is missing from the cache and the press would
    // fall through to the page (seen on the right panel after the left one was resized): rescan once.
    if (
      !edge &&
      performance.now() - lastScan > 400 &&
      edges.some((cached) => !cached.element.isConnected)
    ) {
      scan();
      edge = hit(event.clientX, event.clientY);
    }
    edge ??= probe(event.clientX, event.clientY);
    // Something else (menu, popover, dialog) is on top: the press goes to it untouched.
    if (
      !edge ||
      !clear(event.clientX, event.clientY, edge) ||
      covered(event.target, event.clientX, event.clientY, edge)
    )
      return;
    // Mouse and trackpad: a press on the real handle, or on a row or control beside it (a layer
    // row being dragged, a button), goes to Figma untouched. Only presses on bare panel surface
    // are retargeted.
    if (
      event.pointerType === "mouse" &&
      (edge.element.contains(event.target) || event.target.closest(CONTROL))
    )
      return;
    const rect = edge.element.getBoundingClientRect();
    const offsetX =
      edge.axis === "x" ? rect.left + rect.width / 2 - event.clientX : 0;
    const offsetY =
      edge.axis === "y" ? rect.top + rect.height / 2 - event.clientY : 0;
    grab = {
      edge,
      pointerId: event.pointerId,
      last: { x: event.clientX, y: event.clientY },
      offsetX,
      offsetY,
    };
    suppress(event);
    show(edge);
    const start = handlePoint(grab, event.clientX, event.clientY);
    send(edge.element, "down", start.x, start.y, event.pointerId);
    if (event.pointerType !== "mouse") {
      try {
        globalThis.webkit?.messageHandlers?.folioResize?.postMessage("grab");
      } catch {
        /* Detached frame. */
      }
    }
  };
  // Cancelling the touch sequence keeps WebKit from scrolling, selecting or opening menus.
  const touch = (event: Event) => {
    if (!enabled || !event.isTrusted || !(event instanceof TouchEvent)) return;
    const sequence = grab;
    if (!sequence) return;
    if (event.touches.length > 1) {
      finish();
      return;
    }
    suppress(event);
    // Pointer events carry movement for both finger and Pencil in the same client space.
    // Touch events only prevent WebKit's scrolling/selection default.
    if (event.type === "touchcancel") finish();
  };

  // Compat mouse events still follow a cancelled pointer event; keep them from the page mid-grab.
  const mouseDuringGrab = (event: Event) => {
    if (grab && event.isTrusted) suppress(event);
  };
  const groups: [string[], EventListener][] = [
    [
      ["pointerdown", "pointermove", "pointerup", "pointercancel", "click"],
      pointer,
    ],
    [["touchstart", "touchmove", "touchend", "touchcancel"], touch],
    [["mousedown", "mousemove", "mouseup"], mouseDuringGrab],
  ];
  for (const [names, listener] of groups)
    for (const name of names)
      window.addEventListener(name, listener, {
        capture: true,
        passive: false,
      });
  const reset = () => finish();
  window.addEventListener("blur", reset);
  window.addEventListener("pagehide", reset);
  window.addEventListener("resize", schedule);
  const observe = () => {
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["class", "style"],
    });
    schedule();
  };
  if (document.readyState === "loading")
    document.addEventListener("DOMContentLoaded", observe, { once: true });
  else observe();

  runtime.setResizeEdges = (next) => {
    if (enabled === next) return;
    enabled = next;
    if (!next) {
      finish();
      edges = [];
      line.remove();
      visible = false;
    }
    if (next) schedule();
  };
  runtime.disposeResizeEdges = () => {
    runtime.setResizeEdges?.(false);
    observer.disconnect();
    clearTimeout(scanTimer);
    clearTimeout(hideTimer);
    if (frame !== undefined) cancelAnimationFrame(frame);
    document.removeEventListener("DOMContentLoaded", observe);
    for (const [names, listener] of groups)
      for (const name of names)
        window.removeEventListener(name, listener, true);
    window.removeEventListener("blur", reset);
    window.removeEventListener("pagehide", reset);
    window.removeEventListener("resize", schedule);
    delete runtime.setResizeEdges;
    delete runtime.disposeResizeEdges;
  };
}
export {};
