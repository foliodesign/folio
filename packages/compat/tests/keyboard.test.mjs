import assert from "node:assert/strict";
import { build } from "esbuild";
import test from "node:test";
import vm from "node:vm";
const source = (
  await build({
    entryPoints: [
      new URL("../src/keyboard-routing.ts", import.meta.url).pathname,
    ],
    bundle: true,
    format: "iife",
    globalName: "keyboard",
    write: false,
  })
).outputFiles[0].text;
function harness() {
  const messages = [],
    listeners = new Map(),
    microtasks = [];
  class HTMLElement {
    constructor(tagName) {
      this.tagName = tagName;
      this.isContentEditable = false;
    }
  }
  class HTMLInputElement extends HTMLElement {
    constructor() {
      super("INPUT");
      this.type = "text";
      this.value = "SECRET";
    }
  }
  class KeyboardEvent {
    constructor(key, flags = {}) {
      Object.assign(
        this,
        {
          type: "keydown",
          key,
          metaKey: true,
          shiftKey: false,
          ctrlKey: false,
          altKey: false,
          isTrusted: true,
          isComposing: false,
          repeat: false,
          defaultPrevented: false,
        },
        flags,
      );
    }
  }
  class InputEvent {
    constructor(inputType, type = "beforeinput") {
      Object.assign(this, {
        type,
        inputType,
        data: "SECRET",
        isTrusted: true,
        isComposing: false,
        defaultPrevented: false,
      });
    }
  }
  const document = {
    activeElement: new HTMLInputElement(),
    hasFocus: () => true,
  };
  const context = vm.createContext({
    HTMLElement,
    HTMLInputElement,
    KeyboardEvent,
    InputEvent,
    document,
    performance: { now: () => 42 },
    queueMicrotask: (fn) => microtasks.push(fn),
    window: {
      addEventListener(name, fn, options) {
        assert.deepEqual({ ...options }, { capture: true, passive: true });
        listeners.set(name, fn);
      },
      removeEventListener(name, fn, capture) {
        assert.equal(capture, true);
        assert.equal(listeners.get(name), fn);
        listeners.delete(name);
      },
    },
  });
  vm.runInContext(source, context);
  const runtime = { post: (name, payload) => messages.push({ name, payload }) };
  const toggle = context.keyboard.observeKeyboardRouting(runtime);
  return {
    messages,
    listeners,
    runtime,
    toggle,
    document,
    KeyboardEvent,
    InputEvent,
    flush: () => {
      microtasks.splice(0).forEach((fn) => fn());
    },
  };
}
test("only fixed chords, history input and active-element categories leave the world", () => {
  const h = harness();
  assert.equal(h.listeners.size, 0);
  h.toggle(true);
  for (const [key, flags] of [
    ["z", {}],
    ["Z", { shiftKey: true }],
    ["y", {}],
    ["y", { shiftKey: true }],
    ["SECRET", {}],
    ["z", { ctrlKey: true }],
  ])
    h.listeners.get("keydown")(new h.KeyboardEvent(key, flags));
  for (const type of [
    "insertText",
    "deleteContentBackward",
    "historyUndo",
    "historyRedo",
  ])
    h.listeners.get("beforeinput")(new h.InputEvent(type));
  h.listeners.get("input")(new h.InputEvent("historyRedo", "input"));
  assert.deepEqual(
    h.messages.slice(0, 3).map((m) => m.payload.chord),
    ["Cmd+Z", "Cmd+Shift+Z", "Cmd+Y"],
  );
  assert.equal(h.messages.length, 6);
  assert.equal(JSON.stringify(h.messages).includes("SECRET"), false);
  h.runtime.captureKeyboardFocus();
  assert.equal(h.messages.at(-1).payload.tag, "INPUT");
  h.document.activeElement = { tagName: "IFRAME" };
  h.runtime.captureKeyboardFocus();
  assert.equal(h.messages.at(-1).payload.iframe, true);
  assert.equal(h.messages.at(-1).payload.editable, false);
});
test("passive capture and post-dispatch sample final prevention without performing input", () => {
  const h = harness();
  h.toggle(true);
  const event = new h.KeyboardEvent("z");
  h.listeners.get("keydown")(event);
  assert.equal(event.defaultPrevented, false);
  event.defaultPrevented = true;
  h.flush();
  assert.deepEqual(
    h.messages.map((m) => [m.payload.phase, m.payload.defaultPrevented]),
    [
      ["capture", false],
      ["post-dispatch", true],
    ],
  );
  assert.equal(h.messages[0].payload.sequence, h.messages[1].payload.sequence);
});
test("disable, re-enable and disposal discard queued records from older generations", () => {
  const h = harness();
  h.toggle(true);
  h.listeners.get("keyup")(new h.KeyboardEvent("y", { type: "keyup" }));
  h.toggle(false);
  h.toggle(true);
  h.flush();
  assert.equal(h.messages.length, 1);
  h.listeners.get("keydown")(new h.KeyboardEvent("z"));
  h.toggle(false);
  h.flush();
  assert.equal(h.messages.length, 2);
  assert.equal(h.listeners.size, 0);
  h.runtime.captureKeyboardFocus();
  assert.equal(h.messages.length, 2);
});

test("navigation pagehide removes listeners and discards queued post-dispatch samples", () => {
  const h = harness();
  h.toggle(true);
  h.listeners.get("keydown")(new h.KeyboardEvent("z"));
  h.listeners.get("pagehide")();
  h.flush();
  assert.equal(h.messages.length, 1);
  assert.equal(h.listeners.size, 0);
});
