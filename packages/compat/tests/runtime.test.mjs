import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const scripts = await Promise.all(
  ["bridge", "diagnostics", "input-log"].map((name) =>
    readFile(
      new URL(
        `../../../apps/ios/Folio/Resources/Compat/${name}.js`,
        import.meta.url,
      ),
      "utf8",
    ),
  ),
);
function harness() {
  const messages = [];
  const registered = new Map();
  const listeners = {
    get: (name) => (event) => {
      for (const fn of registered.get(name) ?? []) fn(event);
    },
    get size() {
      return registered.size;
    },
  };
  class MouseEvent {}
  class KeyboardEvent {
    constructor(key, flags = {}) {
      Object.assign(this, { type: "keydown", key, isTrusted: true, ...flags });
    }
  }
  class WheelEvent extends MouseEvent {}
  const context = vm.createContext({
    navigator: { userAgent: "Unchanged UA", maxTouchPoints: 5 },
    devicePixelRatio: 2,
    innerWidth: 1024,
    innerHeight: 768,
    document: {
      hasFocus: () => true,
      createElement: () => ({ getContext: () => null }),
    },
    matchMedia: () => ({ matches: false }),
    MouseEvent,
    KeyboardEvent,
    WheelEvent,
    InputEvent: class {},
    HTMLInputElement: class {},
    HTMLElement: class {},
    performance: { now: () => 42 },
    queueMicrotask,
    setTimeout,
    clearTimeout,
    webkit: {
      messageHandlers: {
        folio: { postMessage: (message) => messages.push(message) },
      },
    },
    window: {
      addEventListener(name, listener, options) {
        assert.deepEqual({ ...options }, { capture: true, passive: true });
        if (!registered.has(name)) registered.set(name, new Set());
        registered.get(name).add(listener);
      },
      removeEventListener(name, listener, capture) {
        assert.equal(capture, true);
        assert.ok(registered.get(name).delete(listener));
        if (!registered.get(name).size) registered.delete(name);
      },
    },
  });
  for (const script of scripts) vm.runInContext(script, context);
  return { context, messages, listeners, KeyboardEvent };
}

test("input is opt-in, keys are redacted before bridge delivery, disposal removes listeners", () => {
  const { context, messages, listeners, KeyboardEvent } = harness();
  assert.equal(listeners.size, 0);
  context.__folio.setInputLogging(true);
  for (const key of ["a", "😀", "private composing text", "Enter"]) {
    listeners.get("keydown")(new KeyboardEvent(key));
  }
  assert.deepEqual(
    messages
      .filter((m) => m.name === "folioInputLog")
      .map((m) => m.payload.key),
    ["<char>", "<char>", "<char>", "Enter"],
  );
  assert.equal(
    JSON.stringify(messages).includes("private composing text"),
    false,
  );
  context.__folio.dispose();
  assert.equal(listeners.size, 0);
  assert.equal(context.__folio, undefined);
});

test("capture preserves UA, coalesces overlap, bounds adapter text, and stops after disposal", async () => {
  const { context, messages } = harness();
  let resolveAdapter;
  let requests = 0;
  context.navigator.gpu = {
    requestAdapter: () => {
      requests++;
      return new Promise((resolve) => {
        resolveAdapter = resolve;
      });
    },
  };
  const capture = context.__folio.capture;
  const pending = capture();
  await capture();
  assert.equal(requests, 1);
  resolveAdapter({
    info: {
      vendor: "v".repeat(256),
      architecture: "a".repeat(256),
      device: "d".repeat(256),
      description: "x".repeat(256),
    },
  });
  await pending;
  assert.equal(messages.length, 1);
  assert.equal(messages[0].payload.userAgent, "Unchanged UA");
  assert.equal(messages[0].payload.adapterInfo.length, 1024);
  assert.equal(messages[0].payload.adapterResult, "available");
  const disposed = capture();
  context.__folio.dispose();
  resolveAdapter(null);
  await disposed;
  await capture();
  assert.equal(messages.length, 1);
  assert.equal(requests, 2);
});

