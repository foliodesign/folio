import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const scripts = await Promise.all(
  ["bridge", "focus-environment"].map((name) =>
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
  const messages = [],
    listeners = new Map(),
    viewportListeners = new Map(),
    metas = [];
  let mutation,
    observing = false;
  class Element {
    constructor(tagName) {
      this.tagName = tagName;
      this.textContent = "private text";
    }
  }
  class HTMLInputElement extends Element {
    constructor() {
      super("INPUT");
      this.type = "text";
      this.value = "private input";
    }
  }
  const document = {
    head: null,
    querySelectorAll: () => metas,
    createElement: () => ({
      name: "",
      content: "",
      getAttribute() {
        return this.content;
      },
      setAttribute(_, value) {
        this.content = value;
      },
      removeAttribute() {
        this.content = "";
      },
      remove() {
        metas.splice(metas.indexOf(this), 1);
      },
    }),
  };
  function target(map) {
    return {
      addEventListener(name, fn) {
        map.set(name, fn);
      },
      removeEventListener(name, fn) {
        assert.equal(map.get(name), fn);
        map.delete(name);
      },
    };
  }
  const context = vm.createContext({
    document,
    Element,
    HTMLElement: Element,
    HTMLTextAreaElement: class extends Element {},
    queueMicrotask: (fn) => fn(),
    HTMLInputElement,
    innerWidth: 1024,
    innerHeight: 768,
    performance: { now: () => 42 },
    location: {
      protocol: "https:",
      hostname: "www.figma.com",
      pathname: "/design/test",
    },
    window: {
      ...target(listeners),
      scrollX: 0,
      scrollY: 12,
      visualViewport: {
        ...target(viewportListeners),
        width: 1024,
        height: 450,
        offsetLeft: 0,
        offsetTop: 20,
        scale: 1,
      },
    },
    MutationObserver: class {
      constructor(fn) {
        this.viewport = mutation === undefined;
        if (this.viewport) mutation = fn;
      }
      observe() {
        if (this.viewport) observing = true;
      }
      disconnect() {
        if (this.viewport) observing = false;
      }
    },
    webkit: {
      messageHandlers: { folio: { postMessage: (m) => messages.push(m) } },
    },
  });
  for (const script of scripts) vm.runInContext(script, context);
  return {
    context,
    messages,
    document,
    metas,
    listeners,
    viewportListeners,
    mutation: () => mutation(),
    observing: () => observing,
    input: new HTMLInputElement(),
  };
}

test("focus logging is opt-in, exports only geometry and fixed tag/type, and disposes", () => {
  const h = harness(),
    r = h.context.__folio;
  h.listeners.get("focusin")({ type: "focusin", target: h.input });
  assert.equal(h.messages.length, 0);
  r.setFocusLogging(true);
  h.listeners.get("focusin")({ type: "focusin", target: h.input });
  h.viewportListeners.get("resize")();
  assert.equal(h.messages[1].payload.tag, "INPUT");
  assert.equal(h.messages[1].payload.inputType, "text");
  assert.equal(h.messages[2].payload.height, 450);
  assert.equal(h.messages[2].payload.offsetTop, 20);
  assert.equal(JSON.stringify(h.messages).includes("private"), false);
  r.setFocusLogging(false);
  assert.equal(h.viewportListeners.size, 0);
  const count = h.messages.length;
  h.listeners.get("focusout")({ type: "focusout", target: h.input });
  assert.equal(h.messages.length, count);
  r.dispose();
  assert.equal(h.listeners.size, 0);
});

test("viewport limit waits for head, preserves unrelated settings, and restores on disable/dispose", () => {
  const h = harness(),
    r = h.context.__folio;
  r.setFocusEnvironment(true, false);
  assert.equal(h.metas.length, 0);
  h.document.head = {
    append(meta) {
      h.metas.push(meta);
    },
  };
  const meta = h.document.createElement();
  const baseline =
    "width=device-width, initial-scale=1, maximum-scale=5, viewport-fit=cover";
  meta.content = baseline;
  h.metas.push(meta);
  h.mutation();
  assert.equal(
    meta.content,
    "width=device-width, initial-scale=1, viewport-fit=cover, maximum-scale=1",
  );
  h.mutation();
  assert.equal(h.metas.length, 1);
  r.setFocusEnvironment(false, false);
  assert.equal(meta.content, baseline);
  assert.equal(h.observing(), false);
  r.setFocusEnvironment(true, false);
  r.dispose();
  assert.equal(meta.content, baseline);
});

test("focus candidates skip auth and dashboards, remove added meta, and send no input to assistant", () => {
  const h = harness(),
    r = h.context.__folio;
  h.document.head = {
    append(meta) {
      h.metas.push(meta);
    },
  };
  h.context.location.pathname = "/login";
  r.setFocusEnvironment(true, true);
  assert.equal(h.metas.length, 0);
  h.listeners.get("focusin")({ type: "focusin", target: h.input });
  assert.equal(h.messages.length, 0);
  h.context.location.pathname = "/design/test";
  r.setFocusEnvironment(true, true);
  assert.equal(h.metas.length, 1);
  h.listeners.get("focusin")({ type: "focusin", target: h.input });
  assert.deepEqual({ ...h.messages[0].payload }, {});
  assert.equal(h.messages[0].name, "folioFocusAssist");
  h.context.location.pathname = "/files";
  r.setFocusEnvironment(true, true);
  assert.equal(h.metas.length, 0);
  r.dispose();
});

test("canvas edit guard reports hidden DOM editors without logging or private data", () => {
  const h = harness();
  const focused = [];
  h.context.window.webkit = {
    messageHandlers: {
      folioDOMEditorFocused: { postMessage: (value) => focused.push(value) },
    },
  };
  h.context.getComputedStyle = () => ({ visibility: "hidden", opacity: "0" });
  h.input.getBoundingClientRect = () => ({ width: 0, height: 0 });
  h.document.activeElement = h.input;
  h.listeners.get("focusin")({ type: "focusin", target: h.input });
  assert.equal(focused.at(-1), true);
  assert.equal(h.messages.length, 0);
  const editable = new h.context.Element("DIV");
  editable.isContentEditable = true;
  editable.getBoundingClientRect = h.input.getBoundingClientRect;
  h.document.activeElement = editable;
  h.listeners.get("focusin")({ type: "focusin", target: editable });
  assert.equal(focused.at(-1), true);
  h.document.activeElement = new h.context.Element("CANVAS");
  h.listeners.get("focusout")({ type: "focusout", target: editable });
  assert.equal(focused.at(-1), false);
  assert.equal(
    focused.every((value) => typeof value === "boolean"),
    true,
  );
  h.context.__folio.dispose();
});
