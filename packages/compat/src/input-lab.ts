import { keyLabel } from "./key-label";
import {
  inputItems,
  summarize,
  type InputItem,
  type Verdict,
} from "./lab-results";
const runtime = globalThis.__folio;
// Never install a UI, read form text, or log printable shortcuts on a network page.
if (
  runtime &&
  location.protocol === "file:" &&
  location.pathname.endsWith("/Compat/input-lab.html")
) {
  const controller = new AbortController();
  runtime.disposeLab = () => {
    controller.abort();
    delete runtime.setLabStrategy;
    delete runtime.disposeLab;
  };
  const start = () => {
    if (controller.signal.aborted) return;
    const listen = <E extends Event>(
      target: EventTarget,
      name: string,
      listener: (event: E) => void,
      options: AddEventListenerOptions = {},
    ) => {
      target.addEventListener(name, listener as EventListener, {
        ...options,
        signal: controller.signal,
      });
    };
    const element = <T extends HTMLElement>(id: string) => {
      const node = document.getElementById(id);
      if (!node) throw new Error(`Missing lab element ${id}`);
      return node as T;
    };
    const events = element<HTMLPreElement>("events");
    const lines: string[] = [];
    const results = Object.fromEntries(
      inputItems.map((item) => [item, "NOT TESTED"]),
    ) as Record<InputItem, Verdict>;
    const selects: HTMLSelectElement[] = [];
    const summary = element<HTMLTextAreaElement>("summary");
    let strategy = "Awaiting native strategy";
    const publish = () => {
      summary.value = `Folio input lab\n${strategy}\n${summarize(results)}`;
      runtime.post("folioLabResults", { results });
    };
    for (const item of inputItems) {
      const label = document.createElement("label");
      label.textContent = item;
      const select = document.createElement("select");
      select.disabled = item === "text-layer editing";
      select.setAttribute("aria-label", `${item} verdict`);
      for (const verdict of ["NOT TESTED", "PASS", "FAIL"] as const) {
        const option = document.createElement("option");
        option.value = verdict;
        option.textContent = verdict;
        select.append(option);
      }
      listen(select, "change", () => {
        results[item] = select.value as Verdict;
        publish();
      });
      label.append(select);
      element("results").append(label);
      selects.push(select);
    }
    const reset = () => {
      for (const item of inputItems) results[item] = "NOT TESTED";
      for (const select of selects) select.value = "NOT TESTED";
      publish();
    };
    runtime.setLabStrategy = (label) => {
      if (strategy === label) return;
      strategy = label;
      element("strategy").textContent = label;
      reset();
    };
    listen(element("reset-results"), "click", reset);
    listen(element("copy-summary"), "click", () => {
      summary.focus();
      summary.select();
      // Local file pages may not have Clipboard API permission. Selection remains copyable.
      const copied = document.execCommand("copy");
      element("copy-status").textContent = copied
        ? "Summary copied"
        : "Select summary and Copy, or use diagnostics Copy report";
    });
    const names = [
      "pointerdown",
      "pointermove",
      "pointerup",
      "pointercancel",
      "pointerover",
      "pointerout",
      "gotpointercapture",
      "lostpointercapture",
      "touchstart",
      "touchmove",
      "touchend",
      "touchcancel",
      "mousedown",
      "mousemove",
      "mouseup",
      "click",
      "wheel",
      "dblclick",
      "gesturestart",
      "gesturechange",
      "gestureend",
      "keydown",
      "keyup",
    ];
    for (const name of names)
      listen(
        window,
        name,
        (event) => {
          const p = event instanceof PointerEvent ? event : undefined;
          const m = event instanceof MouseEvent ? event : undefined;
          const t = event instanceof TouchEvent ? event : undefined;
          const k = event instanceof KeyboardEvent ? event : undefined;
          const w = event instanceof WheelEvent ? event : undefined;
          const line = `${event.type} pointerType=${p?.pointerType ?? (t ? "touch" : m ? "mouse" : "none")} isTrusted=${event.isTrusted} buttons=${m?.buttons ?? 0} pressure=${p?.pressure ?? t?.changedTouches[0]?.force ?? 0} tilt=${p?.tiltX ?? 0},${p?.tiltY ?? 0} coalesced=${p?.getCoalescedEvents?.().length ?? 0} touches=${t?.touches.length ?? 0} xy=${m?.clientX ?? t?.changedTouches[0]?.clientX ?? 0},${m?.clientY ?? t?.changedTouches[0]?.clientY ?? 0} wheel=${w?.deltaX ?? 0},${w?.deltaY ?? 0} key=${k ? keyLabel(k) : ""} modifiers=${m?.metaKey || k?.metaKey ? "Cmd " : ""}${m?.shiftKey || k?.shiftKey ? "Shift " : ""}${m?.altKey || k?.altKey ? "Alt " : ""}${m?.ctrlKey || k?.ctrlKey ? "Ctrl" : ""}`;
          lines.push(line);
          if (lines.length > 100) lines.shift();
          events.textContent = lines.join("\n");
          events.scrollTop = events.scrollHeight;
          if (k)
            element("key-status").textContent =
              `${k.type}: ${keyLabel(k)} isTrusted=${k.isTrusted}`;
        },
        { capture: true, passive: true },
      );
    const canvas = element<HTMLCanvasElement>("draw");
    const ctx = canvas.getContext("2d");
    const points = new Map<number, { x: number; y: number }>();
    const xy = (event: PointerEvent) => {
      const r = canvas.getBoundingClientRect();
      return {
        x: ((event.clientX - r.left) * canvas.width) / r.width,
        y: ((event.clientY - r.top) * canvas.height) / r.height,
      };
    };
    listen<PointerEvent>(canvas, "pointerdown", (event) => {
      points.set(event.pointerId, xy(event));
      try {
        canvas.setPointerCapture(event.pointerId);
      } catch {
        element("drag-status").textContent =
          "Pointer capture rejected for this event";
      }
    });
    listen<PointerEvent>(canvas, "pointermove", (event) => {
      let last = points.get(event.pointerId);
      if (!last || !ctx) return;
      const samples = event.getCoalescedEvents?.() ?? [];
      for (const sample of samples.length ? samples : [event]) {
        const next = xy(sample);
        ctx.beginPath();
        ctx.moveTo(last.x, last.y);
        ctx.lineTo(next.x, next.y);
        ctx.lineWidth = 3;
        ctx.strokeStyle = event.isTrusted ? "#165c92" : "#b24d00";
        ctx.stroke();
        last = next;
      }
      points.set(event.pointerId, last);
    });
    for (const name of ["pointerup", "pointercancel", "lostpointercapture"])
      listen(canvas, name, (event) => {
        if (event instanceof PointerEvent) points.delete(event.pointerId);
      });
    const box = element("pointer-box");
    let drag:
      | { id: number; x: number; y: number; left: number; top: number }
      | undefined;
    listen<PointerEvent>(box, "pointerdown", (event) => {
      drag = {
        id: event.pointerId,
        x: event.clientX,
        y: event.clientY,
        left: box.offsetLeft,
        top: box.offsetTop,
      };
      try {
        box.setPointerCapture(event.pointerId);
      } catch {
        element("drag-status").textContent =
          "Pointer capture rejected for this event";
      }
    });
    listen<PointerEvent>(box, "pointermove", (event) => {
      if (drag?.id !== event.pointerId) return;
      box.style.left = `${drag.left + event.clientX - drag.x}px`;
      box.style.top = `${drag.top + event.clientY - drag.y}px`;
    });
    for (const name of ["pointerup", "pointercancel", "lostpointercapture"])
      listen(box, name, (event) => {
        if (!(event instanceof PointerEvent) || drag?.id !== event.pointerId)
          return;
        element("drag-status").textContent =
          `Pointer ${event.type}; box ${box.offsetLeft},${box.offsetTop}; trusted=${event.isTrusted}`;
        drag = undefined;
      });
    const mouseBox = element("mouse-box");
    let mouseDrag:
      | { x: number; y: number; left: number; top: number }
      | undefined;
    listen<MouseEvent>(mouseBox, "mousedown", (event) => {
      mouseDrag = {
        x: event.clientX,
        y: event.clientY,
        left: mouseBox.offsetLeft,
        top: mouseBox.offsetTop,
      };
    });
    listen<MouseEvent>(window, "mousemove", (event) => {
      if (!mouseDrag) return;
      mouseBox.style.left = `${mouseDrag.left + event.clientX - mouseDrag.x}px`;
      mouseBox.style.top = `${mouseDrag.top + event.clientY - mouseDrag.y}px`;
    });
    listen<MouseEvent>(window, "mouseup", (event) => {
      if (!mouseDrag) return;
      element("drag-status").textContent =
        `Mouse up; box ${mouseBox.offsetLeft},${mouseBox.offsetTop}; trusted=${event.isTrusted}`;
      mouseDrag = undefined;
    });
    listen(window, "blur", () => {
      mouseDrag = undefined;
      drag = undefined;
      points.clear();
    });
    const hover = element("hover");
    listen<PointerEvent>(hover, "pointermove", (event) => {
      const hovering = event.buttons === 0 && event.pointerType !== "touch";
      hover.classList.toggle("active", hovering);
      hover.textContent = `${event.pointerType} ${hovering ? "hover" : "contact"}; trusted=${event.isTrusted}`;
    });
    listen(hover, "pointerleave", () => {
      hover.classList.remove("active");
      hover.textContent = "Hover left";
    });
    const scroll = element("scroll-zone");
    listen(scroll, "scroll", () => {
      element("scroll-status").textContent =
        `Scroll ${scroll.scrollLeft}, ${scroll.scrollTop}`;
    });
    listen(element("text-field"), "input", () => {
      element("text-status").textContent =
        "Text input event received, value not logged";
    });
    listen(element("focus-page"), "click", () => {
      (document.activeElement as HTMLElement | null)?.blur();
    });
    listen(element("clear-events"), "click", () => {
      lines.length = 0;
      events.textContent = "";
      ctx?.clearRect(0, 0, canvas.width, canvas.height);
    });
    publish();
  };
  if (document.readyState === "loading")
    document.addEventListener("DOMContentLoaded", start, {
      once: true,
      signal: controller.signal,
    });
  else start();
}
