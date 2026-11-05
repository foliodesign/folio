import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const script = await readFile(
  new URL(
    "../../../apps/ios/Folio/Resources/Compat/memory-lab.js",
    import.meta.url,
  ),
  "utf8",
);
function harness(
  kind,
  postMessage = async () => true,
  memoryAPI = WebAssembly,
  now = () => 0,
) {
  const fields = new Map();
  for (const [id, value] of Object.entries({
    kind,
    step: "2",
    limit: "8",
    delay: "50",
    timeout: "60",
    touch: "",
  }))
    fields.set(id, { value, checked: true });
  for (const id of ["start", "stop", "result"])
    fields.set(id, {
      addEventListener(name, listener) {
        this[name] = listener;
      },
      removeEventListener(name) {
        delete this[name];
      },
    });
  const messages = [];
  const context = vm.createContext({
    document: {
      readyState: "complete",
      getElementById: (id) => fields.get(id),
    },
    crypto: { randomUUID: () => "11111111-1111-4111-8111-111111111111" },
    performance: { now },
    WebAssembly: memoryAPI,
    setTimeout: (fn) => {
      fn();
    },
    webkit: {
      messageHandlers: {
        memoryProgress: {
          postMessage: async (p) => {
            messages.push({ ...p });
            return postMessage(p);
          },
        },
      },
    },
  });
  vm.runInContext(script, context);
  return { context, messages, fields };
}
test("TypedArray and WASM stop at cap and await native persistence for each step", async () => {
  for (const kind of ["typed-array", "wasm"]) {
    const { context, messages, fields } = harness(kind);
    await context.__folioMemorySmoke();
    assert.deepEqual(
      messages.map((p) => p.status),
      [
        "started",
        "allocating",
        "success",
        "allocating",
        "success",
        "allocating",
        "success",
        "allocating",
        "success",
        "limit",
      ],
    );
    assert.equal(messages.at(-1).successfulMiB, 8);
    assert.equal(messages.at(-1).attemptedMiB, 8);
    assert.equal(fields.get("stop").disabled, true);
  }
});
test("a rejected checkpoint stops before allocating the next WASM step", async () => {
  let grows = 0;
  const { context, messages, fields } = harness(
    "wasm",
    async (p) => {
      if (p.status === "allocating") throw Error("disk full");
      return true;
    },
    {
      Memory: class {
        grow() {
          grows++;
        }
      },
    },
  );
  await context.__folioMemorySmoke();
  assert.equal(grows, 0);
  assert.deepEqual(
    messages.map((p) => p.status),
    ["started", "allocating"],
  );
  assert.match(fields.get("result").textContent, /Native persistence failed/);
});
test("Memory.grow failure preserves the previous successful size", async () => {
  let bytes = 0;
  const { context, messages } = harness("wasm", async () => true, {
    Memory: class {
      get buffer() {
        return new ArrayBuffer(bytes);
      }
      grow(pages) {
        if (bytes) throw new RangeError();
        bytes += pages * 65536;
      }
    },
  });
  await context.__folioMemorySmoke();
  assert.equal(messages.at(-1).status, "allocation-failed");
  assert.equal(messages.at(-1).successfulMiB, 2);
  assert.equal(messages.at(-1).attemptedMiB, 4);
});

test("disposal while awaiting a checkpoint prevents the next allocation", async () => {
  let grows = 0;
  let context;
  const h = harness(
    "wasm",
    async (p) => {
      if (p.status === "allocating") context.__folio.dispose();
      return true;
    },
    {
      Memory: class {
        grow() {
          grows++;
        }
      },
    },
  );
  context = h.context;
  await context.__folioMemorySmoke();
  assert.equal(grows, 0);
  assert.equal(h.messages.at(-1).status, "stopped");
});

test("an unresolved native checkpoint blocks allocation until it is acknowledged", async () => {
  let acknowledge;
  let bytes = 0;
  let grows = 0;
  const { context, messages } = harness(
    "wasm",
    (p) => {
      if (p.status === "allocating" && !acknowledge)
        return new Promise((resolve) => {
          acknowledge = resolve;
        });
      return Promise.resolve(true);
    },
    {
      Memory: class {
        get buffer() {
          return new ArrayBuffer(bytes);
        }
        grow(pages) {
          grows++;
          bytes += pages * 65536;
        }
      },
    },
  );
  const pending = context.__folioMemorySmoke();
  for (let i = 0; i < 10 && !acknowledge; i++) await Promise.resolve();
  assert.equal(typeof acknowledge, "function");
  assert.equal(messages.at(-1).status, "allocating");
  assert.equal(grows, 0);
  acknowledge(true);
  await pending;
  assert.equal(grows, 4);
  assert.equal(messages.at(-1).status, "limit");
});

test("timeout during checkpoint persistence prevents the pending allocation", async () => {
  let elapsed = 0;
  let grows = 0;
  const { context, messages } = harness(
    "wasm",
    async (p) => {
      if (p.status === "allocating") elapsed = 60000;
      return true;
    },
    {
      Memory: class {
        grow() {
          grows++;
        }
      },
    },
    () => elapsed,
  );
  await context.__folioMemorySmoke();
  assert.equal(grows, 0);
  assert.equal(messages.at(-1).status, "timeout");
  assert.equal(messages.at(-1).successfulMiB, 0);
  assert.equal(messages.at(-1).attemptedMiB, 2);
});

test("raised cap accepts a durable run before allocation and rejects values beyond 8192 MiB", async () => {
  for (const limit of [8192, 8193]) {
    const { fields, messages } = harness("typed-array", async () => {
      throw new Error("Stop before allocating");
    });
    fields.get("limit").value = String(limit);
    fields.get("start").click();
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(messages.length, limit === 8192 ? 1 : 0);
    if (messages.length) assert.equal(messages[0].limitMiB, 8192);
  }
});
