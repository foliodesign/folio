import { canvasAtPoint } from "./canvas-target";
// Figma's ctrl-wheel zoom on this iPad is zoom *= exp(-0.0025 * deltaY) (pinch harness,
// 2026-10-07). deltaY = -400 ln(scale) makes Figma's zoom equal the trackpad's cumulative pinch
// scale, the way a native iPad pinch tracks the fingers. Earlier on-device feedback at gain 4 came
// from a build that reset UIPinchGestureRecognizer.scale per callback; native now reads the
// recognizer's cumulative scale directly.
export const PINCH_GAIN = 4;
export const PINCH_MAX_STEP = 25;
export const PINCH_EPSILON = 1e-4;
// A pinch starts zooming only past 2% so jitter during two-finger scrolling never zooms.
export const PINCH_START = 0.02;
export function scaleToDelta(ratio: number): number {
  return Number.isFinite(ratio) && ratio > 0
    ? -100 * PINCH_GAIN * Math.log(ratio)
    : 0;
}
export function splitDelta(dy: number): number[] {
  if (!Number.isFinite(dy) || dy === 0) return [];
  const count = Math.ceil(Math.abs(dy) / PINCH_MAX_STEP);
  const chunk = dy / count;
  const chunks = Array<number>(count).fill(chunk);
  chunks[count - 1] = dy - chunk * (count - 1);
  return chunks;
}
interface GestureEventLike extends Event {
  scale: number;
  rotation: number;
  initGestureEvent(
    type: string,
    bubbles: boolean,
    cancelable: boolean,
    view: Window,
    detail: number,
    screenX: number,
    screenY: number,
    clientX: number,
    clientY: number,
    ctrl: boolean,
    alt: boolean,
    shift: boolean,
    meta: boolean,
    target: Element,
    scale: number,
    rotation: number,
  ): void;
}
const runtime = globalThis.__folio;
if (runtime && !runtime.setCanvasWheel) {
  let enabled = true;
  let touchMode: "pencil-and-touch" | "touch-only" = "pencil-and-touch";
  let direct:
    | {
        down: PointerEvent;
        target: HTMLCanvasElement;
        last: PointerEvent;
        moved: boolean;
        mouse: boolean;
        started: boolean;
        modifiers: PointerEventInit;
        capture?: Element;
      }
    | undefined;
  let directHold: ReturnType<typeof setTimeout> | undefined;
  let multiContact = false;
  let fingerGestureMoved = false;
  let fingerGesture:
    | {
        x: number;
        y: number;
        startX: number;
        startY: number;
        distance: number;
        applied: number;
        zooming: boolean;
        panning: boolean;
      }
    | undefined;
  let trackpadZoom = true;
  let ctrlHeld = false;
  let replaying = false;
  const touches = new Set<number>();
  const canvasContacts = new Set<number>();
  let pending:
    | {
        down: PointerEvent;
        target: HTMLCanvasElement;
        x: number;
        y: number;
        time: number;
        pan: boolean;
        vx: number;
        vy: number;
        buffered: Event[];
      }
    | undefined;
  let hold: ReturnType<typeof setTimeout> | undefined;
  let momentum: ReturnType<typeof setTimeout> | undefined;
  let suppressMouseUntil = 0;
  let lastTap:
    | { time: number; x: number; y: number; target: EventTarget }
    | undefined;
  const stopMomentum = () => {
    clearTimeout(momentum);
    momentum = undefined;
  };
  const dispatch = (target: EventTarget, event: Event) => {
    replaying = true;
    try {
      return target.dispatchEvent(event);
    } finally {
      replaying = false;
    }
  };
  const wheel = (
    x: number,
    y: number,
    dx: number,
    dy: number,
    ctrlKey = false,
  ) => {
    const target = document.elementFromPoint(x, y);
    if (target)
      dispatch(
        target,
        new WheelEvent("wheel", {
          clientX: x,
          clientY: y,
          deltaX: dx,
          deltaY: dy,
          deltaMode: 0,
          ctrlKey,
          bubbles: true,
          cancelable: true,
          composed: true,
        }),
      );
  };
  let route: "wheel" | "gesture" = "wheel";
  let gestureSupported = false;
  const constructGesture = (
    type: string,
    scale: number,
    x: number,
    y: number,
    target: Element,
  ) => {
    const event = document.createEvent("GestureEvent") as GestureEventLike;
    event.initGestureEvent(
      type,
      true,
      true,
      window,
      0,
      x,
      y,
      x,
      y,
      false,
      false,
      false,
      false,
      target,
      scale,
      0,
    );
    return event;
  };
  try {
    // A present initializer can still throw. Probe construction, not just its name.
    const probe = constructGesture(
      "gesturechange",
      1.25,
      0,
      0,
      document.documentElement,
    );
    gestureSupported = probe.scale === 1.25;
  } catch {
    /* This WebKit cannot construct usable gesture events. Wheel remains default. */
  }
  let dispatched = 0,
    prevented = 0;
  let gesture:
    | {
        target: Element;
        x: number;
        y: number;
        applied: number;
        started: boolean;
        startedAs: "wheel" | "gesture";
      }
    | undefined;
  const effectiveRoute = () =>
    route === "gesture" && gestureSupported ? "gesture" : "wheel";
  const pinchDispatch = (target: Element, event: Event) => {
    dispatched += 1;
    if (!dispatch(target, event)) prevented += 1;
  };
  const gestureEvent = (type: string, scale: number) => {
    if (!gesture) return;
    const { target, x, y } = gesture;
    try {
      pinchDispatch(target, constructGesture(type, scale, x, y, target));
    } catch {
      gestureSupported = false;
      gesture.startedAs = "wheel";
    }
  };
  const endPinch = () => {
    if (gesture?.started && gesture.startedAs === "gesture")
      gestureEvent("gestureend", gesture.applied);
    gesture = undefined;
  };
  runtime.resetTrackpadPinch = endPinch;
  runtime.setTrackpadPinchRoute = (next) => {
    route = next;
  };
  runtime.trackpadPinchGain = () => PINCH_GAIN;
  runtime.trackpadPinchStats = () => ({
    route: effectiveRoute(),
    dispatched,
    prevented,
    gestureSupported,
  });
  runtime.trackpadPinch = (phase, scale, x, y) => {
    if (
      !Number.isFinite(scale) ||
      scale <= 0 ||
      !Number.isFinite(x) ||
      !Number.isFinite(y)
    )
      return;
    if (phase === "began") {
      endPinch();
      // Only Figma's canvas zooms. Pinches anywhere else stay exactly as the browser leaves them.
      const target = trackpadZoom ? canvasAtPoint(x, y) : undefined;
      if (!(target instanceof HTMLCanvasElement)) return;
      gesture = {
        target,
        x,
        y,
        applied: 1,
        started: false,
        startedAs: effectiveRoute(),
      };
      return;
    }
    if ((phase !== "changed" && phase !== "ended") || !gesture) return;
    if (!gesture.started) {
      if (Math.abs(Math.log(scale)) < PINCH_START) {
        if (phase === "ended") gesture = undefined;
        return;
      }
      gesture.started = true;
      if (gesture.startedAs === "gesture") gestureEvent("gesturestart", 1);
    }
    if (!gesture.target.isConnected) {
      const target = document.elementFromPoint(gesture.x, gesture.y);
      if (!target) {
        gesture = undefined;
        return;
      }
      gesture.target = target;
    }
    if (gesture.startedAs === "wheel") {
      // Subtract logs to avoid overflow of scale / applied for finite extremes.
      const logRatio = Math.log(scale) - Math.log(gesture.applied);
      if (Math.abs(logRatio) >= PINCH_EPSILON) {
        for (const dy of splitDelta(-100 * PINCH_GAIN * logRatio))
          pinchDispatch(
            gesture.target,
            new WheelEvent("wheel", {
              clientX: gesture.x,
              clientY: gesture.y,
              deltaX: 0,
              deltaY: dy,
              deltaMode: 0,
              ctrlKey: true,
              bubbles: true,
              cancelable: true,
              composed: true,
            }),
          );
        gesture.applied = scale;
      }
    } else {
      if (phase === "changed" || scale !== gesture.applied)
        gestureEvent("gesturechange", scale);
      if (!gestureSupported) {
        runtime.trackpadPinch?.(phase, scale, x, y);
        return;
      }
      gesture.applied = scale;
      if (phase === "ended") gestureEvent("gestureend", scale);
    }
    if (phase === "ended") gesture = undefined;
  };
  // iOS WebKit builds trackpad wheel events with no modifiers, so Ctrl+scroll reaches the page as
  // a plain scroll. Track Ctrl from trusted key events and, over the canvas only, replay
  // the wheel event with ctrlKey like a desktop browser. Everything else scrolls natively.
  const modifiers = (event: Event) => {
    if (!event.isTrusted) return;
    if (event instanceof KeyboardEvent)
      ctrlHeld =
        event.key === "Control" ? event.type === "keydown" : event.ctrlKey;
  };
  const ctrlWheel = (event: Event) => {
    if (
      replaying ||
      !trackpadZoom ||
      !ctrlHeld ||
      !(event instanceof WheelEvent) ||
      !event.isTrusted ||
      event.ctrlKey ||
      !canvasAtPoint(event.clientX, event.clientY, event.target)
    )
      return;
    suppress(event, true);
    dispatch(
      canvasAtPoint(event.clientX, event.clientY, event.target)!,
      new WheelEvent("wheel", {
        clientX: event.clientX,
        clientY: event.clientY,
        screenX: event.screenX,
        screenY: event.screenY,
        deltaX: event.deltaX,
        deltaY: event.deltaY,
        deltaMode: event.deltaMode,
        ctrlKey: true,
        shiftKey: event.shiftKey,
        altKey: event.altKey,
        metaKey: event.metaKey,
        bubbles: true,
        cancelable: true,
        composed: true,
      }),
    );
  };
  const pointerInit = (e: PointerEvent): PointerEventInit => ({
    clientX: e.clientX,
    clientY: e.clientY,
    screenX: e.screenX,
    screenY: e.screenY,
    pointerId: e.pointerId,
    pointerType: e.pointerType,
    isPrimary: e.isPrimary,
    button: e.button,
    buttons: e.buttons,
    pressure: e.pressure,
    width: e.width,
    height: e.height,
    bubbles: true,
    cancelable: true,
    composed: true,
  });
  const replay = () => {
    const sequence = pending;
    pending = undefined;
    clearTimeout(hold);
    if (!sequence) return;
    for (const e of sequence.buffered) {
      if (e instanceof PointerEvent)
        dispatch(sequence.target, new PointerEvent(e.type, pointerInit(e)));
      else if (e instanceof MouseEvent)
        dispatch(
          sequence.target,
          new MouseEvent(e.type, {
            clientX: e.clientX,
            clientY: e.clientY,
            screenX: e.screenX,
            screenY: e.screenY,
            button: e.button,
            buttons: e.buttons,
            detail: e.detail,
            bubbles: true,
            cancelable: true,
            composed: true,
          }),
        );
      else if (e instanceof TouchEvent)
        dispatch(
          sequence.target,
          new TouchEvent(e.type, {
            touches: [...e.touches],
            targetTouches: [...e.targetTouches],
            changedTouches: [...e.changedTouches],
            bubbles: true,
            cancelable: true,
            composed: true,
          }),
        );
    }
  };
  const reset = () => {
    endDirect(true);
    fingerGesture = undefined;
    multiContact = false;
    fingerGestureMoved = false;
    endPinch();
    ctrlHeld = false;
    stopMomentum();
    clearTimeout(hold);
    pending = undefined;
    touches.clear();
    canvasContacts.clear();
    lastTap = undefined;
  };
  const suppress = (e: Event, prevent: boolean) => {
    e.stopImmediatePropagation();
    if (prevent && e.cancelable) e.preventDefault();
  };
  const coast = (x: number, y: number, vx: number, vy: number) => {
    let frames = 0;
    const tick = () => {
      vx *= 0.82;
      vy *= 0.82;
      if (++frames > 24 || Math.hypot(vx, vy) < 0.5) {
        momentum = undefined;
        return;
      }
      wheel(x, y, vx, vy);
      momentum = setTimeout(tick, 16);
    };
    momentum = setTimeout(tick, 16);
  };
  const directPair = (
    sequence: NonNullable<typeof direct>,
    phase: "down" | "move" | "up",
  ) => {
    const e = phase === "down" ? sequence.down : sequence.last;
    const target = sequence.capture?.isConnected
      ? sequence.capture
      : sequence.target;
    const init: PointerEventInit = {
      ...pointerInit(e),
      pointerType: "mouse",
      pointerId: sequence.down.pointerId,
      button: phase === "move" ? -1 : 0,
      buttons: phase === "down" || phase === "move" ? 1 : 0,
      pressure: phase === "down" || phase === "move" ? e.pressure : 0,
      altKey: e.altKey || sequence.modifiers.altKey,
      ctrlKey: e.ctrlKey || sequence.modifiers.ctrlKey,
      metaKey: e.metaKey || sequence.modifiers.metaKey,
      shiftKey: e.shiftKey || sequence.modifiers.shiftKey,
    };
    const accepted = dispatch(
      target,
      new PointerEvent(`pointer${phase}`, init),
    );
    if (phase === "down") sequence.mouse = accepted;
    if (sequence.mouse)
      dispatch(
        target,
        new MouseEvent(`mouse${phase}`, {
          ...init,
          button: 0,
        }),
      );
  };
  const startDirect = () => {
    const sequence = direct;
    clearTimeout(directHold);
    directHold = undefined;
    if (!sequence || sequence.started || touches.size !== 1 || multiContact)
      return;
    sequence.started = true;
    directPair(sequence, "down");
  };
  const endDirect = (cancelled: boolean) => {
    clearTimeout(directHold);
    directHold = undefined;
    const sequence = direct;
    if (!sequence) return;
    direct = undefined;
    if (!sequence.started) return;
    // A handoff/cancellation closes the drag where it began, never at the marquee's far corner.
    if (cancelled) sequence.last = sequence.down;
    directPair(sequence, "up");
    if (sequence.capture?.hasPointerCapture?.(sequence.down.pointerId))
      sequence.capture.releasePointerCapture(sequence.down.pointerId);
    if (
      !cancelled &&
      sequence.mouse &&
      !sequence.moved &&
      sequence.target.isConnected
    ) {
      const e = sequence.last;
      const double =
        lastTap &&
        performance.now() - lastTap.time < 350 &&
        lastTap.target === sequence.target &&
        Math.hypot(e.clientX - lastTap.x, e.clientY - lastTap.y) < 8;
      const init = {
        ...pointerInit(e),
        pointerType: "mouse",
        buttons: 0,
        pressure: 0,
        detail: double ? 2 : 1,
        altKey: e.altKey || sequence.modifiers.altKey,
        ctrlKey: e.ctrlKey || sequence.modifiers.ctrlKey,
        metaKey: e.metaKey || sequence.modifiers.metaKey,
        shiftKey: e.shiftKey || sequence.modifiers.shiftKey,
      };
      dispatch(sequence.target, new MouseEvent("click", init));
      if (double) dispatch(sequence.target, new MouseEvent("dblclick", init));
      lastTap = double
        ? undefined
        : {
            time: performance.now(),
            x: e.clientX,
            y: e.clientY,
            target: sequence.target,
          };
    }
    if (!cancelled) runtime.consumeTouchShortcutModifiers?.();
  };
  const capture = (event: Event) => {
    if (
      !(event instanceof PointerEvent) ||
      !direct ||
      event.pointerId !== direct.down.pointerId
    )
      return;
    if (event.type === "gotpointercapture" && event.target instanceof Element)
      direct.capture = event.target;
    else if (event.target === direct.capture) direct.capture = undefined;
  };
  const pointer = (event: Event) => {
    if (replaying || !(event instanceof PointerEvent) || !event.isTrusted)
      return;
    if (event.pointerType !== "touch") {
      if (event.type === "pointerdown") {
        stopMomentum();
        endDirect(true);
      }
      suppressMouseUntil = 0;
      return;
    }
    if (event.type === "pointerdown") {
      stopMomentum();
      if (direct?.down.pointerId === event.pointerId) endDirect(true);
      touches.add(event.pointerId);
      const onCanvas = !!canvasAtPoint(
        event.clientX,
        event.clientY,
        event.target,
      );
      if (onCanvas) canvasContacts.add(event.pointerId);
      if (touches.size > 1) {
        if (enabled && (pending || direct || multiContact)) {
          endDirect(true);
          clearTimeout(hold);
          pending = undefined;
          lastTap = undefined;
          multiContact = true;
          suppressMouseUntil = performance.now() + 700;
          // TouchEvents own the two-finger geometry. UIKit tap recognizers still see real touches.
          if (onCanvas) suppress(event, false);
        }
        return;
      }
      if (
        !enabled ||
        !canvasAtPoint(event.clientX, event.clientY, event.target)
      )
        return;
      if (!multiContact) fingerGestureMoved = false;
      if (touchMode === "touch-only") {
        endDirect(true);
        direct = {
          down: event,
          last: event,
          target: canvasAtPoint(event.clientX, event.clientY, event.target)!,
          moved: false,
          mouse: true,
          started: false,
          modifiers: runtime.touchShortcutFlags?.() ?? {},
        };
        suppressMouseUntil = performance.now() + 1000;
        const sequence = direct;
        directHold = setTimeout(() => {
          if (direct === sequence) startDirect();
        }, 120);
        suppress(event, true);
        return;
      }
      pending = {
        down: event,
        target: canvasAtPoint(event.clientX, event.clientY, event.target)!,
        x: event.clientX,
        y: event.clientY,
        time: performance.now(),
        pan: false,
        vx: 0,
        vy: 0,
        buffered: [event],
      };
      suppressMouseUntil = performance.now() + 1000;
      // Long press returns the held events and lets subsequent input pass through.
      hold = setTimeout(() => {
        replay();
        suppressMouseUntil = 0;
      }, 500);
      suppress(event, false);
      return;
    }
    if (multiContact) {
      if (canvasContacts.has(event.pointerId)) suppress(event, false);
      if (event.type === "pointerup" || event.type === "pointercancel") {
        touches.delete(event.pointerId);
        canvasContacts.delete(event.pointerId);
      }
      return;
    }
    if (direct?.down.pointerId === event.pointerId) {
      direct.last = event;
      suppressMouseUntil = performance.now() + 700;
      if (event.type === "pointermove") {
        direct.moved ||=
          Math.hypot(
            event.clientX - direct.down.clientX,
            event.clientY - direct.down.clientY,
          ) >= 8;
        if (direct.moved) startDirect();
        if (direct.started) directPair(direct, "move");
      } else if (event.type === "pointerup" || event.type === "pointercancel") {
        // A short single-finger tap still receives a complete down/up/click sequence.
        if (event.type === "pointerup") startDirect();
        endDirect(event.type === "pointercancel");
        touches.delete(event.pointerId);
        canvasContacts.delete(event.pointerId);
      }
      suppress(event, true);
      return;
    }
    const sequence = pending;
    if (
      sequence &&
      sequence.down.pointerId === event.pointerId &&
      touches.size === 1
    ) {
      const now = performance.now();
      suppressMouseUntil = now + 700;
      if (event.type === "pointermove") {
        if (
          !sequence.pan &&
          Math.hypot(
            event.clientX - sequence.down.clientX,
            event.clientY - sequence.down.clientY,
          ) >= 8
        ) {
          sequence.pan = true;
          clearTimeout(hold);
          sequence.buffered = [];
        }
        if (sequence.pan) {
          const dx = sequence.x - event.clientX,
            dy = sequence.y - event.clientY;
          const dt = Math.max(8, now - sequence.time);
          sequence.vx = (dx * 16) / dt;
          sequence.vy = (dy * 16) / dt;
          wheel(event.clientX, event.clientY, dx, dy);
        } else sequence.buffered.push(event);
        if (sequence.pan) {
          sequence.x = event.clientX;
          sequence.y = event.clientY;
          sequence.time = now;
        }
      } else if (event.type === "pointerup" || event.type === "pointercancel") {
        clearTimeout(hold);
        pending = undefined;
        if (event.type === "pointerup") {
          if (sequence.pan) {
            if (now - sequence.time < 80)
              coast(sequence.x, sequence.y, sequence.vx, sequence.vy);
          } else {
            const double =
              lastTap &&
              now - lastTap.time < 350 &&
              lastTap.target === sequence.target &&
              Math.hypot(event.clientX - lastTap.x, event.clientY - lastTap.y) <
                8;
            const init = {
              ...pointerInit(event),
              pointerType: "mouse",
              pointerId: sequence.down.pointerId,
              button: 0,
              pressure: 0,
              detail: double ? 2 : 1,
            };
            const accepted = dispatch(
              sequence.target,
              new PointerEvent("pointerdown", { ...init, buttons: 1 }),
            );
            if (accepted)
              dispatch(
                sequence.target,
                new MouseEvent("mousedown", { ...init, buttons: 1 }),
              );
            dispatch(
              sequence.target,
              new PointerEvent("pointerup", { ...init, buttons: 0 }),
            );
            if (accepted) {
              dispatch(
                sequence.target,
                new MouseEvent("mouseup", { ...init, buttons: 0 }),
              );
              dispatch(
                sequence.target,
                new MouseEvent("click", { ...init, buttons: 0 }),
              );
              if (double)
                dispatch(
                  sequence.target,
                  new MouseEvent("dblclick", { ...init, buttons: 0 }),
                );
            }
            lastTap = double
              ? undefined
              : {
                  time: now,
                  x: event.clientX,
                  y: event.clientY,
                  target: sequence.target,
                };
          }
        }
        suppressMouseUntil = now + 700;
      }
      suppress(event, sequence.pan);
    }
    if (event.type === "pointerup" || event.type === "pointercancel")
      touches.delete(event.pointerId);
  };
  const touch = (event: Event) => {
    if (
      replaying ||
      !enabled ||
      !(event instanceof TouchEvent) ||
      !event.isTrusted
    )
      return;
    // Touch termination is a fallback when WebKit omits the matching pointer termination.
    if (direct && (event.type === "touchcancel" || event.type === "touchend")) {
      if (event.type === "touchcancel" || !event.touches.length) {
        if (event.type === "touchend") startDirect();
        endDirect(event.type === "touchcancel");
        touches.clear();
        canvasContacts.clear();
        suppressMouseUntil = performance.now() + 700;
        suppress(event, true);
        return;
      }
    }
    if (event.touches.length > 1 || multiContact) {
      const points = [...event.touches];
      if (direct || pending) {
        endDirect(true);
        clearTimeout(hold);
        pending = undefined;
        multiContact = true;
        lastTap = undefined;
      }
      if (
        event.type === "touchstart" &&
        points.length === 2 &&
        points.every((p) => !!canvasAtPoint(p.clientX, p.clientY))
      ) {
        endDirect(true);
        clearTimeout(hold);
        pending = undefined;
        multiContact = true;
        lastTap = undefined;
        const [a, b] = points as [Touch, Touch];
        const x = (a.clientX + b.clientX) / 2,
          y = (a.clientY + b.clientY) / 2;
        fingerGesture = {
          x,
          y,
          startX: x,
          startY: y,
          distance: Math.max(
            1,
            Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY),
          ),
          applied: 1,
          zooming: false,
          panning: false,
        };
      } else if (points.length !== 2 || event.type === "touchcancel")
        fingerGesture = undefined;
      const g = fingerGesture;
      if (g && event.type === "touchmove") {
        const [a, b] = points as [Touch, Touch];
        const x = (a.clientX + b.clientX) / 2,
          y = (a.clientY + b.clientY) / 2;
        const scale =
          Math.max(
            1,
            Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY),
          ) / g.distance;
        g.zooming ||= Math.abs(Math.log(scale)) >= PINCH_START;
        g.panning ||= Math.hypot(x - g.startX, y - g.startY) >= 8;
        fingerGestureMoved ||= g.panning || g.zooming;
        // Native pinch: pan by the centroid's movement, then zoom about the current centroid, so
        // the content under the fingers stays under them.
        // Once armed, pan still needs actual centroid movement. A stationary reversal must
        // deliver only ctrl-wheel zoom, never a plain zero-delta scroll between zoom updates.
        if (g.panning && (g.x !== x || g.y !== y))
          wheel(x, y, g.x - x, g.y - y);
        if (g.zooming) {
          for (const dy of splitDelta(scaleToDelta(scale / g.applied)))
            wheel(x, y, 0, dy, true);
          g.applied = scale;
        }
        g.x = x;
        g.y = y;
      }
      if (multiContact) {
        suppressMouseUntil = performance.now() + 700;
        if (event.target instanceof HTMLCanvasElement) suppress(event, true);
        if (!points.length || event.type === "touchcancel") {
          multiContact = false;
          touches.clear();
          canvasContacts.clear();
        }
      }
      return;
    }
    if (direct) {
      suppress(event, true);
      return;
    }
    if (pending) {
      if (!pending.pan) pending.buffered.push(event);
      suppress(event, pending.pan);
    } else if (
      performance.now() < suppressMouseUntil &&
      event.target instanceof HTMLCanvasElement
    ) {
      suppress(event, event.type === "touchend");
    }
  };
  const mouse = (event: Event) => {
    if (
      replaying ||
      !enabled ||
      !event.isTrusted ||
      !(event instanceof MouseEvent)
    )
      return;
    // sourceCapabilities distinguishes touch compatibility events from real pointer clicks.
    const source = (
      event as MouseEvent & {
        sourceCapabilities?: { firesTouchEvents: boolean };
      }
    ).sourceCapabilities;
    if (
      !!canvasAtPoint(event.clientX, event.clientY, event.target) &&
      (source?.firesTouchEvents ?? event.target instanceof HTMLCanvasElement) &&
      performance.now() < suppressMouseUntil
    ) {
      if (pending && !pending.pan) pending.buffered.push(event);
      suppress(event, true);
    }
  };
  // WebKit also turns two canvas fingers into trusted GestureEvents. The finger transport owns
  // that pinch; letting the page see both would zoom twice.
  const nativeGesture = (event: Event) => {
    if (
      !replaying &&
      enabled &&
      event.isTrusted &&
      (fingerGesture || multiContact)
    )
      suppress(event, true);
  };
  const groups: [string[], EventListener][] = [
    [["gotpointercapture", "lostpointercapture"], capture],
    [["gesturestart", "gesturechange", "gestureend"], nativeGesture],
    [["keydown", "keyup"], modifiers],
    [["wheel"], ctrlWheel],
    [["pointerdown", "pointermove", "pointerup", "pointercancel"], pointer],
    [["touchstart", "touchmove", "touchend", "touchcancel"], touch],
    [["mousedown", "mousemove", "mouseup", "click", "dblclick"], mouse],
  ];
  for (const [names, listener] of groups)
    for (const name of names)
      window.addEventListener(name, listener, {
        capture: true,
        passive: false,
      });
  for (const name of ["blur", "pagehide"]) window.addEventListener(name, reset);
  // A new editing/keyboard/pointer interaction ends any previous touch coast.
  // Never let synthesized wheel input continue after focus enters an editor.
  for (const name of ["focusin", "keydown"])
    window.addEventListener(name, stopMomentum, true);
  const visibility = () => {
    if (document.hidden) reset();
  };
  document.addEventListener("visibilitychange", visibility);
  runtime.ownsCanvasTouch = (event) =>
    enabled &&
    touchMode === "touch-only" &&
    event.pointerType === "touch" &&
    (!!direct || multiContact || event.target instanceof HTMLCanvasElement);
  runtime.isCanvasPoint = (x, y) => !!canvasAtPoint(x, y);
  runtime.canvasGestureDidMove = () => fingerGestureMoved;
  runtime.cancelCanvasContact = () => {
    endDirect(true);
    fingerGesture = undefined;
    multiContact = false;
    touches.clear();
    canvasContacts.clear();
    clearTimeout(hold);
    pending = undefined;
    stopMomentum();
    lastTap = undefined;
    suppressMouseUntil = performance.now() + 700;
  };
  runtime.setTrackpadZoom = (next) => {
    if (!next) endPinch();
    trackpadZoom = next;
  };
  runtime.setTouchMode = (next) => {
    if (touchMode === next) return;
    runtime.resetTouchShortcuts?.();
    runtime.resetTouchGestures?.();
    reset();
    suppressMouseUntil = performance.now() + 700;
    touchMode = next;
  };
  runtime.setCanvasWheel = (next) => {
    if (next !== enabled) {
      reset();
      enabled = next;
      suppressMouseUntil = 0;
    }
  };
  runtime.disposeCanvasWheel = () => {
    reset();
    for (const [names, listener] of groups)
      for (const name of names)
        window.removeEventListener(name, listener, true);
    for (const name of ["blur", "pagehide"])
      window.removeEventListener(name, reset);
    for (const name of ["focusin", "keydown"])
      window.removeEventListener(name, stopMomentum, true);
    document.removeEventListener("visibilitychange", visibility);
    delete runtime.ownsCanvasTouch;
    delete runtime.isCanvasPoint;
    delete runtime.canvasGestureDidMove;
    delete runtime.cancelCanvasContact;
    delete runtime.setTouchMode;
    delete runtime.setCanvasWheel;
    delete runtime.setTrackpadZoom;
    delete runtime.trackpadPinch;
    delete runtime.resetTrackpadPinch;
    delete runtime.setTrackpadPinchRoute;
    delete runtime.trackpadPinchStats;
    delete runtime.trackpadPinchGain;
    delete runtime.disposeCanvasWheel;
  };
}
