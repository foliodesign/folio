import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const script = await readFile(
  new URL(
    "../../../apps/ios/Folio/Resources/Compat/file-availability.js",
    import.meta.url,
  ),
  "utf8",
);
const node = (tag, text, children = [], style = {}) => {
  const el = {
    tag,
    textContent: text,
    children,
    childElementCount: children.length,
    parentElement: null,
    style: {
      display: "block",
      visibility: "visible",
      borderRadius: "0px",
      boxShadow: "none",
      ...style,
    },
    getBoundingClientRect: () => ({
      width: style.width ?? 440,
      height: style.height ?? 40,
    }),
    querySelectorAll: () =>
      children
        .flatMap((child) => [child, ...child.querySelectorAll()])
        .filter((child) => ["a", "button"].includes(child.tag)),
  };
  for (const child of children) child.parentElement = el;
  return el;
};
const check = ({
  canvas = false,
  heading = "Hmm, we couldn't find that one",
  action = "Go back to Figma",
  card = true,
  hidden = false,
} = {}) => {
  const title = node("h1", heading);
  const back = node("button", action);
  const panel = node(
    "div",
    "private account emails must not be exported",
    [title, back],
    {
      height: 400,
      borderRadius: card ? "6px" : "0px",
      boxShadow: card ? "0px 2px 8px black" : "none",
      visibility: hidden ? "hidden" : "visible",
    },
  );
  const body = node("body", "", [panel], { width: 1408, height: 834 });
  const doc = {
    querySelector: () => (canvas ? {} : null),
    querySelectorAll: () => [panel, title],
  };
  const context = vm.createContext({
    document: doc,
    getComputedStyle: (el) => el.style,
    console: {
      log() {
        throw new Error("Must not log page data");
      },
    },
  });
  vm.runInContext(script, context);
  const result = context.__folioUnavailableFile();
  assert.equal(typeof result, "boolean");
  assert.equal(body.children[0], panel); // The check never edits or removes the card.
  return result;
};

test("not-found card returns only a boolean; curly apostrophe is accepted", () => {
  assert.equal(check(), true);
  assert.equal(check({ heading: "Hmm, we couldn’t find that one" }), true);
});
test("a mounted canvas always keeps the tab, even with an error-like card", () => {
  assert.equal(check({ canvas: true }), false);
});
test("loading, ordinary dialogs, bare text and hidden cards cannot close a file", () => {
  assert.equal(check({ heading: "Loading…" }), false);
  assert.equal(check({ heading: "Request access" }), false);
  assert.equal(check({ card: false }), false);
  assert.equal(check({ hidden: true }), false);
  assert.equal(check({ action: "Retry" }), false);
});
test("unverified localized error labels fail closed", () => {
  assert.equal(
    check({
      heading: "Die Datei wurde nicht gefunden",
      action: "Zurück zu Figma",
    }),
    false,
  );
});

const canvasWatch = (initial = false) => {
  let mounted = initial;
  let now = 0;
  let observeCallback;
  let timeoutCallback;
  let disconnected = false;
  let timerCleared = false;
  const context = vm.createContext({
    document: { querySelector: () => (mounted ? {} : null) },
    performance: { now: () => now },
    MutationObserver: class {
      constructor(callback) {
        observeCallback = callback;
      }
      observe(_doc, options) {
        assert.equal(options.childList, true);
        assert.equal(options.subtree, true);
      }
      disconnect() {
        disconnected = true;
      }
    },
    setTimeout: (callback, delay) => {
      assert.equal(delay, 1000);
      timeoutCallback = callback;
      return 1;
    },
    clearTimeout: () => {
      timerCleared = true;
    },
  });
  vm.runInContext(script, context);
  const result = context.__folioWaitForFileCanvas();
  return {
    result,
    mount: (elapsed) => {
      mounted = true;
      now = elapsed;
      observeCallback?.();
    },
    expire: () => timeoutCallback?.(),
    cleanup: () => ({ disconnected, timerCleared }),
  };
};

test("positive canvas observation returns immediately for an already mounted editor", async () => {
  const watch = canvasWatch(true);
  assert.equal(await watch.result, true);
});
test("canvas mounting restores promptly and disconnects the bounded read-only observer", async () => {
  const watch = canvasWatch();
  watch.mount(80);
  assert.equal(await watch.result, true);
  assert.deepEqual(watch.cleanup(), { disconnected: true, timerCleared: true });
});
test("missing or late canvas is not healthy evidence and the observer retires", async () => {
  const missing = canvasWatch();
  missing.expire();
  assert.equal(await missing.result, false);
  assert.deepEqual(missing.cleanup(), {
    disconnected: true,
    timerCleared: true,
  });
  const late = canvasWatch();
  late.mount(1100);
  assert.equal(await late.result, false);
});
