import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
const script = await readFile(
  new URL(
    "../../../apps/ios/Folio/Resources/Compat/pencil.js",
    import.meta.url,
  ),
  "utf8",
);
function harness() {
  const listeners = new Map();
  const delivered = [];
  class MouseEvent {
    constructor(type, init) {
      Object.assign(this, init, { type, isTrusted: false });
    }
  }
  class PointerEvent extends MouseEvent {}
  const target = {
    dispatchEvent(event) {
      delivered.push(event);
      listeners.get(event.type)?.(event);
      return !event.defaultPrevented;
    },
  };
  const context = vm.createContext({
    __folio: {},
    PointerEvent,
    MouseEvent,
    window: {
      addEventListener(name, listener, options) {
        if (name.startsWith("pointer"))
          assert.deepEqual({ ...options }, { capture: true, passive: true });
        listeners.set(name, listener);
      },
      removeEventListener(name) {
        listeners.delete(name);
      },
    },
  });
  vm.runInContext(script, context);
  const send = (type, init = {}) => {
    const event = new PointerEvent(type, {
      pointerType: "pen",
      pointerId: 9,
      clientX: 10,
      clientY: 20,
      buttons: ["pointerup", "pointercancel"].includes(type) ? 0 : 1,
      button: 0,
      isPrimary: true,
      ...init,
    });
    event.isTrusted = init.isTrusted ?? true;
    event.target = target;
    listeners.get(type)?.(event);
  };
  return { context, delivered, send, listeners, target };
}
test("synthesis requires selected JS strategy and native unusable verdict; never recurses on untrusted input", () => {
  const { context, delivered, send, listeners } = harness();
  send("pointerdown");
  assert.equal(delivered.length, 0);
  context.__folio.setPencilStrategy("pencil-as-mouse-js", false);
  send("pointerdown");
  assert.equal(delivered.length, 0);
  context.__folio.setPencilStrategy("none", true);
  send("pointerdown");
  assert.equal(delivered.length, 0);
  context.__folio.setPencilStrategy("pencil-as-mouse-js", true);
  send("pointerdown", { isTrusted: false });
  assert.equal(delivered.length, 0);
  send("pointerdown", { pointerType: "touch" });
  assert.equal(delivered.length, 0);
  send("pointerdown");
  send("pointermove", { clientX: 40, button: -1 });
  send("pointerup", { clientX: 40 });
  assert.deepEqual(
    delivered.map((e) => e.type),
    [
      "pointerdown",
      "mousedown",
      "pointermove",
      "mousemove",
      "pointerup",
      "mouseup",
    ],
  );
  assert.ok(delivered.every((e) => e.isTrusted === false));
  assert.equal(delivered[0].pointerType, "mouse");
  assert.equal(delivered[2].clientX, 40);
  assert.equal(delivered[2].button, -1);
  assert.equal(delivered[3].button, 0);
  assert.equal(delivered[3].buttons, 1);
  assert.equal(delivered[0].pointerId, 9);
  context.__folio.disposePencil();
  assert.equal(listeners.size, 0);
});
test("tap has a click, cancel does not; changing strategy cancels active drags", () => {
  const { context, delivered, send } = harness();
  context.__folio.setPencilStrategy("pencil-as-mouse-js", true);
  send("pointerdown");
  send("pointerup");
  assert.equal(delivered.at(-1).type, "click");
  delivered.length = 0;
  send("pointerdown");
  send("pointercancel");
  assert.ok(!delivered.some((e) => e.type === "click"));
  delivered.length = 0;
  send("pointerdown");
  context.__folio.setPencilStrategy("none", false);
  assert.deepEqual(
    delivered.slice(-2).map((e) => e.type),
    ["pointercancel", "mouseup"],
  );
  assert.ok(
    delivered.slice(-2).every((e) => e.buttons === 0 && e.pressure === 0),
  );
  const count = delivered.length;
  send("pointermove");
  send("pointerup");
  assert.equal(delivered.length, count);
});

test("reapplying a strategy preserves a drag; blur, pagehide and disposal release it", () => {
  for (const action of ["blur", "pagehide", "dispose"]) {
    const { context, delivered, send, listeners } = harness();
    context.__folio.setPencilStrategy("pencil-as-mouse-js", true);
    send("pointerdown");
    context.__folio.setPencilStrategy("pencil-as-mouse-js", true);
    send("pointermove", { clientX: 40 });
    assert.equal(delivered.at(-1).type, "mousemove");
    if (action === "dispose") context.__folio.disposePencil();
    else listeners.get(action)();
    assert.deepEqual(
      delivered.slice(-2).map((e) => e.type),
      ["pointercancel", "mouseup"],
    );
    assert.ok(delivered.slice(-2).every((e) => e.buttons === 0));
    const count = delivered.length;
    send("pointerup");
    assert.equal(delivered.length, count);
  }
});
test("secondary contacts are ignored and cancelled pointerdown suppresses mouse events", () => {
  const { context, delivered, send, target } = harness();
  context.__folio.setPencilStrategy("pencil-as-mouse-js", true);
  send("pointerdown", { button: 2 });
  send("pointerdown", { isPrimary: false });
  assert.equal(delivered.length, 0);
  const dispatch = target.dispatchEvent;
  target.dispatchEvent = (event) => {
    if (event.type === "pointerdown") event.defaultPrevented = true;
    return dispatch(event);
  };
  send("pointerdown");
  send("pointermove");
  send("pointerup");
  assert.deepEqual(
    delivered.map((e) => e.type),
    ["pointerdown", "pointermove", "pointerup"],
  );
});
