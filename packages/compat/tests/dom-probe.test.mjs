import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
const script = await readFile(
  new URL(
    "../../../apps/ios/Folio/Resources/Compat/dom-probe.js",
    import.meta.url,
  ),
  "utf8",
);
const node = (tag, attrs = {}, children = []) => {
  const el = {
    tagName: tag,
    id: attrs.id ?? "",
    classList: (attrs.class ?? "").split(" ").filter(Boolean),
    children,
    parentElement: null,
    getAttribute: (name) => attrs[name] ?? null,
    getBoundingClientRect: () => ({
      x: 0,
      y: 0,
      left: 0,
      top: 0,
      right: 402,
      bottom: 48,
      width: 402,
      height: 48,
    }),
    matches: (selector) => selector.includes("button") && tag === "BUTTON",
    querySelector: () => null,
    style: { getPropertyValue: () => "" },
  };
  for (const child of children) child.parentElement = el;
  Object.defineProperty(el, "textContent", {
    get() {
      throw new Error("Text read");
    },
  });
  Object.defineProperty(el, "value", {
    get() {
      throw new Error("Value read");
    },
  });
  return el;
};
test("DOM probe exports structure and redacts arbitrary names, IDs and CSS values", async () => {
  const buttons = [
    node("BUTTON", {
      "aria-label": "Scale",
      "data-testid": "Scale-tool",
      "aria-pressed": "true",
    }),
    node("BUTTON", {
      id: "secret-file-key",
      "aria-label": "Expand UI secret-file-name",
      "data-testid": "secret-layer-name",
      class: "toolbelt_button--selectedButton--abc secret-user-name",
    }),
    node("BUTTON", { "aria-label": "private-person" }),
  ];
  const toolbar = node(
    "DIV",
    { "data-testid": "positioned-design-toolbelt" },
    buttons,
  );
  const body = node("BODY", {}, [
    toolbar,
    node("BUTTON", { "aria-label": "Scale" }),
  ]);
  const html = node("HTML", {}, [body]);
  const document = {
    body,
    documentElement: html,
    querySelector: (selector) =>
      selector.includes("positioned-design-toolbelt") ? toolbar : null,
    querySelectorAll: (selector) =>
      selector.includes("positioned-design-toolbelt") ? [toolbar] : [],
  };
  const css = {
    length: 1,
    item: () => "--background-color",
    getPropertyValue: (name) =>
      name === "--background-color" ? "url(secret-file-key)" : "402px",
  };
  const context = vm.createContext({
    document,
    getComputedStyle: () => css,
    innerWidth: 402,
    innerHeight: 694,
    devicePixelRatio: 3,
  });
  vm.runInContext(script, context);
  const raw = await context.__folioCaptureDOMStructure(false);
  for (const secret of [
    "secret-file-key",
    "secret-file-name",
    "secret-layer-name",
    "secret-user-name",
    "private-person",
  ])
    assert.ok(!raw.includes(secret));
  const result = JSON.parse(raw);
  assert.equal(result.baseline.mode, "unknown");
  assert.equal(result.toolCheck, "not-requested");
  const scale = result.baseline.nodes.find((n) => n.testid === "Scale-tool");
  assert.equal(scale.buttonLabel, "Scale");
  assert.ok(
    result.baseline.nodes.some(
      (n) =>
        n.tag === "button" &&
        n.testid === null &&
        n.buttonLabel === "[redacted]",
    ),
  );
  assert.equal(scale.css.width, "402px");
  assert.equal(scale.states["aria-pressed"], "true");
  assert.equal(
    result.baseline.nodes[0].variables["--background-color"],
    "[redacted]",
  );
  assert.ok(
    result.baseline.nodes.some((n) => n.buttonLabel === "Expand UI [redacted]"),
  );
  assert.ok(
    result.baseline.nodes.every((n) => n.parent === null || n.parent < n.index),
  );
});
test("DOM probe caps exported nodes and reports incomplete structure", async () => {
  const toolbar = node(
    "DIV",
    {},
    Array.from({ length: 1600 }, () =>
      node("BUTTON", { "aria-label": "Move" }),
    ),
  );
  const body = node("BODY", {}, [toolbar]);
  const html = node("HTML", {}, [body]);
  const context = vm.createContext({
    document: {
      body,
      documentElement: html,
      querySelector: () => toolbar,
      querySelectorAll: (selector) =>
        selector.includes("positioned-design-toolbelt") ? [toolbar] : [],
    },
    getComputedStyle: () => ({ length: 0, getPropertyValue: () => "" }),
    innerWidth: 402,
    innerHeight: 694,
    devicePixelRatio: 3,
  });
  vm.runInContext(script, context);
  const result = JSON.parse(await context.__folioCaptureDOMStructure(false));
  assert.equal(result.baseline.nodes.length, 800);
  assert.equal(result.baseline.limitReached, true);
});