test("fixed shortcuts are labelled while arbitrary printable keys stay redacted", () => {
  const { context, messages, listeners, KeyboardEvent } = harness();
  context.__folio.setInputLogging(true);
  for (const [key, flags] of [
    ["c", { metaKey: true }],
    ["v", { metaKey: true }],
    ["z", { metaKey: true }],
    ["z", { metaKey: true, shiftKey: true }],
    ["d", { metaKey: true }],
    [" ", {}],
    ["x", { metaKey: true }],
    ["constructor", { metaKey: true }],
    ["__proto__", { metaKey: true }],
  ]) {
    listeners.get("keydown")(new KeyboardEvent(key, flags));
  }
  assert.deepEqual(
    messages
      .filter((m) => m.name === "folioInputLog")
      .map((m) => m.payload.key),
    [
      "Cmd+C",
      "Cmd+V",
      "Cmd+Z",
      "Cmd+Shift+Z",
      "Cmd+D",
      "Space",
      "<char>",
      "<char>",
      "<char>",
    ],
  );
  assert.ok(
    messages
      .filter((m) => m.name === "folioInputLog")
      .every((m) => m.payload.coalesced === 0),
  );
});

test("capture includes only fixed pinch route and counters when available", async () => {
  const { context, messages } = harness();
  const stats = {
    route: "wheel",
    dispatched: 4,
    prevented: 2,
    gestureSupported: false,
  };
  context.__folio.trackpadPinchStats = () => stats;
  await context.__folio.capture();
  assert.deepEqual(messages[0].payload.trackpadPinch, stats);
});

test("Pencil command transport sends complete standard chords to the focused editor", async () => {
  const events = [];
  const target = {
    dispatchEvent: (event) => {
      events.push(event);
      return true;
    },
  };
  class KeyboardEvent {
    constructor(type, init) {
      Object.assign(this, { type }, init);
    }
  }
  const script = await readFile(
    new URL(
      "../../../apps/ios/Folio/Resources/Compat/touch-shortcuts.js",
      import.meta.url,
    ),
    "utf8",
  );
  const context = vm.createContext({
    __folio: {},
    KeyboardEvent,
    document: {
      activeElement: target,
      addEventListener() {},
      removeEventListener() {},
    },
    window: { addEventListener() {}, removeEventListener() {} },
  });
  vm.runInContext(script, context);
  for (const [action, key, code, meta, shift, alt] of [
    ["undo", "z", "KeyZ", true, false, false],
    ["redo", "z", "KeyZ", true, true, false],
    ["toggleDevMode", "d", "KeyD", false, true, false],
    ["toggleUI", "\\", "Backslash", true, false, false],
    ["minimizeUI", "\\", "Backslash", true, true, false],
    ["arrow", "l", "KeyL", false, true, false],
    ["pencil", "p", "KeyP", false, true, false],
    ["section", "s", "KeyS", false, true, false],
    ["delete", "Backspace", "Backspace", false, false, false],
    ["frameSelection", "g", "KeyG", true, false, true],
    ["actions", "k", "KeyK", true, false, false],
    ["placeImage", "k", "KeyK", true, true, false],
    ["measurement", "m", "KeyM", false, true, false],
    ["annotation", "t", "KeyT", false, true, false],
    ...[
      ["move", "v"],
      ["frame", "f"],
      ["rectangle", "r"],
      ["ellipse", "o"],
      ["line", "l"],
      ["pen", "p"],
      ["text", "t"],
      ["hand", "h"],
      ["comment", "c"],
      ["slice", "s"],
      ["scale", "k"],
    ].map(([action, key]) => [
      action,
      key,
      `Key${key.toUpperCase()}`,
      false,
      false,
      false,
    ]),
  ]) {
    events.length = 0;
    context.__folio.touchShortcutKey(action);
    assert.deepEqual(
      events.map((e) => [
        e.type,
        e.key,
        e.code,
        e.metaKey,
        e.shiftKey,
        e.altKey,
        e.ctrlKey,
      ]),
      [
        ["keydown", key, code, meta, shift, alt, false],
        ["keyup", key, code, meta, shift, alt, false],
      ],
    );
  }
  context.__folio.disposeTouchShortcuts();
  assert.equal(context.__folio.touchShortcutKey, undefined);
});

