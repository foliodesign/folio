const runtime = globalThis.__folio;
if (runtime && !runtime.setPencilStrategy) {
  let enabled = false;
  interface Drag {
    target: EventTarget;
    startX: number;
    startY: number;
    moved: boolean;
    mouse: boolean;
    init: PointerEventInit;
  }
  const active = new Map<number, Drag>();
  const cancel = () => {
    const drags = [...active.values()];
    active.clear();
    for (const drag of drags) {
      const init = { ...drag.init, buttons: 0, pressure: 0, button: 0 };
      drag.target.dispatchEvent(new PointerEvent("pointercancel", init));
      if (drag.mouse)
        drag.target.dispatchEvent(new MouseEvent("mouseup", init));
    }
  };
  const listener = (event: Event) => {
    if (
      !enabled ||
      !(event instanceof PointerEvent) ||
      !event.isTrusted ||
      event.pointerType !== "pen" ||
      !event.target
    )
      return;
    const init: PointerEventInit = {
      bubbles: true,
      cancelable: true,
      composed: true,
      clientX: event.clientX,
      clientY: event.clientY,
      screenX: event.screenX,
      screenY: event.screenY,
      button: event.type === "pointercancel" ? 0 : event.button,
      buttons: event.type === "pointercancel" ? 0 : event.buttons,
      pointerId: event.pointerId,
      pointerType: "mouse",
      isPrimary: event.isPrimary,
      pressure: event.type === "pointercancel" ? 0 : event.pressure,
      tiltX: event.tiltX,
      tiltY: event.tiltY,
      altKey: event.altKey,
      ctrlKey: event.ctrlKey,
      metaKey: event.metaKey,
      shiftKey: event.shiftKey,
    };
    if (event.type === "pointerdown") {
      // One primary left-button sequence; ignore eraser/secondary contacts.
      if (!event.isPrimary || event.button !== 0 || active.size) return;
      active.set(event.pointerId, {
        target: event.target,
        startX: event.clientX,
        startY: event.clientY,
        moved: false,
        mouse: true,
        init,
      });
    }
    const drag = active.get(event.pointerId);
    if (!drag) return;
    drag.init = init;
    drag.moved ||=
      Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY) > 5;
    // Originals stay observable. These untrusted events may duplicate WebKit's own mouse events.
    const accepted = drag.target.dispatchEvent(
      new PointerEvent(event.type, init),
    );
    if (event.type === "pointerdown" && !accepted) drag.mouse = false;
    // A listener may have changed the strategy during dispatch and cancelled this sequence.
    if (active.get(event.pointerId) !== drag) return;
    const mouseType = {
      pointerdown: "mousedown",
      pointermove: "mousemove",
      pointerup: "mouseup",
      pointercancel: "mouseup",
    }[event.type];
    if (drag.mouse && mouseType)
      drag.target.dispatchEvent(
        new MouseEvent(mouseType, {
          ...init,
          button: mouseType === "mousemove" ? 0 : init.button,
        }),
      );
    if (active.get(event.pointerId) !== drag) return;
    if (event.type === "pointerup" || event.type === "pointercancel") {
      active.delete(event.pointerId);
      if (event.type === "pointerup" && !drag.moved && drag.mouse)
        drag.target.dispatchEvent(new MouseEvent("click", init));
    }
  };
  const names = ["pointerdown", "pointermove", "pointerup", "pointercancel"];
  runtime.setPencilStrategy = (strategy, unusable) => {
    const next = strategy === "pencil-as-mouse-js" && unusable;
    if (next === enabled) return;
    enabled = next;
    cancel();
  };
  for (const name of names)
    window.addEventListener(name, listener, { capture: true, passive: true });
  window.addEventListener("blur", cancel);
  window.addEventListener("pagehide", cancel);
  runtime.disposePencil = () => {
    enabled = false;
    cancel();
    for (const name of names) window.removeEventListener(name, listener, true);
    window.removeEventListener("blur", cancel);
    window.removeEventListener("pagehide", cancel);
    delete runtime.setPencilStrategy;
    delete runtime.disposePencil;
  };
}
export {};
