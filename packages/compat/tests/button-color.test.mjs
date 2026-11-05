import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const scripts = await Promise.all(
  ["bridge", "ua-button-color"].map((name) =>
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
  let callback;
  let observing = false;
  const children = [];
  const head = {
    prepend(style) {
      if (style.parentNode) style.remove();
      children.unshift(style);
      style.parentNode = head;
    },
  };
  const document = {
    head: null,
    documentElement: null,
    createElement(tag) {
      assert.equal(tag, "style");
      return {
        parentNode: null,
        textContent: "",
        remove() {
          if (this.parentNode) children.splice(children.indexOf(this), 1);
          this.parentNode = null;
        },
      };
    },
  };
  const context = vm.createContext({
    document,
    MutationObserver: class {
      constructor(fn) {
        callback = fn;
      }
      observe(target, options) {
        assert.equal(target, document);
        assert.deepEqual({ ...options }, { childList: true, subtree: true });
        observing = true;
      }
      disconnect() {
        observing = false;
      }
    },
  });
  scripts.forEach((s) => vm.runInContext(s, context));
  return {
    context,
    document,
    head,
    children,
    mutate: () => callback(),
    observing: () => observing,
  };
}

test("button normalization waits for document, injects one rule, and reverses cleanly", () => {
  const h = harness();
  h.context.__folio.setUAButtonColor(true);
  assert.equal(h.children.length, 0);
  assert.equal(h.observing(), true);
  h.document.head = h.head;
  h.mutate();
  assert.equal(h.observing(), false);
  assert.equal(h.children.length, 1);
  assert.equal(
    h.children[0].textContent,
    "@layer folio-ua-default { :where(button) { color: inherit; } }",
  );
  h.context.__folio.setUAButtonColor(true);
  assert.equal(h.children.length, 1);
  h.context.__folio.setUAButtonColor(false);
  assert.equal(h.children.length, 0);
  h.context.__folio.setUAButtonColor(true);
  h.context.__folio.dispose();
  assert.equal(h.children.length, 0);
  assert.equal(h.observing(), false);
});

test("disabled button normalization never installs or observes", () => {
  const h = harness();
  h.document.head = h.head;
  h.context.__folio.setUAButtonColor(false);
  assert.equal(h.children.length, 0);
  assert.equal(h.observing(), false);
});