test("latched modifiers preserve native Tab and IME keys while replaying canvas shortcuts", async () => {
  const events = [];
  const listeners = new Map();
  const target = {
    dispatchEvent(event) {
      events.push(event);
      return true;
    },
  };
  class KeyboardEvent {
    constructor(type, init) {
      Object.assign(this, { type, target, cancelable: true }, init);
      this.prevented = false;
      this.stopped = false;
    }
    preventDefault() {
      this.prevented = true;
    }
    stopImmediatePropagation() {
      this.stopped = true;
    }
  }
  const script = await readFile(
    new URL(
      "../../../apps/ios/Folio/Resources/Compat/touch-shortcuts.js",
      import.meta.url,
    ),
    "utf8",
  );
  const context = vm.createContext({
    __folio: {},
    KeyboardEvent,
    document: {
      activeElement: target,
      addEventListener() {},
      removeEventListener() {},
    },
    window: {
      addEventListener(name, listener) {
        listeners.set(name, listener);
      },
      removeEventListener(name) {
        listeners.delete(name);
      },
    },
  });
  vm.runInContext(script, context);
  context.__folio.setTouchShortcutModifiers(32); // Locked Command.
  events.length = 0;
  const send = (type, init) => {
    const event = new KeyboardEvent(type, {
      isTrusted: true,
      key: "Enter",
      ...init,
    });
    listeners.get(type)(event);
    return event;
  };
  // Native form traversal needs the original trusted event. Synthetic Tab cannot
  // replace its default action, even when Folio has a one-shot/locked modifier.
  for (const mask of [0, 1, 2, 4, 8, 16, 32, 64, 128, 170]) {
    context.__folio.setTouchShortcutModifiers(mask);
    events.length = 0;
    for (const flags of [{}, { shiftKey: true }, { ctrlKey: true }]) {
      for (const type of ["keydown", "keyup"]) {
        const event = send(type, {
          key: "Tab",
          code: "Tab",
          keyCode: 9,
          ...flags,
        });
        assert.equal(event.prevented, false, `Tab mask=${mask}`);
        assert.equal(event.stopped, false, `Tab mask=${mask}`);
      }
    }
    assert.equal(events.length, 0, `No synthetic Tab mask=${mask}`);
  }
  context.__folio.setTouchShortcutModifiers(32);
  events.length = 0;
  for (const init of [{ isComposing: true }, { keyCode: 229 }]) {
    for (const type of ["keydown", "keyup"]) {
      const event = send(type, init);
      assert.equal(event.prevented, false);
      assert.equal(event.stopped, false);
    }
  }
  listeners.get("compositionstart")({
    type: "compositionstart",
    isTrusted: true,
  });
  for (const type of ["keydown", "keyup"]) {
    const event = send(type, { isComposing: false, keyCode: 13 });
    assert.equal(event.prevented, false);
    assert.equal(event.stopped, false);
  }
  context.__folio.touchShortcutKey("undo");
  assert.equal(events.length, 0);
  listeners.get("compositionend")({ type: "compositionend", isTrusted: true });
  for (const type of ["keydown", "keyup"]) {
    const event = send(type, { key: "z", keyCode: 90 });
    assert.equal(event.prevented, true);
    assert.equal(event.stopped, true);
  }
  assert.deepEqual(
    events.map((event) => [event.type, event.metaKey]),
    [
      ["keydown", true],
      ["keyup", true],
    ],
  );
  context.__folio.disposeTouchShortcuts();
  assert.equal(listeners.size, 0);
});

