import "./bridge";

const handler = globalThis.webkit?.messageHandlers?.memoryProgress;
function setup() {
  if (!handler) return;
  const field = (id: string) => document.getElementById(id) as HTMLInputElement;
  const start = document.getElementById("start") as HTMLButtonElement;
  const stop = document.getElementById("stop") as HTMLButtonElement;
  const result = document.getElementById("result") as HTMLElement;
  let stopped = false;
  let used = false;
  // Keep allocations alive until navigation, including after the stop condition.
  const chunks: Uint8Array[] = [];
  let memory: WebAssembly.Memory | undefined;
  const run = async () => {
    if (used) return;
    const values = [
      Number(field("step").value),
      Number(field("limit").value),
      Number(field("delay").value),
      Number(field("timeout").value),
    ];
    const [step = 0, limit = 0, delay = 0, timeout = 0] = values;
    if (
      !values.every(Number.isInteger) ||
      step < 1 ||
      step > 512 ||
      limit < 1 ||
      limit > 8192 ||
      delay < 50 ||
      delay > 5000 ||
      timeout < 1 ||
      timeout > 600
    ) {
      result.textContent = "Invalid configuration. Check the displayed ranges.";
      return;
    }
    used = true;
    start.disabled = true;
    stop.disabled = false;
    const kind = (document.getElementById("kind") as HTMLSelectElement).value;
    const p = {
      runID: crypto.randomUUID(),
      kind,
      stepMiB: step,
      limitMiB: limit,
      delayMS: delay,
      timeoutSeconds: timeout,
      touchPages: field("touch").checked,
      successfulMiB: 0,
      attemptedMiB: 0,
      status: "started",
    };
    const save = async (status: string) => {
      p.status = status;
      await handler.postMessage(p);
      result.textContent = `${kind}: largest successful ${p.successfulMiB} MiB; attempted ${p.attemptedMiB} MiB; ${status}. Saved natively.`;
    };
    const began = performance.now();
    try {
      await save("started");
      if (kind === "wasm") {
        try {
          memory = new WebAssembly.Memory({ initial: 0 });
        } catch {
          await save("allocation-failed");
          return;
        }
      }
      while (p.successfulMiB < limit) {
        if (stopped || performance.now() - began >= timeout * 1000) break;
        p.attemptedMiB = Math.min(p.successfulMiB + step, limit);
        await save("allocating");
        // Stop/disposal can arrive while the native checkpoint is being written.
        if (stopped || performance.now() - began >= timeout * 1000) {
          await save(stopped ? "stopped" : "timeout");
          return;
        }
        try {
          const bytes = (p.attemptedMiB - p.successfulMiB) * 1048576;
          let array: Uint8Array;
          if (memory) {
            memory.grow(bytes / 65536);
            array = new Uint8Array(
              memory.buffer,
              p.successfulMiB * 1048576,
              bytes,
            );
          } else {
            array = new Uint8Array(bytes);
            chunks.push(array);
          }
          if (p.touchPages)
            for (let i = 0; i < array.length; i += 4096) array[i] = 1;
          p.successfulMiB = p.attemptedMiB;
        } catch {
          await save("allocation-failed");
          return;
        }
        await save("success");
        await new Promise<void>((resolve) => setTimeout(resolve, delay));
      }
      await save(
        stopped ? "stopped" : p.successfulMiB >= limit ? "limit" : "timeout",
      );
    } catch {
      result.textContent =
        "Native persistence failed. Run stopped; inspect diagnostics. Reload before another run.";
    } finally {
      stop.disabled = true;
    }
  };
  const onStart = () => void run();
  const onStop = () => {
    stopped = true;
  };
  start.addEventListener("click", onStart);
  stop.addEventListener("click", onStop);
  if (globalThis.__folio)
    globalThis.__folio.disposeMemoryLab = () => {
      stopped = true;
      start.removeEventListener("click", onStart);
      stop.removeEventListener("click", onStop);
    };
  globalThis.__folioMemorySmoke = async () => {
    field("step").value = "2";
    field("limit").value = "8";
    field("delay").value = "50";
    await run();
  };
}
if (document.readyState === "loading")
  document.addEventListener("DOMContentLoaded", setup, { once: true });
else setup();
