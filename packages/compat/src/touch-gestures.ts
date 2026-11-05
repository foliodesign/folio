import { canvasAtPoint } from "./canvas-target";
// Standard DOM input only. No page functions, selectors or file data are inspected.
const runtime = globalThis.__folio;
if (runtime && !runtime.setTouchGestures) {
  let enabled = true;
  let home = false;
  let dragLogging = false;
  // The latest trusted press came from a mouse or trackpad; its mouse events are never touched.
  let mousePress = false;
  let dragNumber = 0;
  // Only fixed UI labels survive. Arbitrary aria-labels can contain file/layer names.
  const labels = new Set([
    "Layers",
    "Pages",
    "Assets",
    "Move",
    "Close",
    "More",
    "Search",
  ]);
  const describe = (target: EventTarget | null): string => {
    if (!(target instanceof Element)) return "OTHER";
    const tag =
      /^(DIV|SPAN|BUTTON|INPUT|UL|LI|SVG|PATH|CANVAS|BODY|HTML|A)$/.test(
        target.tagName.toUpperCase(),
      )
        ? target.tagName.toUpperCase()
        : "OTHER";
    const role = target.getAttribute("role") ?? "";
    const safeRole =
      /^(button|tree|treeitem|list|listitem|option|menuitem|row|grid|tab|tabpanel)$/.test(
        role,
      )
        ? role
        : role
          ? "redacted"
          : "none";
    const label = target.getAttribute("aria-label") ?? "";
    return `${tag}/role=${safeRole}/aria=${label ? (labels.has(label) ? label.slice(0, 32) : "redacted") : "none"}`;
  };
  const recordDrag = (
    kind: string,
    type: string,
    target: EventTarget | null,
    event?: MouseEvent,
    detail = "none",
  ) => {
    if (!dragLogging) return;
    const pointer = event instanceof PointerEvent ? event : undefined;
    runtime.post("folioUIDrag", {
      kind,
      type,
      target: describe(target),
      detail,
      drag: dragNumber,
      x: event?.clientX ?? 0,
      y: event?.clientY ?? 0,
      buttons: event?.buttons ?? 0,
      pointerId: pointer?.pointerId ?? 0,
      pointerType: pointer?.pointerType ?? "none",
      isPrimary: pointer?.isPrimary ?? false,
      defaultPrevented: event?.defaultPrevented ?? false,
      trusted: event?.isTrusted ?? false,
      time: performance.now(),
    });
  };
  const dispatchUI = (target: EventTarget, event: MouseEvent) => {
    target.dispatchEvent(event);
    if (observing()) recordDrag("synthetic", event.type, target, event);
  };
  const observing = () => dragLogging;
  const observeDrag: EventListener = (event) => {
    if (!observing()) return;
    recordDrag(
      "observed",
      event.type,
      event.target,
      event instanceof MouseEvent ? event : undefined,
    );
  };
  const observeError: EventListener = (event) => {
    if (!observing()) return;
    // Never send message, stack, source URL or rejection text across the bridge.
    const error: unknown =
      event instanceof ErrorEvent
        ? event.error
        : event instanceof PromiseRejectionEvent
          ? event.reason
          : undefined;
    const name =
      error instanceof Error || error instanceof DOMException
        ? error.name
        : "unknown";
    const safeName = [
      "NotFoundError",
      "InvalidStateError",
      "TypeError",
      "Error",
      "SecurityError",
    ].includes(name)
      ? name
      : "unknown";
    const message =
      event instanceof ErrorEvent
        ? event.message
        : error instanceof Error || error instanceof DOMException
          ? error.message
          : "";
    recordDrag(
      "error",
      event.type,
      null,
      undefined,
      /(?:setPointerCapture|hasPointerCapture|pointer.?capture)/i.test(message)
        ? `capture-${safeName}`
        : safeName,
    );
  };
  const observedEvents = [
    "gotpointercapture",
    "lostpointercapture",
    "dragstart",
    "dragover",
    "drop",
    "dragend",
  ];
  for (const name of observedEvents)
    window.addEventListener(name, observeDrag, true);
  for (const name of ["error", "unhandledrejection"])
    window.addEventListener(name, observeError, true);
  const contacts = new Set<number>();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let pending:
    | { down: PointerEvent; target: Element; held: boolean }
    | undefined;
  let tap: { target: Element; x: number; y: number; until: number } | undefined;
  let consumed: { target: Element; until: number } | undefined;
  const style = document.createElement("style");
  style.textContent = "canvas { -webkit-touch-callout: none !important; }";
  const editable = (target: Element) =>
    target.closest(
      'input, textarea, select, [contenteditable]:not([contenteditable="false"])',
    ) !== null;
  const suppress = (event: Event) => {
    event.stopImmediatePropagation();
    if (event.cancelable) event.preventDefault();
  };
  const reset = () => {
    cancelUIHold();
    clearTimeout(timer);
    pending = undefined;
    tap = undefined;
    consumed = undefined;
    contacts.clear();
  };
  const mouseSequence = (
    target: Element,
    event: MouseEvent,
    button: number,
    detail: number,
  ) => {
    const init: PointerEventInit = {
      bubbles: true,
      cancelable: true,
      composed: true,
      view: window,
      clientX: event.clientX,
      clientY: event.clientY,
      screenX: event.screenX,
      screenY: event.screenY,
      altKey: event.altKey,
      ctrlKey: event.ctrlKey,
      metaKey: event.metaKey,
      shiftKey: event.shiftKey,
      pointerType: "mouse",
      pointerId: 1,
      isPrimary: true,
      button,
      detail,
    };
    dispatchUI(
      target,
      new PointerEvent("pointerdown", {
        ...init,
        buttons: button === 2 ? 2 : 1,
      }),
    );
    dispatchUI(
      target,
      new MouseEvent("mousedown", { ...init, buttons: button === 2 ? 2 : 1 }),
    );
    dispatchUI(target, new PointerEvent("pointerup", { ...init, buttons: 0 }));
    dispatchUI(target, new MouseEvent("mouseup", { ...init, buttons: 0 }));
    dispatchUI(
      target,
      new MouseEvent(button === 2 ? "contextmenu" : "click", {
        ...init,
        buttons: 0,
      }),
    );
  };
  // UI contacts stay native. A native long-press recognizer outside the web view (WebKit's own
  // long-press handling can cancel the page's touch) calls touchUIHold: "began" after 0.5 s still
  // opens the menu while the finger/Pencil is down, "moved" past 12 pt closes it so the drag goes on.
  // A still hold on a Figma row makes WebKit lift an HTML drag (dragstart … dragend); if that closed
  // the menu and the finger never moved, the menu reopens once after dragend.
  const HOLD_SLOP = 12;
  let uiHold:
    | {
        down: PointerEvent;
        target: Element;
        at: number;
        rejected?: string;
        menu?: "open" | "closed";
        moved?: boolean;
        reopened?: boolean;
        menusBefore?: Set<Element>;
      }
    | undefined;
  const rejectUIHold = (reason: string) => {
    if (uiHold && !uiHold.rejected) uiHold.rejected = reason;
  };
  const cancelUIHold = () => {
    uiHold = undefined;
  };
  const nearDown = (event: MouseEvent) =>
    !!uiHold &&
    Math.hypot(
      event.clientX - uiHold.down.clientX,
      event.clientY - uiHold.down.clientY,
    ) <= HOLD_SLOP;
  // Menus: new, visible, near the point and not aria-hidden. Used only to avoid a second menu.
  const MENUS =
    '[role="menu"], [role="listbox"], [data-radix-popper-content-wrapper]';
  const menuElements = () =>
    new Set(Array.from(document.querySelectorAll?.(MENUS) ?? []));
  const newMenuNear = (before: Set<Element>, x: number, y: number) =>
    Array.from(menuElements()).some((el) => {
      if (before.has(el) || el.closest?.('[aria-hidden="true"]')) return false;
      const r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) return false;
      const dx = Math.max(r.left - x, 0, x - r.right);
      const dy = Math.max(r.top - y, 0, y - r.bottom);
      return Math.hypot(dx, dy) <= 300;
    });
  const contextMenuAt = (target: Element, x: number, y: number) =>
    target.dispatchEvent(
      new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        composed: true,
        view: window,
        clientX: x,
        clientY: y,
        screenX: x,
        screenY: y,
        button: 2,
        buttons: 0,
      }),
    );
  const openHoldMenu = () => {
    const hold = uiHold;
    if (!hold) return;
    hold.menusBefore = menuElements();
    hold.menu = "open";
    if (observing()) recordDrag("state", "hold-menu", hold.target, hold.down);
    contextMenuAt(hold.target, hold.down.clientX, hold.down.clientY);
  };
  const closeHoldMenu = () => {
    const target = document.activeElement ?? document.body;
    for (const type of ["keydown", "keyup"])
      target?.dispatchEvent(
        new KeyboardEvent(type, {
          key: "Escape",
          code: "Escape",
          keyCode: 27,
          bubbles: true,
          cancelable: true,
          composed: true,
        } as KeyboardEventInit),
      );
  };
  const nativeActivity = (event: Event) => {
    if (!event.isTrusted || !uiHold) return;
    if (event.type === "dragstart" || event.type === "drop") return;
    if (event.type === "dragend") {
      const hold = uiHold;
      // WebKit's lifted drag may have closed the menu; reopen once if the finger never moved.
      if (
        hold.menu === "open" &&
        !hold.moved &&
        !hold.reopened &&
        hold.target.isConnected &&
        !newMenuNear(
          hold.menusBefore ?? new Set(),
          hold.down.clientX,
          hold.down.clientY,
        )
      ) {
        hold.reopened = true;
        if (observing()) recordDrag("state", "hold-menu-reopen", hold.target);
        contextMenuAt(hold.target, hold.down.clientX, hold.down.clientY);
      }
      return;
    }
    if (uiHold.menu === undefined) rejectUIHold(event.type);
  };
  const nativeEvents = [
    "scroll",
    "dragstart",
    "drop",
    "dragend",
    "contextmenu",
  ];
  for (const name of nativeEvents)
    window.addEventListener(name, nativeActivity, {
      capture: true,
      passive: true,
    });
  // Opt-in fixed decisions only. home-armed followed by no home-click means the compatibility
  // click never reached this listener; rejection reasons require no Home markup inspection.
  const homeState = () =>
    !home ? "home-off" : enabled ? "home-ready" : "home-disabled";
  const homeDecision = (event: MouseEvent, detail: string) => {
    if (home) recordDrag("state", event.type, event.target, event, detail);
  };
  const pointer = (event: Event) => {
    if (
      event instanceof PointerEvent &&
      event.isTrusted &&
      event.type === "pointerdown"
    )
      homeDecision(event, homeState());
    if (!enabled || !(event instanceof PointerEvent) || !event.isTrusted)
      return;
    if (event.pointerType !== "touch" && event.pointerType !== "pen") {
      // Real mouse input must never be swallowed by a prior touch's click suppression.
      if (event.type === "pointerdown") {
        // WebKit's drag lift on a held row emits a trusted mouse press at the finger; keep the hold.
        const hold = uiHold && nearDown(event) ? uiHold : undefined;
        reset();
        uiHold = hold;
        mousePress = true;
        recordDrag("state", "mouse-down", event.target, event);
      }
      return;
    }
    if (event.type === "pointerdown") {
      mousePress = false;
      cancelUIHold();
    }
    if (event.type === "pointerdown") {
      contacts.add(event.pointerId);
      clearTimeout(timer);
      pending = undefined;
      tap = undefined;
      consumed = undefined;
      if (
        contacts.size !== 1 ||
        !event.isPrimary ||
        event.button !== 0 ||
        !(event.target instanceof Element) ||
        editable(event.target)
      ) {
        homeDecision(
          event,
          contacts.size !== 1
            ? "home-multi"
            : !event.isPrimary
              ? "home-primary"
              : event.button !== 0
                ? "home-button"
                : !(event.target instanceof Element)
                  ? "home-target"
                  : "home-editable",
        );
        return;
      }
      const canvas = canvasAtPoint(event.clientX, event.clientY, event.target);
      if (!home && !canvas) {
        uiHold = { down: event, target: event.target, at: performance.now() };
        return;
      }
      const sequence = { down: event, target: event.target, held: false };
      pending = sequence;
      homeDecision(event, "home-pending");
      timer = setTimeout(() => {
        if (
          pending !== sequence ||
          contacts.size !== 1 ||
          !sequence.target.isConnected
        )
          return;
        homeDecision(event, "home-held");
        sequence.held = true;
        consumed = { target: sequence.target, until: performance.now() + 1000 };
        runtime.cancelCanvasContact?.();
        // End the original left-button selection/drawing before starting a right-button sequence.
        dispatchUI(
          sequence.target,
          new PointerEvent("pointercancel", {
            bubbles: true,
            composed: true,
            pointerId: event.pointerId,
            pointerType: event.pointerType,
            isPrimary: true,
            clientX: event.clientX,
            clientY: event.clientY,
            button: 0,
            buttons: 0,
          }),
        );
        dispatchUI(
          sequence.target,
          new MouseEvent("mouseup", {
            bubbles: true,
            composed: true,
            clientX: event.clientX,
            clientY: event.clientY,
            button: 0,
            buttons: 0,
          }),
        );
        mouseSequence(sequence.target, event, 2, 0);
      }, 500);
      return;
    }
    if (
      uiHold?.down.pointerId === event.pointerId &&
      event.type === "pointermove" &&
      !nearDown(event) &&
      uiHold.menu === undefined
    )
      rejectUIHold("moved");
    const sequence = pending;
    if (sequence?.down.pointerId === event.pointerId) {
      if (
        !sequence.held &&
        event.type === "pointermove" &&
        Math.hypot(
          event.clientX - sequence.down.clientX,
          event.clientY - sequence.down.clientY,
        ) > 6
      ) {
        homeDecision(event, "home-moved");
        clearTimeout(timer);
        pending = undefined;
      } else if (sequence.held) {
        consumed = { target: sequence.target, until: performance.now() + 700 };
        suppress(event);
      } else if (
        event.type === "pointerup" &&
        home &&
        event.pointerType === "touch" &&
        Math.hypot(
          event.clientX - sequence.down.clientX,
          event.clientY - sequence.down.clientY,
        ) <= 6
      ) {
        homeDecision(event, "home-armed");
        tap = {
          target: sequence.target,
          x: event.clientX,
          y: event.clientY,
          until: performance.now() + 700,
        };
      }
    }
    if (event.type === "pointerup" || event.type === "pointercancel") {
      homeDecision(
        event,
        event.type === "pointercancel"
          ? "home-cancelled"
          : tap
            ? "home-await-click"
            : "home-no-tap",
      );
      contacts.delete(event.pointerId);
      clearTimeout(timer);
      pending = undefined;
    }
  };
  const mouse = (event: Event) => {
    if (
      event instanceof MouseEvent &&
      event.isTrusted &&
      event.type === "click"
    )
      homeDecision(
        event,
        !enabled
          ? "home-disabled"
          : mousePress
            ? "home-mouse"
            : tap
              ? "home-click"
              : "home-no-tap",
      );
    if (
      !enabled ||
      mousePress ||
      !event.isTrusted ||
      !(event instanceof MouseEvent)
    )
      return;
    if (
      !home &&
      event instanceof MouseEvent &&
      !canvasAtPoint(event.clientX, event.clientY, event.target)
    )
      return;
    if (
      consumed &&
      performance.now() < consumed.until &&
      event.target instanceof Node &&
      consumed.target.contains(event.target)
    ) {
      suppress(event);
      return;
    }
    if (event.type !== "click" || !tap || !home) return;
    const sequence = tap;
    tap = undefined;
    if (
      performance.now() > sequence.until ||
      !(event.target instanceof Node) ||
      !sequence.target.contains(event.target) ||
      Math.hypot(event.clientX - sequence.x, event.clientY - sequence.y) > 6
    ) {
      homeDecision(
        event,
        performance.now() > sequence.until
          ? "home-expired"
          : !(event.target instanceof Node)
            ? "home-target"
            : !sequence.target.contains(event.target)
              ? event.target.contains(sequence.target)
                ? "home-click-ancestor"
                : "home-click-other"
              : "home-distance",
      );
      return;
    }
    homeDecision(event, "home-double");
    suppress(event);
    // Replace the compatibility click with the full mouse double-click sequence.
    mouseSequence(sequence.target, event, 0, 1);
    if (!sequence.target.isConnected) {
      homeDecision(event, "home-detached");
      return;
    }
    mouseSequence(sequence.target, event, 0, 2);
    dispatchUI(
      sequence.target,
      new MouseEvent("dblclick", {
        bubbles: true,
        cancelable: true,
        composed: true,
        view: window,
        clientX: event.clientX,
        clientY: event.clientY,
        screenX: event.screenX,
        screenY: event.screenY,
        button: 0,
        buttons: 0,
        detail: 2,
        altKey: event.altKey,
        ctrlKey: event.ctrlKey,
        metaKey: event.metaKey,
        shiftKey: event.shiftKey,
      }),
    );
  };
  const touch = (event: Event) => {
    if (!enabled || !event.isTrusted || !(event instanceof TouchEvent)) return;
    if (event.touches.length > 1) {
      if (home)
        recordDrag("state", "finish", event.target, undefined, "home-multi");
      rejectUIHold("multi-touch");
      clearTimeout(timer);
      pending = undefined;
      tap = undefined;
      consumed = undefined;
    } else {
      if (
        consumed &&
        performance.now() < consumed.until &&
        event.target instanceof Node &&
        consumed.target.contains(event.target)
      )
        suppress(event);
    }
  };
  const groups: [string[], EventListener][] = [
    [["pointerdown", "pointermove", "pointerup", "pointercancel"], pointer],
    [["mousedown", "mouseup", "click", "dblclick", "contextmenu"], mouse],
    [["touchstart", "touchmove", "touchend", "touchcancel"], touch],
  ];
  for (const [names, listener] of groups)
    for (const name of names)
      window.addEventListener(name, listener, {
        capture: true,
        passive: false,
      });
  for (const name of ["blur", "pagehide"]) window.addEventListener(name, reset);
  runtime.setUIDragOptions = (logging) => {
    dragLogging = logging;
    recordDrag("state", "options", null, undefined, homeState());
  };
  // Called by the native long-press recognizer (0.5 s, 12 pt) with the finger/Pencil still down.
  runtime.touchUIHold = (phase, x, y) => {
    const hold = uiHold;
    if (!enabled) return "disabled";
    if (home) return "home";
    if (!hold) return "no-ui-press";
    if (phase === "began") {
      if (hold.rejected) return hold.rejected;
      if (performance.now() - hold.at > 5000) return "stale";
      if (Math.hypot(x - hold.down.clientX, y - hold.down.clientY) > 24)
        return "elsewhere";
      if (!hold.target.isConnected) return "detached";
      openHoldMenu();
      return "menu";
    }
    if (phase === "moved") {
      hold.moved = true;
      if (hold.menu !== "open") return "no-menu";
      hold.menu = "closed";
      closeHoldMenu();
      return "closed";
    }
    return hold.menu === "open" ? "kept" : "ended";
  };
  // Trackpad/mouse secondary click. iPadOS WebKit's own secondary press reaches the page without
  // button-2 mousedown/mouseup (device logs 2026-10-09), and Figma may open nothing. Right after
  // WebKit's contextmenu the missing mousedown/mouseup are added; a native recognizer reports the
  // click ~150 ms later and, if no new menu is visible near the point, sends the full sequence.
  let native:
    | {
        at: number;
        x: number;
        y: number;
        mousedown: boolean;
        mouseup: boolean;
        completed: boolean;
        menus: Set<Element>;
      }
    | undefined;
  const mouseAt = (
    target: EventTarget,
    type: string,
    x: number,
    y: number,
    buttons: number,
  ) =>
    target.dispatchEvent(
      new MouseEvent(type, {
        bubbles: true,
        cancelable: true,
        composed: true,
        view: window,
        clientX: x,
        clientY: y,
        screenX: x,
        screenY: y,
        button: 2,
        buttons,
        detail: 1,
      }),
    );
  const secondary = (event: Event) => {
    if (!event.isTrusted || !(event instanceof MouseEvent)) return;
    if (
      event.type === "pointerdown" &&
      event instanceof PointerEvent &&
      event.pointerType === "mouse" &&
      (event.buttons & 2) !== 0 &&
      !event.ctrlKey
    ) {
      native = {
        at: performance.now(),
        x: event.clientX,
        y: event.clientY,
        mousedown: false,
        mouseup: false,
        completed: false,
        menus: menuElements(),
      };
      return;
    }
    const press = native;
    if (!press || event.ctrlKey) return;
    if (event.type === "mousedown" && event.button === 2)
      press.mousedown = true;
    else if (event.type === "mouseup" && event.button === 2)
      press.mouseup = true;
    else if (event.type === "contextmenu" && !press.completed) {
      const target = event.target;
      // After WebKit's own dispatch (and the focus its pointerdown moved), add what it left out.
      setTimeout(() => {
        if (native !== press || press.completed || !(target instanceof Element))
          return;
        press.completed = true;
        if (!press.mousedown) mouseAt(target, "mousedown", press.x, press.y, 2);
        if (!press.mouseup) mouseAt(target, "mouseup", press.x, press.y, 0);
      });
    }
  };
  for (const name of ["contextmenu", "mousedown", "mouseup", "pointerdown"])
    window.addEventListener(name, secondary, { capture: true, passive: true });
  runtime.secondaryClick = (x, y) => {
    const press =
      native && performance.now() - native.at < 2000 ? native : undefined;
    native = undefined;
    if (press && newMenuNear(press.menus, x, y))
      return press.completed ? "menu-opened-after-completion" : "menu-opened";
    const target = document.elementFromPoint(x, y);
    if (!target) return "no-target";
    if (editable(target)) return "editable";
    mouseSequence(
      target,
      new MouseEvent("mousemove", {
        clientX: x,
        clientY: y,
        screenX: x,
        screenY: y,
      }),
      2,
      1,
    );
    return "menu";
  };
  runtime.resetTouchGestures = reset;
  runtime.setTouchGestures = (next, isHome) => {
    if (enabled !== next || home !== isHome) reset();
    enabled = next;
    home = isHome;
    if (enabled) (document.head ?? document.documentElement)?.append(style);
    else style.remove();
  };
  document.addEventListener(
    "DOMContentLoaded",
    () => {
      if (enabled) (document.head ?? document.documentElement)?.append(style);
    },
    { once: true },
  );
  runtime.disposeTouchGestures = () => {
    reset();
    enabled = false;
    style.remove();
    for (const [names, listener] of groups)
      for (const name of names)
        window.removeEventListener(name, listener, true);
    for (const name of ["blur", "pagehide"])
      window.removeEventListener(name, reset);
    for (const name of observedEvents)
      window.removeEventListener(name, observeDrag, true);
    for (const name of ["error", "unhandledrejection"])
      window.removeEventListener(name, observeError, true);
    for (const name of nativeEvents)
      window.removeEventListener(name, nativeActivity, true);
    delete runtime.setUIDragOptions;
    delete runtime.resetTouchGestures;
    delete runtime.touchUIHold;
    delete runtime.secondaryClick;
    for (const name of ["contextmenu", "mousedown", "mouseup", "pointerdown"])
      window.removeEventListener(name, secondary, true);
    delete runtime.setTouchGestures;
    delete runtime.disposeTouchGestures;
  };
}
export {};