async function touchGestureHarness(width = 1024) {
  let now = 0;
  const menus = [];
  const events = [];
  const messages = [];
  const listeners = new Map();
  const timers = new Set();
  class MouseEvent {
    constructor(type, init = {}) {
      Object.assign(this, { type, cancelable: true, isTrusted: false }, init);
    }
    stopImmediatePropagation() {
      this.stopped = true;
    }
    preventDefault() {
      this.defaultPrevented = true;
    }
  }
  class KeyboardEvent {
    constructor(type, init = {}) {
      Object.assign(this, init);
      this.type = type;
    }
  }
  class PointerEvent extends MouseEvent {}
  class Element {
    isConnected = true;
    parentElement = null;
    contains(other) {
      return (
        other === this ||
        (other?.parentElement ? this.contains(other.parentElement) : false)
      );
    }
    closest(selector) {
      return selector.includes("draggable") ? this : null;
    }
    getAttribute(name) {
      return name === "draggable" ? "true" : null;
    }
    tagName = "DIV";
    dispatchEvent(event) {
      events.push(event);
      this.onEvent?.(event);
      return true;
    }
  }
  const row = new Element();
  const context = vm.createContext({
    __folio: { post: (name, payload) => messages.push({ name, payload }) },
    innerWidth: width,
    innerHeight: 874,
    matchMedia: () => ({ matches: width <= 440 }),
    MouseEvent,
    PointerEvent,
    KeyboardEvent,
    Element,
    Node: Element,
    HTMLCanvasElement: class extends Element {},
    TouchEvent: class {},
    performance: { now: () => now },
    setTimeout: (fn) => {
      timers.add(fn);
      return fn;
    },
    clearTimeout: (fn) => timers.delete(fn),
    requestAnimationFrame: () => 1,
    cancelAnimationFrame() {},
    getComputedStyle: () => ({ overflowY: "visible" }),
    document: {
      createElement: () => ({ remove() {} }),
      elementFromPoint: () => row,
      elementsFromPoint: () => [row],
      activeElement: row,
      querySelectorAll: () => menus,
      addEventListener() {},
    },
    webkit: {
      messageHandlers: {
        touchUIHold: { postMessage: (value) => messages.push(value) },
      },
    },
    window: {
      addEventListener(name, listener) {
        const group = listeners.get(name) ?? [];
        group.push(listener);
        listeners.set(name, group);
      },
      removeEventListener(name, listener) {
        listeners.set(
          name,
          (listeners.get(name) ?? []).filter((fn) => fn !== listener),
        );
      },
    },
  });
  const script = await readFile(
    new URL(
      "../../../apps/ios/Folio/Resources/Compat/touch-gestures.js",
      import.meta.url,
    ),
    "utf8",
  );
  vm.runInContext(script, context);
  const send = (type, x = 10, flags = {}) => {
    const EventClass = type.startsWith("pointer") ? PointerEvent : MouseEvent;
    const event = new EventClass(type, {
      pointerType: "touch",
      pointerId: 7,
      isPrimary: true,
      button: 0,
      clientX: x,
      clientY: 10,
      target: row,
      isTrusted: true,
      ...flags,
    });
    for (const listener of listeners.get(type) ?? []) listener(event);
    return event;
  };
  return {
    menus,
    context,
    events,
    messages,
    send,
    row,
    Element,
    advance: (ms) => {
      now += ms;
    },
    hold: () => {
      now += 500;
      for (const fn of [...timers]) fn();
    },
  };
}

