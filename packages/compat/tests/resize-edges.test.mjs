import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const script = await readFile(
  new URL(
    "../../../apps/ios/Folio/Resources/Compat/resize-edges.js",
    import.meta.url,
  ),
  "utf8",
);

// A left panel with a resize handle on its right edge (x 240) and Figma's floating toolbar lying
// across that edge near the bottom, as on a narrow iPhone screen.
function harness() {
  const listeners = new Map();
  const painted = [];
  // The first scan runs from a timer.
  const timers = [];
  const frames = [];
  class Element {
    constructor(tag, rect, parent, { cursor = "auto", cls = "" } = {}) {
      Object.assign(this, { tag, rect, cursor, cls, dispatched: [] });
      this.parentElement = parent ?? null;
      this.childElementCount = 0;
      this.isConnected = true;
      if (parent) parent.childElementCount++;
    }
    getBoundingClientRect() {
      const [left, top, right, bottom] = this.rect;
      return {
        left,
        top,
        right,
        bottom,
        width: right - left,
        height: bottom - top,
      };
    }
    getAttribute(name) {
      return name === "class" ? this.cls : null;
    }
    contains(other) {
      for (let el = other; el; el = el.parentElement)
        if (el === this) return true;
      return false;
    }
    closest(selector) {
      const tags = selector.split(/,\s*/);
      for (let el = this; el; el = el.parentElement)
        if (tags.includes(el.tag)) return el;
      return null;
    }
    dispatchEvent(event) {
      this.dispatched.push(event.type);
      return true;
    }
  }
  class MouseEvent {
    constructor(type, init) {
      Object.assign(this, init, { type, isTrusted: false });
    }
    stopImmediatePropagation() {}
    preventDefault() {
      this.defaultPrevented = true;
    }
  }
  class PointerEvent extends MouseEvent {}
  const root = new Element("div", [0, 0, 800, 800]);
  const panel = new Element("div", [0, 0, 240, 800], root);
  const row = new Element("div", [0, 280, 236, 320], panel);
  const handle = new Element("div", [238, 0, 242, 800], panel, {
    cursor: "col-resize",
  });
  const toolbar = new Element("div", [200, 700, 400, 760], root);
  const button = new Element("button", [210, 705, 260, 755], toolbar);
  // Top of the stack first.
  painted.push(button, toolbar, row, handle, panel, root);
  const line = new Element("div", [0, 0, 0, 0]);
  line.isConnected = false;
  line.style = {};
  line.setAttribute = () => {};
  const context = vm.createContext({
    __folio: {},
    Element,
    PointerEvent,
    MouseEvent,
    TouchEvent: class {},
    HTMLCanvasElement: class {},
    SVGElement: class {},
    MutationObserver: class {
      observe() {}
      disconnect() {}
    },
    getComputedStyle: (el) => ({ cursor: el.cursor }),
    requestAnimationFrame: (fn) => frames.push(fn),
    cancelAnimationFrame() {},
    setTimeout: (fn) => timers.push(fn),
    clearTimeout() {},
    performance,
    document: {
      readyState: "complete",
      createElement: () => line,
      documentElement: { append() {} },
      body: { getElementsByTagName: () => painted },
      elementsFromPoint: (x, y) =>
        painted.filter(
          ({ rect: [l, t, r, b] }) => x >= l && x <= r && y >= t && y <= b,
        ),
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
  timers.splice(0).forEach((fn) => fn());
  const press = (target, x, y, pointerType = "touch") => {
    const event = new PointerEvent("pointerdown", {
      pointerType,
      pointerId: 1,
      isPrimary: true,
      button: 0,
      buttons: 1,
      clientX: x,
      clientY: y,
      cancelable: true,
    });
    event.isTrusted = true;
    event.target = target;
    listeners.get("pointerdown")(event);
    return event;
  };
  const frame = () => frames.splice(0).forEach((fn) => fn());
  return { button, frame, handle, line, press, row, toolbar };
}

test("a tap on a toolbar button lying across a panel edge goes to the button", () => {
  const h = harness();
  const event = press(h, h.button, 240, 730);
  assert.equal(event.defaultPrevented, undefined);
  assert.deepEqual(h.handle.dispatched, []);
});

test("a tap on the toolbar background across the edge does not resize either", () => {
  const h = harness();
  const event = press(h, h.toolbar, 240, 758);
  assert.equal(event.defaultPrevented, undefined);
  assert.deepEqual(h.handle.dispatched, []);
});

test("a finger next to an uncovered edge still grabs it, even over a row", () => {
  const h = harness();
  const event = press(h, h.row, 236, 300);
  assert.equal(event.defaultPrevented, true);
  assert.deepEqual(h.handle.dispatched, ["pointerdown", "mousedown"]);
});

test("a finger grab draws the line up to the toolbar, not over it", () => {
  const h = harness();
  press(h, h.row, 236, 300);
  h.frame();
  assert.equal(h.line.style.height, "800px");
  assert.equal(
    h.line.style.background,
    "linear-gradient(to bottom, #0D99FF 0px, #0D99FF 700px, transparent 700px, " +
      "transparent 760px, #0D99FF 760px, #0D99FF 800px)",
  );
});

function press(h, target, x, y) {
  return h.press(target, x, y);
}