test("DOM probe reaches tool buttons beneath the captured carousel wrappers", async () => {
  const move = node("BUTTON", {
    "data-testid": "Move-tool",
    "aria-pressed": "true",
  });
  let nested = move;
  for (let i = 0; i < 13; i++) nested = node("DIV", {}, [nested]);
  const toolbar = node("DIV", { "data-testid": "positioned-design-toolbelt" }, [
    nested,
  ]);
  const body = node("BODY", {}, [toolbar]);
  const html = node("HTML", {}, [body]);
  const context = vm.createContext({
    document: {
      body,
      documentElement: html,
      querySelector: () => toolbar,
      querySelectorAll: (s) =>
        s.includes("positioned-design-toolbelt") ? [toolbar] : [],
    },
    getComputedStyle: () => ({ length: 0, getPropertyValue: () => "" }),
    innerWidth: 933,
    innerHeight: 694,
    devicePixelRatio: 3,
  });
  vm.runInContext(script, context);
  const result = JSON.parse(await context.__folioCaptureDOMStructure(false));
  assert.equal(result.baseline.limitReached, false);
  assert.ok(
    result.baseline.nodes.some(
      (n) => n.testid === "Move-tool" && n.states["aria-pressed"] === "true",
    ),
  );
});

test("probe keys allow mode radios, re-resolve replaced controls, and still skip text editors", async () => {
  const toolbar = node("DIV", { "data-testid": "positioned-design-toolbelt" });
  const body = node("BODY", {}, [toolbar]);
  const html = node("HTML", {}, [body]);
  const events = [];
  const document = {
    body,
    documentElement: html,
    querySelector: () => toolbar,
    querySelectorAll: (s) =>
      s.includes("positioned-design-toolbelt") ? [toolbar] : [],
  };
  toolbar.isConnected = true;
  const radio = () => {
    const el = node("INPUT", {
      type: "radio",
      "data-testid": "toolbelt-mode-option-design",
    });
    el.parentElement = toolbar;
    el.isConnected = true;
    el.checked = true;
    el.matches = (s) => s === 'input[type="radio"]';
    el.closest = () => toolbar;
    el.dispatchEvent = (event) => {
      events.push(event);
      if (event.type === "keyup") {
        el.isConnected = false;
        document.activeElement = radio();
      }
      return true;
    };
    return el;
  };
  document.activeElement = radio();
  const context = vm.createContext({
    document,
    getComputedStyle: () => ({ length: 0, getPropertyValue: () => "" }),
    innerWidth: 402,
    innerHeight: 694,
    devicePixelRatio: 3,
    KeyboardEvent: class {
      constructor(type, properties) {
        this.type = type;
        Object.assign(this, properties);
      }
    },
    setTimeout: (callback) => callback(),
  });
  vm.runInContext(script, context);
  const result = JSON.parse(await context.__folioCaptureDOMStructure(true));
  assert.equal(result.toolCheck, "dispatched-not-acceptance");
  assert.equal(result.modes.length, 2);
  assert.deepEqual(
    result.tools.map((t) => t.key),
    ["H", "K", "V"],
  );
  assert.deepEqual(
    events.filter((e) => e.type === "keydown").map((e) => [e.key, e.shiftKey]),
    [
      ["D", true],
      ["D", true],
      ["h", false],
      ["k", false],
      ["v", false],
    ],
  );
  const input = node("INPUT");
  input.matches = () => false;
  input.closest = () => input;
  document.activeElement = input;
  const skipped = JSON.parse(await context.__folioCaptureDOMStructure(true));
  assert.equal(skipped.toolCheck, "skipped-editor-or-no-toolbar");
  assert.equal(events.length, 10);
  input.isConnected = true;
  input.getBoundingClientRect = () => ({
    x: 0,
    y: -200,
    left: 0,
    top: -200,
    right: 1,
    bottom: -184,
    width: 1,
    height: 16,
  });
  input.dispatchEvent = (event) => {
    events.push(event);
    return true;
  };
  const proxy = JSON.parse(await context.__folioCaptureDOMStructure(true));
  assert.equal(proxy.toolCheck, "dispatched-not-acceptance");
  assert.equal(proxy.tools.length, 3);
  assert.equal(events.length, 20);
});