test("UI presses and drags stay native for finger, Pencil and mouse", async () => {
  for (const pointerType of ["touch", "pen", "mouse"]) {
    const h = await touchGestureHarness();
    for (let i = 0; i < 2; i++) {
      for (const type of ["pointerdown", "pointermove", "pointerup"]) {
        const event = h.send(type, type === "pointermove" ? 40 : 10, {
          pointerType,
        });
        assert.equal(event.stopped, undefined);
        assert.equal(event.defaultPrevented, undefined);
      }
    }
    assert.equal(h.events.length, 0);
    assert.equal(h.context.__folio.armTouchUI, undefined);
  }
});

test("UI holds open the menu while still down, and moving closes it", async () => {
  for (const pointerType of ["touch", "pen"]) {
    const h = await touchGestureHarness();
    h.send("pointerdown", 10, { pointerType });
    h.advance(500);
    assert.equal(h.context.__folio.touchUIHold("began", 10, 10), "menu");
    assert.deepEqual(
      h.events.map((e) => e.type),
      ["contextmenu"],
    );
    assert.equal(h.context.__folio.touchUIHold("moved", 10, 10), "closed");
    assert.deepEqual(
      h.events.map((e) => `${e.type}:${e.key ?? ""}`),
      ["contextmenu:", "keydown:Escape", "keyup:Escape"],
    );
  }
  const kept = await touchGestureHarness();
  kept.send("pointerdown");
  kept.context.__folio.touchUIHold("began", 10, 10);
  assert.equal(kept.context.__folio.touchUIHold("ended", 10, 10), "kept");
  assert.equal(kept.events.length, 1);
});

test("UI hold menus need an uninterrupted UI press", async () => {
  for (const [interrupt, reason] of [
    [(h) => h.send("pointermove", 40), "moved"],
    [(h) => h.send("scroll"), "scroll"],
    [(h) => h.send("contextmenu"), "contextmenu"],
    [
      (h) => h.send("pointerdown", 10, { pointerId: 8, isPrimary: false }),
      "no-ui-press",
    ],
    [(h) => h.context.__folio.setTouchGestures(false, false), "disabled"],
  ]) {
    const h = await touchGestureHarness();
    h.send("pointerdown");
    interrupt(h);
    h.advance(500);
    assert.equal(h.context.__folio.touchUIHold("began", 10, 10), reason);
    assert.equal(h.events.length, 0);
  }
});

test("WebKit's drag lift keeps the hold and reopens a closed menu once", async () => {
  const h = await touchGestureHarness();
  h.send("pointerdown");
  h.send("dragstart", 12);
  h.send("pointerdown", 12, { pointerType: "mouse" });
  assert.equal(h.context.__folio.touchUIHold("began", 10, 10), "menu");
  h.send("dragend", 12);
  h.send("dragend", 12);
  assert.deepEqual(
    h.events.map((e) => e.type),
    ["contextmenu", "contextmenu"],
  );
  const open = await touchGestureHarness();
  open.send("pointerdown");
  open.context.__folio.touchUIHold("began", 10, 10);
  open.menus.push({
    getBoundingClientRect: () => ({
      left: 0,
      top: 0,
      right: 50,
      bottom: 50,
      width: 50,
      height: 50,
    }),
  });
  open.send("dragend", 12);
  assert.equal(open.events.length, 1);
});

