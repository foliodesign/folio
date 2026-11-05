import { observeKeyboardRouting } from "./keyboard-routing";
import { keyLabel } from "./key-label";
export {};
const runtime = globalThis.__folio;
if (runtime && !runtime.setInputLogging) {
  let enabled = false;
  const keyboardLogging = observeKeyboardRouting(runtime);
  let lastMove = -Infinity;
  const events = [
    "pointerdown",
    "pointerup",
    "pointermove",
    "pointercancel",
    "pointerover",
    "pointerout",
    "pointerenter",
    "pointerleave",
    "gotpointercapture",
    "lostpointercapture",
    "touchstart",
    "touchmove",
    "touchend",
    "touchcancel",
    "mousedown",
    "mouseup",
    "mousemove",
    "mouseover",
    "mouseout",
    "mouseenter",
    "mouseleave",
    "click",
    "dblclick",
    "contextmenu",
    "wheel",
    "gesturestart",
    "gesturechange",
    "gestureend",
    "keydown",
    "keyup",
  ];
  // Only geometry and fixed event metadata. No target, DOM text or printable key values.
  const listener = (event: Event) => {
    if (event.type.endsWith("move")) {
      const now = performance.now();
      if (now - lastMove < 100) return;
      lastMove = now;
    }
    const mouse = event instanceof MouseEvent ? event : undefined;
    const pointer =
      typeof PointerEvent !== "undefined" && event instanceof PointerEvent
        ? event
        : undefined;
    const key = event instanceof KeyboardEvent ? event : undefined;
    const touch =
      typeof TouchEvent !== "undefined" && event instanceof TouchEvent
        ? event.changedTouches[0]
        : undefined;
    const payload = {
      type: event.type,
      pointerType:
        pointer?.pointerType || (touch ? "touch" : mouse ? "mouse" : "none"),
      isTrusted: event.isTrusted,
      button: mouse?.button ?? 0,
      buttons: mouse?.buttons ?? 0,
      prevented: event.defaultPrevented,
      coalesced: pointer?.getCoalescedEvents?.().length ?? 0,
      pressure: pointer?.pressure ?? touch?.force ?? 0,
      tiltX: pointer?.tiltX ?? 0,
      tiltY: pointer?.tiltY ?? 0,
      x: mouse?.clientX ?? touch?.clientX ?? 0,
      y: mouse?.clientY ?? touch?.clientY ?? 0,
      deltaX: event instanceof WheelEvent ? event.deltaX : 0,
      deltaY: event instanceof WheelEvent ? event.deltaY : 0,
      key: key ? keyLabel(key) : "",
      alt: key?.altKey ?? mouse?.altKey ?? false,
      ctrl: key?.ctrlKey ?? mouse?.ctrlKey ?? false,
      meta: key?.metaKey ?? mouse?.metaKey ?? false,
      shift: key?.shiftKey ?? mouse?.shiftKey ?? false,
    };
    // Mouse/pointer lines are posted after dispatch so `prevented` shows whether the page (or
    // Folio) cancelled the event. Keys stay synchronous.
    if (mouse)
      setTimeout(() =>
        runtime.post("folioInputLog", {
          ...payload,
          prevented: event.defaultPrevented,
        }),
      );
    else runtime.post("folioInputLog", payload);
  };
  runtime.setInputLogging = (value) => {
    keyboardLogging(value);
    if (enabled === value) return;
    enabled = value;
    for (const name of events) {
      if (enabled)
        window.addEventListener(name, listener, {
          capture: true,
          passive: true,
        });
      else window.removeEventListener(name, listener, true);
    }
  };
  runtime.disposeInputLog = () => {
    runtime.setInputLogging?.(false);
    delete runtime.captureKeyboardFocus;
    delete runtime.setInputLogging;
    delete runtime.disposeInputLog;
  };
}
