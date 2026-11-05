import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
import { build } from "esbuild";
const script = await readFile(
  new URL(
    "../../../apps/ios/Folio/Resources/Compat/canvas-wheel.js",
    import.meta.url,
  ),
  "utf8",
);
const shortcuts = await readFile(
  new URL(
    "../../../apps/ios/Folio/Resources/Compat/touch-shortcuts.js",
    import.meta.url,
  ),
  "utf8",
);
function harness(
  unsupported = false,
  initializerThrows = false,
  modifiers = false,
) {
  const listeners = new Map(),
    timers = new Map(),
    delivered = [];
  let now = 0,
    timerId = 0;
  class MouseEvent {
    constructor(type, init = {}) {
      Object.assign(this, init, { type, isTrusted: false });
    }
    stopImmediatePropagation() {
      this.stopped = true;
    }
    preventDefault() {
      this.defaultPrevented = true;
    }
  }
  class PointerEvent extends MouseEvent {}
  class WheelEvent extends MouseEvent {}
  class TouchEvent extends MouseEvent {}
  class KeyboardEvent extends MouseEvent {}
  class Element {
    isConnected = true;
  }
  class HTMLCanvasElement extends Element {
    isConnected = true;
    dispatchEvent(event) {
      delivered.push(event);
      listeners.get(event.type)?.(event);
      return !event.defaultPrevented;
    }
  }
  const canvas = new HTMLCanvasElement();
  const addListener = (name, fn) => {
    const previous = listeners.get(name);
    listeners.set(
      name,
      previous
        ? (event) => {
            previous(event);
            if (!event.stopped) fn(event);
          }
        : fn,
    );
  };
  const context = vm.createContext({
    __folio: {},
    PointerEvent,
    MouseEvent,
    WheelEvent,
    TouchEvent,
    KeyboardEvent,
    HTMLCanvasElement,
    Element,
    performance: { now: () => now },
    setTimeout(fn, delay) {
      const id = ++timerId;
      timers.set(id, { fn, at: now + delay });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    document: {
      activeElement: canvas,
      elementFromPoint: () => canvas,
      createEvent() {
        if (unsupported) throw new Error("NotSupportedError");
        return {
          isTrusted: false,
          initGestureEvent(...args) {
            if (initializerThrows) throw new Error("NotSupportedError");
            this.args = args;
            [
              this.type,
              this.bubbles,
              this.cancelable,
              this.view,
              this.detail,
              this.screenX,
              this.screenY,
              this.clientX,
              this.clientY,
              this.ctrlKey,
              this.altKey,
              this.shiftKey,
              this.metaKey,
              this.target,
              this.scale,
              this.rotation,
            ] = args;
          },
        };
      },
      addEventListener: addListener,
      removeEventListener: (n) => listeners.delete(n),
    },
    window: {
      addEventListener: addListener,
      removeEventListener: (n) => listeners.delete(n),
    },
  });
  if (modifiers) vm.runInContext(shortcuts, context);
  vm.runInContext(script, context);
  const send = (type, init = {}) => {
    const e = new PointerEvent(type, {
      target: canvas,
      pointerType: "touch",
      pointerId: 1,
      clientX: 10,
      clientY: 20,
      button: 0,
      buttons: type === "pointerup" ? 0 : 1,
      cancelable: true,
      ...init,
    });
    e.isTrusted = true;
    listeners.get(type)?.(e);
    return e;
  };
  const advance = (ms) => {
    now += ms;
    for (const [id, timer] of [...timers])
      if (timer.at <= now) {
        timers.delete(id);
        timer.fn();
      }
  };
  return {
    context,
    send,
    KeyboardEvent,
    WheelEvent,
    advance,
    delivered,
    listeners,
    timers,
    canvas,
    MouseEvent,
    TouchEvent,
  };
}
test("tap and double tap replay complete mouse sequences, raw events stay held", () => {
  const h = harness();
  assert.equal(h.send("pointerdown").stopped, true);
  assert.equal(h.delivered.length, 0);
  h.send("pointerup");
  assert.deepEqual(
    h.delivered.map((e) => e.type),
    ["pointerdown", "mousedown", "pointerup", "mouseup", "click"],
  );
  assert.ok(
    h.delivered.every((e) => !e.isTrusted && e.pointerType !== "touch"),
  );
  assert.equal(h.delivered.at(-1).buttons, 0);
  h.advance(100);
  h.send("pointerdown");
  h.send("pointerup");
  assert.equal(h.delivered.at(-1).type, "dblclick");
});
test("drag uses negated displacement and momentum cancels on next touch", () => {
  const h = harness();
  h.send("pointerdown");
  h.advance(16);
  h.send("pointermove", { clientX: 30, clientY: 50 });
  assert.equal(h.delivered[0].type, "wheel");
  assert.equal(h.delivered[0].deltaX, -20);
  assert.equal(h.delivered[0].deltaY, -30);
  assert.equal(h.delivered[0].ctrlKey, false);
  h.send("pointerup", { clientX: 30, clientY: 50 });
  h.advance(16);
  assert.equal(h.delivered.length, 2);
  h.send("pointerdown", { target: {} });
  h.advance(16);
  assert.equal(h.delivered.length, 2);
});
test("editing focus, keyboard input and mouse/pen down cancel canvas momentum", () => {
  for (const action of ["focusin", "keydown", "mouse", "pen"]) {
    const h = harness();
    h.send("pointerdown");
    h.advance(16);
    h.send("pointermove", { clientX: 30, clientY: 50 });
    h.send("pointerup", { clientX: 30, clientY: 50 });
    const count = h.delivered.length;
    if (action === "mouse" || action === "pen")
      h.send("pointerdown", { pointerType: action });
    else h.listeners.get(action)?.({ isTrusted: false });
    h.advance(32);
    assert.equal(h.delivered.length, count, action);
  }
});
test("second canvas contact drops held selection without a click", () => {
  const h = harness();
  h.send("pointerdown");
  assert.equal(h.send("pointerdown", { pointerId: 2 }).stopped, true);
  assert.equal(h.delivered.length, 0);
  h.send("pointerup");
  h.send("pointerup", { pointerId: 2 });
  assert.ok(!h.delivered.some((e) => e.type === "click" || e.type === "wheel"));
});
test("cancel, disable, background and disposal cancel pending or momentum", () => {
  for (const action of [
    "pointercancel",
    "disable",
    "blur",
    "pagehide",
    "dispose",
  ]) {
    const h = harness();
    h.send("pointerdown");
    if (action === "pointercancel") h.send(action);
    else if (action === "disable") h.context.__folio.setCanvasWheel(false);
    else if (action === "dispose") h.context.__folio.disposeCanvasWheel();
    else h.listeners.get(action)();
    h.send("pointerup");
    h.advance(600);
    assert.equal(h.delivered.length, 0);
  }
});
test("long press restores held down without click and mouse/pen/noncanvas are unaffected", () => {
  const h = harness();
  for (const init of [
    { pointerType: "pen" },
    { pointerType: "mouse" },
    { target: {} },
  ]) {
    assert.equal(h.send("pointerdown", init).stopped, undefined);
    h.send("pointerup", init);
  }
  h.send("pointerdown");
  h.advance(500);
  assert.equal(h.delivered[0].pointerType, "touch");
  assert.equal(h.send("pointerup").stopped, undefined);
  assert.equal(h.delivered.length, 1);
});
const total = (h) => h.delivered.reduce((sum, e) => sum + (e.deltaY ?? 0), 0);
const pinch = (h, phase, scale, x = 10, y = 20) =>
  h.context.__folio.trackpadPinch(phase, scale, x, y);
test("wheel cumulative updates are idempotent and keep the began anchor", () => {
  const h = harness(),
    coalesced = harness();
  pinch(h, "began", 1);
  pinch(h, "changed", 1.2, 50, 60);
  pinch(h, "changed", 1.5);
  pinch(h, "ended", 1.5);
  pinch(coalesced, "began", 1);
  pinch(coalesced, "ended", 1.5);
  assert.ok(Math.abs(total(h) + 400 * Math.log(1.5)) < 1e-9);
  assert.ok(Math.abs(total(h) - total(coalesced)) < 1e-9);
  assert.ok(
    h.delivered.every(
      (e) =>
        !e.isTrusted &&
        e.ctrlKey &&
        e.deltaMode === 0 &&
        e.deltaX === 0 &&
        e.clientX === 10 &&
        e.clientY === 20,
    ),
  );
});
test("large cumulative deltas use bounded chunks with exact totals in both directions", () => {
  for (const scale of [100, 0.01]) {
    const h = harness();
    pinch(h, "began", 1);
    pinch(h, "changed", scale);
    assert.ok(h.delivered.length > 1);
    assert.ok(
      h.delivered.every(
        (e) =>
          Math.abs(e.deltaY) <= 25 &&
          Math.sign(e.deltaY) === -Math.sign(Math.log(scale)),
      ),
    );
    assert.ok(Math.abs(total(h) + 400 * Math.log(scale)) < 1e-9);
  }
  const h = harness();
  pinch(h, "began", 1);
  pinch(h, "changed", 1);
  assert.equal(h.delivered.length, 0);
});
test("epsilon retains unapplied motion and invalid/out-of-order updates do nothing", () => {
  const h = harness();
  pinch(h, "changed", 2);
  pinch(h, "ended", 2);
  assert.equal(h.delivered.length, 0);
  pinch(h, "began", 1);
  pinch(h, "changed", 1.00001);
  assert.equal(h.delivered.length, 0);
  for (const scale of [0, -1, NaN, Infinity]) pinch(h, "changed", scale);
  pinch(h, "changed", 2, NaN);
  pinch(h, "ended", 2, 10, Infinity);
  pinch(h, "changed", 1.1);
  assert.ok(Math.abs(total(h) + 400 * Math.log(1.1)) < 1e-9);
  pinch(h, "began", 1);
  pinch(h, "ended", 1.1);
  assert.ok(Math.abs(total(h) + 800 * Math.log(1.1)) < 1e-9);
});
test("gesture route uses absolute scale and WebKit initGestureEvent arguments", () => {
  const h = harness();
  h.context.__folio.setTrackpadPinchRoute("gesture");
  for (const [phase, scale] of [
    ["began", 1],
    ["changed", 1.2],
    ["changed", 1.5],
    ["ended", 1.5],
  ])
    pinch(h, phase, scale);
  assert.deepEqual(
    h.delivered.map((e) => [e.type, e.scale]),
    [
      ["gesturestart", 1],
      ["gesturechange", 1.2],
      ["gesturechange", 1.5],
      ["gestureend", 1.5],
    ],
  );
  for (const e of h.delivered)
    assert.deepEqual(e.args, [
      e.type,
      true,
      true,
      h.context.window,
      0,
      10,
      20,
      10,
      20,
      false,
      false,
      false,
      false,
      h.canvas,
      e.scale,
      0,
    ]);
  assert.equal(h.context.__folio.trackpadPinchStats().dispatched, 4);
});
test("unsupported GestureEvent falls back to wheel with diagnostics", () => {
  const h = harness(true);
  h.context.__folio.setTrackpadPinchRoute("gesture");
  pinch(h, "began", 1);
  pinch(h, "ended", 1.5);
  assert.ok(Math.abs(total(h) + 400 * Math.log(1.5)) < 1e-9);
  const stats = h.context.__folio.trackpadPinchStats();
  assert.equal(stats.gestureSupported, false);
  assert.equal(stats.route, "wheel");
});
test("route changes apply only to the next gesture and count prevented events", () => {
  const h = harness();
  pinch(h, "began", 1);
  h.context.__folio.setTrackpadPinchRoute("gesture");
  pinch(h, "ended", 1.2);
  assert.ok(h.delivered.every((e) => e.type === "wheel"));
  const wheelCount = h.delivered.length;
  h.listeners.set("gesturechange", (e) => {
    e.defaultPrevented = true;
  });
  pinch(h, "began", 1);
  pinch(h, "ended", 1.2);
  assert.deepEqual(
    h.delivered.slice(wheelCount).map((e) => e.type),
    ["gesturestart", "gesturechange", "gestureend"],
  );
  assert.equal(h.context.__folio.trackpadPinchStats().prevented, 1);
});
test("pinch lifecycle ends gesture route and drops wheel route updates", () => {
  for (const route of ["wheel", "gesture"])
    for (const action of ["disable", "blur", "pagehide", "hidden", "dispose"]) {
      const h = harness();
      h.context.__folio.setTrackpadPinchRoute(route);
      pinch(h, "began", 1);
      pinch(h, "changed", 1.2);
      if (action === "disable") h.context.__folio.setCanvasWheel(false);
      else if (action === "dispose") h.context.__folio.disposeCanvasWheel();
      else if (action === "hidden") {
        h.context.document.hidden = true;
        h.listeners.get("visibilitychange")();
      } else h.listeners.get(action)();
      const count = h.delivered.length;
      h.context.__folio.trackpadPinch?.("changed", 2, 10, 20);
      assert.equal(h.delivered.length, count);
      if (route === "gesture")
        assert.equal(h.delivered.at(-1).type, "gestureend");
      if (action === "dispose")
        for (const key of [
          "trackpadPinch",
          "setTrackpadPinchRoute",
          "trackpadPinchStats",
        ])
          assert.equal(h.context.__folio[key], undefined);
    }
});
test("detached target is re-resolved or silently dropped", () => {
  const h = harness();
  pinch(h, "began", 1);
  h.canvas.isConnected = false;
  let resolved = 0;
  const replacement = {
    isConnected: true,
    dispatchEvent: (e) => {
      resolved++;
      h.delivered.push(e);
      return true;
    },
  };
  h.context.document.elementFromPoint = () => replacement;
  pinch(h, "changed", 1.2);
  assert.ok(resolved > 0);
  assert.ok(h.delivered.every((e) => Math.abs(e.deltaY) <= 25));
  const deliveredCount = resolved;
  replacement.isConnected = false;
  h.context.document.elementFromPoint = () => null;
  pinch(h, "changed", 1.5);
  pinch(h, "ended", 2);
  assert.equal(resolved, deliveredCount);
});

test("touch compatibility mouse events are suppressed, real mouse movement clears the guard", () => {
  const h = harness();
  h.send("pointerdown");
  h.send("pointerup");
  const compatibility = new h.MouseEvent("click", {
    target: h.canvas,
    cancelable: true,
  });
  compatibility.isTrusted = true;
  h.listeners.get("click")(compatibility);
  assert.equal(compatibility.stopped, true);
  h.send("pointermove", { pointerType: "mouse" });
  const real = new h.MouseEvent("mousemove", { target: h.canvas });
  real.isTrusted = true;
  h.listeners.get("mousemove")(real);
  assert.equal(real.stopped, undefined);
});

test("pure pinch mapping and delta splitting reject invalid inputs", async () => {
  const result = await build({
    entryPoints: [new URL("../src/canvas-wheel.ts", import.meta.url).pathname],
    bundle: true,
    format: "iife",
    globalName: "mapping",
    write: false,
  });
  const context = vm.createContext({});
  vm.runInContext(result.outputFiles[0].text, context);
  const { splitDelta, scaleToDelta } = context.mapping;
  for (const dy of [0, NaN, Infinity, -Infinity])
    assert.equal(splitDelta(dy).length, 0);
  for (const ratio of [0, -1, NaN, Infinity])
    assert.equal(scaleToDelta(ratio), 0);
  for (const dy of [25, -25, 25.01, -76.123, 1000]) {
    const chunks = splitDelta(dy);
    assert.ok(
      chunks.every((v) => Math.abs(v) <= 25 && Math.sign(v) === Math.sign(dy)),
    );
    assert.ok(Math.abs(chunks.reduce((sum, v) => sum + v, 0) - dy) < 1e-9);
  }
});
test("native switch reset ends an active pinch and ignores further updates", () => {
  const h = harness();
  h.context.__folio.setTrackpadPinchRoute("gesture");
  pinch(h, "began", 1);
  pinch(h, "changed", 1.2);
  h.context.__folio.resetTrackpadPinch();
  assert.equal(h.delivered.at(-1).type, "gestureend");
  const count = h.delivered.length;
  pinch(h, "changed", 2);
  assert.equal(h.delivered.length, count);
});

test("throwing GestureEvent initializer cannot select gesture route", () => {
  const h = harness(false, true);
  h.context.__folio.setTrackpadPinchRoute("gesture");
  pinch(h, "began", 1);
  pinch(h, "ended", 1.5);
  assert.equal(h.context.__folio.trackpadPinchStats().route, "wheel");
  assert.ok(Math.abs(total(h) + 400 * Math.log(1.5)) < 1e-9);
});

test("out and back cancels wheel totals, hold and release add no tail", () => {
  const h = harness();
  pinch(h, "began", 1, 40, 80);
  pinch(h, "changed", 1.6, 0, 0);
  const count = h.delivered.length;
  h.advance(1000);
  pinch(h, "changed", 1.6);
  assert.equal(h.delivered.length, count);
  pinch(h, "ended", 1);
  assert.ok(Math.abs(total(h)) < 1e-9);
  const released = h.delivered.length;
  pinch(h, "changed", 2);
  h.advance(1200);
  assert.equal(h.delivered.length, released);
  assert.ok(h.delivered.every((e) => e.clientX === 40 && e.clientY === 80));
});

test("ordinary trusted scroll is observed without synthetic duplication", () => {
  const h = harness();
  const event = new h.MouseEvent("wheel", { deltaY: 20, ctrlKey: false });
  event.isTrusted = true;
  h.listeners.get("wheel")?.(event);
  assert.equal(event.stopped, undefined);
  assert.equal(event.defaultPrevented, undefined);
  assert.equal(h.delivered.length, 0);
});

test("real trace observer bounds records, preserves trusted metadata and reads numeric zoom only", async () => {
  const source = await readFile(
    new URL(
      "../../../apps/ios/Folio/Input/PinchReplayHarness.swift",
      import.meta.url,
    ),
    "utf8",
  );
  const observer = source.match(/static let observer = #"""([\s\S]*?)"""#/)[1];
  const listeners = new Map();
  let tick,
    now = 0;
  const context = vm.createContext({
    performance: { now: () => now },
    requestAnimationFrame: (fn) => {
      tick = fn;
      return 1;
    },
    cancelAnimationFrame: () => {},
    document: {
      createEvent: () => {
        throw new Error("unsupported");
      },
      querySelectorAll: () => [
        { getAttribute: () => "zoom", textContent: "100001%" },
        { getAttribute: () => "zoom", textContent: "42%" },
      ],
    },
    window: {
      addEventListener: (name, fn) => listeners.set(name, fn),
      removeEventListener: (name) => listeners.delete(name),
    },
  });
  vm.runInContext(observer, context);
  context.__folioPinchProbe.start();
  for (let index = 0; index < 4200; index++) {
    now++;
    tick();
    listeners.get("wheel")({
      type: "wheel",
      isTrusted: true,
      ctrlKey: true,
      deltaY: Infinity,
      scale: NaN,
      text: "private",
    });
  }
  const result = JSON.parse(context.__folioPinchProbe.finish());
  assert.equal(result.samples.length, 4096);
  assert.equal(result.events.length, 4096);
  assert.ok(result.dropped > 0);
  assert.equal(result.samples[0].zoom, 42);
  assert.deepEqual(Object.keys(result.events[0]), [
    "t",
    "type",
    "trusted",
    "dy",
    "scale",
  ]);
  assert.equal(result.events[0].trusted, true);
  assert.equal(result.events[0].dy, null);
  assert.equal(result.events[0].scale, null);
  context.__folioPinchProbe.dispose();
  assert.equal(listeners.size, 0);
});

test("GestureEvent construction failing after begin falls back without losing final input", () => {
  const h = harness();
  h.context.__folio.setTrackpadPinchRoute("gesture");
  pinch(h, "began", 1);
  h.context.document.createEvent = () => {
    throw new Error("unsupported");
  };
  pinch(h, "ended", 1.5);
  assert.equal(h.context.__folio.trackpadPinchStats().route, "wheel");
  assert.ok(Math.abs(total(h) + 400 * Math.log(1.5)) < 1e-9);
  const count = h.delivered.length;
  pinch(h, "changed", 2);
  assert.equal(h.delivered.length, count);
});

test("pinch outside the canvas or below the start threshold dispatches nothing", () => {
  const h = harness();
  h.context.document.elementFromPoint = () => ({ isConnected: true });
  pinch(h, "began", 1);
  pinch(h, "changed", 2);
  pinch(h, "ended", 2);
  assert.equal(h.delivered.length, 0);
  h.context.document.elementFromPoint = () => h.canvas;
  pinch(h, "began", 1);
  pinch(h, "changed", 1.01);
  assert.equal(h.delivered.length, 0);
  pinch(h, "changed", 1.05);
  assert.ok(Math.abs(total(h) + 400 * Math.log(1.05)) < 1e-9);
  h.context.__folio.setTrackpadZoom(false);
  pinch(h, "began", 1);
  pinch(h, "changed", 2);
  assert.ok(Math.abs(total(h) + 400 * Math.log(1.05)) < 1e-9);
});
test("Ctrl+scroll over the canvas replays the wheel with ctrlKey only", () => {
  const h = harness();
  const key = (type, init) => {
    const e = new h.KeyboardEvent(type, init);
    e.isTrusted = true;
    h.listeners.get(type)?.(e);
  };
  const wheel = (target) => {
    const e = new h.WheelEvent("wheel", {
      target,
      deltaY: 6,
      clientX: 5,
      clientY: 6,
      cancelable: true,
    });
    e.isTrusted = true;
    h.listeners.get("wheel")?.(e);
    return e;
  };
  assert.equal(wheel(h.canvas).stopped, undefined);
  key("keyup", { key: "a", ctrlKey: true });
  const sidebar = wheel({});
  assert.equal(sidebar.stopped, undefined);
  assert.equal(h.delivered.length, 0);
  const canvas = wheel(h.canvas);
  assert.equal(canvas.stopped, true);
  assert.equal(canvas.defaultPrevented, true);
  assert.equal(h.delivered.length, 1);
  assert.equal(h.delivered[0].ctrlKey, true);
  assert.equal(h.delivered[0].deltaY, 6);
  key("keyup", { key: "Control", ctrlKey: false });
  assert.equal(wheel(h.canvas).stopped, undefined);
});

test("Touch Only defers mouse down until slop or 120 ms, retaining the real pointer ID", () => {
  const h = harness();
  h.context.__folio.setTouchMode("touch-only");
  const down = h.send("pointerdown", { pointerId: 42, shiftKey: true });
  assert.equal(down.defaultPrevented, true);
  h.send("pointermove", { pointerId: 42, clientX: 15 });
  h.advance(119);
  assert.equal(h.delivered.length, 0);
  h.advance(1);
  assert.deepEqual(
    h.delivered.map((e) => e.type),
    ["pointerdown", "mousedown"],
  );
  assert.equal(h.delivered[0].pointerId, 42);
  assert.equal(h.delivered[0].pointerType, "mouse");
  assert.equal(h.delivered[0].shiftKey, true);
  h.send("pointermove", { pointerId: 42, clientX: 30 });
  h.send("pointerup", { pointerId: 42, clientX: 30 });
  assert.deepEqual(
    h.delivered.map((e) => e.type),
    [
      "pointerdown",
      "mousedown",
      "pointermove",
      "mousemove",
      "pointerup",
      "mouseup",
    ],
  );
  assert.ok(!h.delivered.some((e) => e.type === "wheel" || e.type === "click"));
});

test("Touch Only taps click; mode switches and long presses cancel without clicking", () => {
  const h = harness();
  h.context.__folio.setTouchMode("touch-only");
  h.send("pointerdown");
  h.send("pointerup");
  assert.equal(h.delivered.at(-1).type, "click");
  for (const cancel of [
    () => h.context.__folio.setTouchMode("pencil-and-touch"),
    () => h.context.__folio.cancelCanvasContact(),
  ]) {
    h.context.__folio.setTouchMode("touch-only");
    h.delivered.length = 0;
    h.send("pointerdown");
    h.advance(120);
    cancel();
    h.send("pointerup");
    assert.deepEqual(
      h.delivered.map((e) => e.type),
      ["pointerdown", "mousedown", "pointerup", "mouseup"],
    );
  }
});

function fingers(h, type, points) {
  const event = new h.TouchEvent(type, {
    target: h.canvas,
    cancelable: true,
    touches: points.map(([clientX, clientY]) => ({ clientX, clientY })),
  });
  event.isTrusted = true;
  h.listeners.get(type)(event);
  return event;
}

test("both modes pan and pinch with two fingers, suppress a remaining finger and three-finger motion", () => {
  for (const mode of ["pencil-and-touch", "touch-only"]) {
    const h = harness();
    h.context.__folio.setTouchMode(mode);
    h.send("pointerdown");
    h.send("pointerdown", { pointerId: 2 });
    fingers(h, "touchstart", [
      [0, 20],
      [40, 20],
    ]);
    h.delivered.length = 0;
    assert.equal(
      fingers(h, "touchmove", [
        [10, 30],
        [50, 30],
      ]).defaultPrevented,
      true,
    );
    assert.equal(h.delivered.length, 1);
    assert.equal(h.delivered[0].deltaX, -10);
    assert.equal(h.delivered[0].deltaY, -10);
    // Pan and zoom are anchored at the current finger centroid, like a native pinch.
    assert.equal(h.delivered[0].clientX, 30);
    assert.equal(h.delivered[0].clientY, 30);
    fingers(h, "touchmove", [
      [0, 30],
      [60, 30],
    ]);
    assert.equal(h.context.__folio.canvasGestureDidMove(), true);
    const zoom = h.delivered
      .filter((e) => e.ctrlKey)
      .reduce((sum, e) => sum + e.deltaY, 0);
    assert.ok(Math.abs(zoom + 400 * Math.log(1.5)) < 1e-9);
    const count = h.delivered.length;
    fingers(h, "touchstart", [
      [0, 30],
      [60, 30],
      [90, 30],
    ]);
    fingers(h, "touchmove", [
      [0, 40],
      [60, 40],
      [90, 40],
    ]);
    fingers(h, "touchend", [[0, 40]]);
    h.send("pointermove", { clientY: 60 });
    assert.equal(h.delivered.length, count);
    fingers(h, "touchend", []);
    h.advance(1000);
    assert.equal(h.delivered.length, count);
  }
});

test("touch pinch reversal keeps ctrl-wheel through the start distance in both modes", () => {
  for (const mode of ["pencil-and-touch", "touch-only"]) {
    const h = harness();
    h.context.__folio.setTouchMode(mode);
    const move = (distance, x = 20, y = 20) =>
      fingers(h, "touchmove", [
        [x - distance / 2, y],
        [x + distance / 2, y],
      ]);
    fingers(h, "touchstart", [
      [0, 20],
      [40, 20],
    ]);
    // Incidental centroid movement arms pan before the pinch reverses.
    move(60, 30, 30);
    h.delivered.length = 0;
    for (const [distance, sign] of [
      [59.5, 1],
      [40.2, 1],
      [39.8, 1],
      [40, -1],
      [60, -1],
    ]) {
      const before = h.delivered.length;
      move(distance, 30, 30);
      const events = h.delivered.slice(before);
      assert.ok(events.length > 0);
      assert.ok(events.every((e) => e.ctrlKey && Math.sign(e.deltaY) === sign));
    }
    fingers(h, "touchend", []);
    h.delivered.length = 0;
    fingers(h, "touchstart", [
      [0, 20],
      [40, 20],
    ]);
    move(40.5);
    assert.equal(h.delivered.length, 0);
  }
});

test("pan-only touch motion stays pan in both modes", () => {
  for (const mode of ["pencil-and-touch", "touch-only"]) {
    const h = harness();
    h.context.__folio.setTouchMode(mode);
    fingers(h, "touchstart", [
      [0, 20],
      [40, 20],
    ]);
    for (const x of [10, 20, 10])
      fingers(h, "touchmove", [
        [x, 30],
        [x + 40, 30],
      ]);
    assert.equal(h.delivered.length, 3);
    assert.ok(h.delivered.every((e) => !e.ctrlKey));
  }
});

test("touch pinch reversals preserve simultaneous centroid pan in both modes", () => {
  for (const mode of ["pencil-and-touch", "touch-only"]) {
    const h = harness();
    h.context.__folio.setTouchMode(mode);
    fingers(h, "touchstart", [
      [0, 20],
      [40, 20],
    ]);
    for (const [distance, x, sign] of [
      [60, 30, -1],
      [59, 32, 1],
      [61, 34, -1],
    ]) {
      h.delivered.length = 0;
      fingers(h, "touchmove", [
        [x - distance / 2, 30],
        [x + distance / 2, 30],
      ]);
      assert.ok(h.delivered.some((e) => !e.ctrlKey && e.deltaX < 0));
      assert.ok(
        h.delivered.some((e) => e.ctrlKey && Math.sign(e.deltaY) === sign),
      );
      assert.ok(h.delivered.every((e) => e.clientX === x && e.clientY === 30));
    }
  }
});

test("trackpad reversal stays zoom below the start threshold until lift", () => {
  const h = harness();
  pinch(h, "began", 1);
  for (const [scale, sign] of [
    [1.5, -1],
    [1.49, 1],
    [1.01, 1],
    [0.99, 1],
    [1, -1],
    [1.5, -1],
  ]) {
    h.delivered.length = 0;
    pinch(h, "changed", scale);
    assert.ok(h.delivered.length > 0);
    assert.ok(
      h.delivered.every((e) => e.ctrlKey && Math.sign(e.deltaY) === sign),
    );
  }
  pinch(h, "ended", 1.5);
  h.delivered.length = 0;
  pinch(h, "began", 1);
  pinch(h, "changed", 1.01);
  assert.equal(h.delivered.length, 0);
});

test("two-finger taps and pinch jitter dispatch no wheel; sidebar touches stay native", () => {
  const h = harness();
  fingers(h, "touchstart", [
    [0, 0],
    [40, 0],
  ]);
  fingers(h, "touchmove", [
    [0, 0],
    [40.5, 0],
  ]);
  fingers(h, "touchend", []);
  assert.equal(h.delivered.length, 0);
  assert.equal(h.context.__folio.canvasGestureDidMove(), false);
  h.context.document.elementFromPoint = () => ({});
  assert.equal(
    fingers(h, "touchstart", [
      [0, 0],
      [40, 0],
    ]).stopped,
    undefined,
  );
});

test("Touch Only moves and cancellation use the captured element and release capture", () => {
  const h = harness();
  h.context.__folio.setTouchMode("touch-only");
  h.send("pointerdown", { pointerId: 42 });
  h.advance(120);
  const captured = new h.context.Element();
  const events = [];
  captured.dispatchEvent = (e) => {
    events.push(e);
    return true;
  };
  captured.hasPointerCapture = (id) => id === 42;
  captured.releasePointerCapture = (id) =>
    events.push({ type: "release", pointerId: id });
  h.send("gotpointercapture", { target: captured, pointerId: 42 });
  h.send("pointermove", { pointerId: 42, clientX: 90 });
  h.context.__folio.setTouchMode("pencil-and-touch");
  assert.deepEqual(
    events.map((e) => e.type),
    ["pointermove", "mousemove", "pointerup", "mouseup", "release"],
  );
  assert.equal(events.at(-1).pointerId, 42);
});

test("Touch Only second/third contacts before the delay emit no pointer or mouse sequence", () => {
  for (const count of [2, 3]) {
    const h = harness();
    h.context.__folio.setTouchMode("touch-only");
    h.send("pointerdown");
    h.advance(50);
    for (let id = 2; id <= count; id++)
      h.send("pointerdown", { pointerId: id });
    h.advance(150);
    for (let id = 1; id <= count; id++) h.send("pointerup", { pointerId: id });
    fingers(h, "touchend", []);
    assert.equal(h.delivered.length, 0);
    assert.equal(h.context.__folio.canvasGestureDidMove(), false);
    h.send("pointerdown");
    h.send("pointerup");
    assert.equal(h.delivered.at(-1).type, "click");
  }
});

test("Touch Only slop starts at down; late second finger closes at down then pans without clicks", () => {
  const h = harness();
  h.context.__folio.setTouchMode("touch-only");
  h.send("pointerdown");
  h.send("pointermove", { clientX: 30, clientY: 40 });
  assert.deepEqual(
    h.delivered.map((e) => e.type),
    ["pointerdown", "mousedown", "pointermove", "mousemove"],
  );
  assert.equal(h.delivered[0].clientX, 10);
  h.send("pointerdown", { pointerId: 2, clientX: 60 });
  assert.deepEqual(
    h.delivered.slice(-2).map((e) => [e.type, e.clientX, e.clientY, e.buttons]),
    [
      ["pointerup", 10, 20, 0],
      ["mouseup", 10, 20, 0],
    ],
  );
  fingers(h, "touchstart", [
    [30, 40],
    [60, 40],
  ]);
  fingers(h, "touchmove", [
    [40, 50],
    [70, 50],
  ]);
  assert.equal(h.delivered.at(-1).type, "wheel");
  const count = h.delivered.length;
  h.send("pointerup");
  fingers(h, "touchend", [[70, 50]]);
  h.send("pointermove", { pointerId: 2, clientX: 90 });
  h.send("pointerup", { pointerId: 2 });
  fingers(h, "touchend", []);
  h.advance(1000);
  assert.equal(h.delivered.length, count);
  assert.ok(!h.delivered.some((e) => e.type === "click"));
});

test("Touch Only pending and started contacts terminate on every cancellation path", () => {
  for (const started of [false, true])
    for (const action of [
      "pointercancel",
      "touchcancel",
      "blur",
      "pagehide",
      "hidden",
      "tab",
      "mode",
      "disable",
      "dispose",
      "new-touch",
      "pen",
    ]) {
      const h = harness();
      h.context.__folio.setTouchMode("touch-only");
      h.send("pointerdown");
      if (started) h.send("pointermove", { clientX: 50 });
      if (action === "tab") h.context.__folio.cancelCanvasContact();
      else if (action === "mode")
        h.context.__folio.setTouchMode("pencil-and-touch");
      else if (action === "disable") h.context.__folio.setCanvasWheel(false);
      else if (action === "dispose") h.context.__folio.disposeCanvasWheel();
      else if (action === "hidden") {
        h.context.document.hidden = true;
        h.listeners.get("visibilitychange")();
      } else if (action === "touchcancel") fingers(h, action, []);
      else if (action === "new-touch") h.send("pointerdown", { pointerId: 2 });
      else if (action === "pen") h.send("pointerdown", { pointerType: "pen" });
      else if (action === "pointercancel") h.send(action);
      else h.listeners.get(action)();
      h.advance(200);
      assert.equal(
        h.delivered.filter((e) => e.type === "pointerdown").length,
        started ? 1 : 0,
        action,
      );
      assert.equal(
        h.delivered.filter((e) => e.type === "pointerup").length,
        started ? 1 : 0,
        action,
      );
      if (started) assert.equal(h.delivered.at(-1).clientX, 10, action);
      assert.ok(!h.delivered.some((e) => e.type === "click"), action);
    }
});

test("Touch Only touchend fallback completes taps/drags once without pointerup", () => {
  for (const started of [false, true]) {
    const h = harness();
    h.context.__folio.setTouchMode("touch-only");
    h.send("pointerdown");
    if (started) h.send("pointermove", { clientX: 50 });
    fingers(h, "touchend", []);
    h.send("pointerup");
    h.advance(200);
    assert.equal(h.delivered.filter((e) => e.type === "pointerdown").length, 1);
    assert.equal(h.delivered.filter((e) => e.type === "pointerup").length, 1);
    assert.equal(
      h.delivered.filter((e) => e.type === "click").length,
      started ? 0 : 1,
    );
  }
});

test("Touch Only TouchEvent multi-contact fallback cancels pending/started mouse sequence", () => {
  for (const started of [false, true]) {
    const h = harness();
    h.context.__folio.setTouchMode("touch-only");
    h.send("pointerdown");
    if (started) h.send("pointermove", { clientX: 50 });
    fingers(h, "touchstart", [
      [50, 20],
      [80, 20],
    ]);
    h.advance(200);
    assert.equal(
      h.delivered.filter((e) => e.type === "pointerdown").length,
      started ? 1 : 0,
    );
    assert.equal(
      h.delivered.filter((e) => e.type === "pointerup").length,
      started ? 1 : 0,
    );
    fingers(h, "touchend", []);
    assert.ok(!h.delivered.some((e) => e.type === "click"));
  }
});

test("Touch Only latched modifiers use canvas delay/handoff and consume only completed edits", () => {
  const h = harness(false, false, true);
  h.context.__folio.setTouchMode("touch-only");
  h.context.__folio.setTouchShortcutModifiers(1);
  h.delivered.length = 0;
  h.send("pointerdown");
  h.send("pointerdown", { pointerId: 2 });
  h.advance(150);
  assert.equal(h.delivered.length, 0);
  h.send("pointerup");
  h.send("pointerup", { pointerId: 2 });
  fingers(h, "touchend", []);
  assert.equal(h.context.__folio.touchShortcutFlags().shiftKey, true);
  h.send("pointerdown");
  h.send("pointermove", { clientX: 40 });
  assert.equal(h.delivered[0].shiftKey, true);
  h.send("pointerup", { clientX: 40 });
  assert.equal(h.delivered.find((e) => e.type === "mouseup").shiftKey, true);
  assert.equal(h.context.__folio.touchShortcutFlags().shiftKey, false);
  h.context.__folio.setTouchShortcutModifiers(2);
  h.delivered.length = 0;
  h.send("pointerdown");
  h.send("pointerup");
  assert.equal(h.delivered.find((e) => e.type === "click").shiftKey, true);
  assert.equal(h.context.__folio.touchShortcutFlags().shiftKey, true);
});

test("canvas containers qualify, covering UI and mixed sidebar contacts stay native", () => {
  const h = harness();
  h.canvas.getBoundingClientRect = () => ({
    left: 0,
    top: 0,
    right: 100,
    bottom: 100,
  });
  const container = new h.context.Element();
  container.children = [h.canvas];
  h.context.document.elementFromPoint = () => container;
  assert.equal(h.context.__folio.isCanvasPoint(10, 20), true);
  assert.equal(h.context.__folio.isCanvasPoint(101, 20), false);
  h.context.document.elementFromPoint = () => h.canvas;
  h.send("pointerdown");
  const sidebar = {};
  h.context.document.elementFromPoint = () => sidebar;
  for (const type of ["pointerdown", "pointermove", "pointerup"]) {
    const event = h.send(type, { target: sidebar, pointerId: 2 });
    assert.equal(event.stopped, undefined);
    assert.equal(event.defaultPrevented, undefined);
  }
  assert.equal(h.context.__folio.isCanvasPoint(10, 20), false);
});