test("Secondary click completes WebKit's partial press, then falls back", async () => {
  const h = await touchGestureHarness();
  // Device log: pointerdown and contextmenu with button 2, no button-2 mousedown/mouseup.
  h.send("pointerdown", 10, { pointerType: "mouse", button: 2, buttons: 2 });
  h.send("contextmenu", 10, { pointerType: "mouse", button: 2 });
  h.hold();
  assert.deepEqual(
    h.events.map((e) => `${e.type}:${e.button}`),
    ["mousedown:2", "mouseup:2"],
  );
  assert.equal(h.context.__folio.secondaryClick(10, 10), "menu");
  assert.deepEqual(
    h.events.slice(2).map((e) => `${e.type}:${e.button}`),
    [
      "pointerdown:2",
      "mousedown:2",
      "pointerup:2",
      "mouseup:2",
      "contextmenu:2",
    ],
  );
  const opened = await touchGestureHarness();
  opened.send("pointerdown", 10, {
    pointerType: "mouse",
    button: 2,
    buttons: 2,
  });
  opened.send("contextmenu", 10, { pointerType: "mouse", button: 2 });
  opened.hold();
  opened.menus.push({
    getBoundingClientRect: () => ({
      left: 0,
      top: 0,
      right: 50,
      bottom: 50,
      width: 50,
      height: 50,
    }),
  });
  assert.equal(
    opened.context.__folio.secondaryClick(10, 10),
    "menu-opened-after-completion",
  );
  // A menu that already existed, or one far away, is not a new menu near the click.
  const far = await touchGestureHarness();
  far.send("pointerdown", 10, { pointerType: "mouse", button: 2, buttons: 2 });
  far.menus.push({
    getBoundingClientRect: () => ({
      left: 900,
      top: 900,
      right: 950,
      bottom: 950,
      width: 50,
      height: 50,
    }),
  });
  assert.equal(far.context.__folio.secondaryClick(10, 10), "menu");
  const ctrl = await touchGestureHarness();
  ctrl.send("pointerdown", 10, {
    pointerType: "mouse",
    button: 2,
    buttons: 2,
    ctrlKey: true,
  });
  ctrl.send("contextmenu", 10, {
    pointerType: "mouse",
    button: 2,
    ctrlKey: true,
  });
  ctrl.hold();
  assert.equal(ctrl.events.length, 0);
});

test("phone Minimize UI is momentary, ignores latches and yields to IME", async () => {
  const events = [];
  const listeners = new Map();
  const target = {
    dispatchEvent: (event) => {
      events.push(event);
      return true;
    },
  };
  const context = vm.createContext({
    __folio: {},
    KeyboardEvent: class {
      constructor(type, init) {
        Object.assign(this, { type }, init);
      }
    },
    document: {
      activeElement: target,
      addEventListener() {},
      removeEventListener() {},
    },
    window: {
      addEventListener(name, fn) {
        listeners.set(name, fn);
      },
      removeEventListener() {},
    },
  });
  const script = await readFile(
    new URL(
      "../../../apps/ios/Folio/Resources/Compat/touch-shortcuts.js",
      import.meta.url,
    ),
    "utf8",
  );
  vm.runInContext(script, context);
  context.__folio.setTouchShortcutModifiers(170); // All four modifiers locked.
  events.length = 0;
  context.__folio.minimizePhoneUI();
  assert.deepEqual(
    events.map((e) => [
      e.type,
      e.key,
      e.shiftKey,
      e.metaKey,
      e.altKey,
      e.ctrlKey,
    ]),
    [
      ["keydown", "\\", true, true, false, false],
      ["keyup", "\\", true, true, false, false],
    ],
  );
  assert.deepEqual(
    { ...context.__folio.touchShortcutFlags() },
    { shiftKey: true, metaKey: true, altKey: true, ctrlKey: true },
  );
  events.length = 0;
  listeners.get("compositionstart")({
    type: "compositionstart",
    isTrusted: true,
  });
  context.__folio.minimizePhoneUI();
  assert.equal(events.length, 0);
  listeners.get("compositionend")({ type: "compositionend", isTrusted: true });
  context.__folio.minimizePhoneUI();
  assert.equal(events.length, 2);
  context.__folio.disposeTouchShortcuts();
  assert.equal(context.__folio.minimizePhoneUI, undefined);
});

