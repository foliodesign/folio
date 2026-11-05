import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
const scripts = await Promise.all(
  ["bridge", "focus-reveal-guard"].map((name) =>
    readFile(
      new URL(
        `../../../apps/ios/Folio/Resources/Compat/${name}.js`,
        import.meta.url,
      ),
      "utf8",
    ),
  ),
);
function harness(overflowX = "hidden", overflowY = "hidden") {
  const messages = [],
    listeners = new Map(),
    windowListeners = new Map();
  let time = 0;
  class Element {
    constructor(tagName = "DIV", parentElement = null) {
      Object.assign(this, {
        tagName,
        parentElement,
        scrollLeft: 0,
        scrollTop: 0,
        clientWidth: 500,
        clientHeight: 400,
        isContentEditable: false,
        overflowX,
        overflowY,
      });
    }
    contains(el) {
      for (; el; el = el.parentElement) if (el === this) return true;
      return false;
    }
  }
  class HTMLElement extends Element {}
  class HTMLInputElement extends HTMLElement {
    type = "text";
  }
  class HTMLTextAreaElement extends HTMLElement {}
  const container = new HTMLElement(),
    editor = new HTMLElement("DIV", container);
  editor.isContentEditable = true;
  editor.textContent = "private text";
  const target = (map) => ({
    addEventListener(name, fn, capture) {
      map.set(name, { fn, capture });
    },
    removeEventListener(name, fn, capture) {
      assert.equal(map.get(name)?.fn, fn);
      assert.equal(map.get(name)?.capture, capture);
      map.delete(name);
    },
  });
  const document = {
    ...target(listeners),
    activeElement: editor,
    scrollingElement: null,
  };
  const context = vm.createContext({
    Element,
    HTMLElement,
    HTMLInputElement,
    HTMLTextAreaElement,
    document,
    window: { ...target(windowListeners), scrollX: 0, scrollY: 0 },
    getComputedStyle: (el) => ({
      overflowX: el.overflowX,
      overflowY: el.overflowY,
    }),
    performance: { now: () => time },
    innerWidth: 1024,
    innerHeight: 768,
    location: {
      protocol: "https:",
      hostname: "www.figma.com",
      pathname: "/design/test",
      port: "",
    },
    webkit: {
      messageHandlers: { folio: { postMessage: (m) => messages.push(m) } },
    },
  });
  scripts.forEach((script) => vm.runInContext(script, context));
  return {
    context,
    runtime: context.__folio,
    container,
    editor,
    document,
    listeners,
    windowListeners,
    messages,
    time: (next) => (time = next),
    emit: (name, target = editor) => listeners.get(name)?.fn({ target }),
    enable() {
      context.__folio.setFocusRevealGuard(true);
      this.emit("focusin");
    },
  };
}

test("OFF installs no listeners; ON and disposal remove matching capture listeners", () => {
  const h = harness();
  assert.equal(h.listeners.size, 0);
  h.enable();
  assert.equal(h.listeners.size, 6);
  h.runtime.setFocusRevealGuard(false);
  assert.equal(h.listeners.size, 0);
  h.enable();
  h.runtime.dispose();
  assert.equal(h.listeners.size, 0);
  assert.equal(h.windowListeners.size, 0);
  assert.equal(h.context.__folio, undefined);
});
test("hidden ancestor reveal restores before target listeners, logs fixed geometry only", () => {
  const h = harness();
  h.enable();
  h.runtime.setFocusRevealLogging(true);
  h.container.scrollTop = 120;
  h.emit("scroll", h.container);
  assert.equal(h.container.scrollTop, 0);
  assert.equal(h.runtime.focusRevealGuardStats().restored, 1);
  const record = h.messages.find((m) => m.payload.event === "revealguard");
  assert.equal(record.payload.offsetTop, 120);
  assert.equal(JSON.stringify(h.messages).includes("private"), false);
  h.emit("scroll", h.container);
  assert.equal(h.runtime.focusRevealGuardStats().restored, 1);
});
test("auto and scroll ancestors remain scrollable, mixed axes restore hidden axis only", () => {
  for (const type of ["auto", "scroll", "clip"]) {
    const h = harness(type, type);
    h.enable();
    h.container.scrollTop = 120;
    h.emit("scroll", h.container);
    assert.equal(h.container.scrollTop, 120);
  }
  const h = harness("hidden", "auto");
  h.enable();
  h.container.scrollLeft = 50;
  h.container.scrollTop = 120;
  h.emit("scroll", h.container);
  assert.equal(h.container.scrollLeft, 0);
  assert.equal(h.container.scrollTop, 120);
});
test("focusout, blur, pagehide, disable and nonancestor scroll never restore", () => {
  for (const action of [
    "focusout",
    "blur",
    "pagehide",
    "disable",
    "nonancestor",
  ]) {
    const h = harness();
    h.enable();
    if (action === "focusout") h.emit(action);
    else if (action === "disable") h.runtime.setFocusRevealGuard(false);
    else if (action === "nonancestor") h.document.activeElement = null;
    else h.windowListeners.get(action).fn();
    h.container.scrollTop = 120;
    h.emit("scroll", h.container);
    assert.equal(h.container.scrollTop, 120, action);
  }
});
test("expired window leaves scroll alone and rebases before next editing trigger", () => {
  const h = harness();
  h.enable();
  h.time(300);
  h.container.scrollTop = 120;
  h.emit("scroll", h.container);
  assert.equal(h.container.scrollTop, 120);
  assert.equal(h.runtime.focusRevealGuardStats().ignored, 1);
  h.emit("keydown");
  h.container.scrollTop = 180;
  h.emit("scroll", h.container);
  assert.equal(h.container.scrollTop, 120);
});
test("logging observes inner scroll with the candidate OFF, and logging OFF removes observers", () => {
  const h = harness();
  h.runtime.setFocusRevealLogging(true);
  h.container.scrollTop = 120;
  h.emit("scroll", h.container);
  assert.equal(h.container.scrollTop, 120);
  assert.equal(h.messages[0].payload.event, "innerscroll");
  assert.equal(h.runtime.focusRevealGuardStats().restored, 0);
  h.runtime.setFocusRevealLogging(false);
  assert.equal(h.listeners.size, 0);
});
test("auth, dashboards, other origins, root scroll and noneditable focus stay untouched", () => {
  for (const path of ["/files", "/login"]) {
    const h = harness();
    h.context.location.pathname = path;
    h.enable();
    h.container.scrollTop = 120;
    h.emit("scroll", h.container);
    assert.equal(h.container.scrollTop, 120);
  }
  for (const change of [
    (h) => (h.context.location.hostname = "example.com"),
    (h) => (h.document.scrollingElement = h.container),
    (h) => (h.editor.isContentEditable = false),
  ]) {
    const h = harness();
    change(h);
    h.enable();
    h.container.scrollTop = 120;
    h.emit("scroll", h.container);
    assert.equal(h.container.scrollTop, 120);
  }
});