test("Home opens a double-click fixture after a trusted tap at phone and iPad widths", async () => {
  for (const width of [402, 874, 1024]) {
    const h = await touchGestureHarness(width);
    h.context.__folio.setTouchGestures(true, true);
    let opened = 0;
    h.row.onEvent = (event) => {
      if (event.type === "dblclick") opened++;
    };
    h.send("pointerdown");
    h.send("pointerup");
    // Never activate on pointerup alone: scroll/cancel paths must retain WebKit's decision.
    assert.equal(h.events.length, 0);
    const click = h.send("click");
    assert.equal(click.stopped, true);
    assert.equal(opened, 1);
    assert.deepEqual(
      h.events.map((e) => [e.type, e.detail]),
      [
        ["pointerdown", 1],
        ["mousedown", 1],
        ["pointerup", 1],
        ["mouseup", 1],
        ["click", 1],
        ["pointerdown", 2],
        ["mousedown", 2],
        ["pointerup", 2],
        ["mouseup", 2],
        ["click", 2],
        ["dblclick", 2],
      ],
    );
    assert.equal(h.messages.length, 0, "Home decision logging is opt-in");
  }
});

test("Home phone diagnostics identify rejected taps without changing their native events", async () => {
  for (const [expected, setup] of [
    ["home-moved", (h) => h.send("pointermove", 17)],
    ["home-cancelled", (h) => h.send("pointercancel")],
    [
      "home-multi",
      (h) => h.send("pointerdown", 10, { pointerId: 8, isPrimary: false }),
    ],
    [
      "home-expired",
      (h) => {
        h.send("pointerup");
        h.advance(701);
      },
    ],
    ["home-distance", (h) => h.send("pointerup")],
    ["home-click-ancestor", (h) => h.send("pointerup")],
    ["home-click-other", (h) => h.send("pointerup")],
  ]) {
    const h = await touchGestureHarness(402);
    h.context.__folio.setTouchGestures(true, true);
    h.context.__folio.setUIDragOptions(true);
    h.send("pointerdown");
    setup(h);
    const ancestor = new h.Element();
    h.row.parentElement = ancestor;
    const click = h.send("click", expected === "home-distance" ? 17 : 10, {
      target:
        expected === "home-click-ancestor"
          ? ancestor
          : expected === "home-click-other"
            ? new h.Element()
            : h.row,
    });
    assert.equal(click.stopped, undefined);
    assert.equal(h.events.length, 0);
    assert.ok(
      h.messages.some((m) => m.payload.detail === expected),
      expected,
    );
  }
});

test("Home diagnostics separate disabled, editable, mouse and synthetic activation", async () => {
  const h = await touchGestureHarness(402);
  h.context.__folio.setTouchGestures(false, true);
  h.context.__folio.setUIDragOptions(true);
  h.send("pointerdown");
  assert.equal(h.messages.at(-1).payload.detail, "home-disabled");
  h.context.__folio.setTouchGestures(true, true);
  h.row.closest = () => h.row;
  h.send("pointerdown");
  assert.equal(h.messages.at(-1).payload.detail, "home-editable");
  h.send("pointerup");
  h.row.closest = () => null;
  h.send("pointerdown", 10, { pointerType: "mouse" });
  h.send("click");
  assert.equal(h.messages.at(-1).payload.detail, "home-mouse");
  h.send("pointerdown");
  h.send("pointerup");
  h.send("click", 10, { isTrusted: false });
  assert.equal(h.events.length, 0);
  h.row.getAttribute = () => "private file name / private-url";
  h.send("click");
  assert.equal(h.events.at(-1).type, "dblclick");
  assert.ok(h.messages.some((m) => m.payload.detail === "home-double"));
  assert.ok(
    h.messages.some(
      (m) => m.payload.kind === "synthetic" && m.payload.type === "dblclick",
    ),
  );
  assert.equal(JSON.stringify(h.messages).includes("private"), false);
  const schema = await readFile(
    new URL(
      "../../../apps/ios/Folio/Bridge/UIDragCapture.swift",
      import.meta.url,
    ),
    "utf8",
  );
  for (const m of h.messages)
    assert.ok(schema.includes(`"${m.payload.detail}"`));
});
