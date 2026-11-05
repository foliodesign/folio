import type { FolioRuntime } from "./bridge";
import { keyLabel } from "./key-label";

const tags = new Set([
  "INPUT",
  "TEXTAREA",
  "DIV",
  "SPAN",
  "BODY",
  "BUTTON",
  "SELECT",
  "IFRAME",
]);
const types = new Set([
  "text",
  "password",
  "email",
  "search",
  "url",
  "tel",
  "number",
  "checkbox",
  "radio",
  "button",
  "submit",
  "hidden",
]);
export function observeKeyboardRouting(runtime: FolioRuntime) {
  let enabled = false;
  let generation = 0;
  let sequence = 0;
  const metadata = () => {
    const element = document.activeElement;
    const type = element instanceof HTMLInputElement ? element.type : "";
    return {
      documentFocus: document.hasFocus(),
      tag: element
        ? tags.has(element.tagName)
          ? element.tagName
          : "OTHER"
        : "",
      inputType: type ? (types.has(type) ? type : "other") : "",
      editable:
        (element instanceof HTMLElement && element.isContentEditable) ||
        element instanceof HTMLInputElement ||
        element?.tagName === "TEXTAREA",
      iframe: element?.tagName === "IFRAME",
    };
  };
  const listener = (event: Event) => {
    const key = event instanceof KeyboardEvent ? event : undefined;
    const input = event instanceof InputEvent ? event : undefined;
    const chord = key ? keyLabel(key) : "none";
    const history = input?.inputType ?? "none";
    if (key && !["Cmd+Z", "Cmd+Shift+Z", "Cmd+Y"].includes(chord)) return;
    if (input && !["historyUndo", "historyRedo"].includes(history)) return;
    if (!key && !input) return;
    const token = generation;
    const id = ++sequence;
    const post = (phase: "capture" | "post-dispatch") =>
      runtime.post("folioKeyboardRouting", {
        chord,
        event: event.type,
        phase,
        history,
        sequence: id,
        time: performance.now(),
        alt: key?.altKey ?? false,
        ctrl: key?.ctrlKey ?? false,
        meta: key?.metaKey ?? false,
        shift: key?.shiftKey ?? false,
        repeat: key?.repeat ?? false,
        isComposing: key?.isComposing ?? input?.isComposing ?? false,
        isTrusted: event.isTrusted,
        defaultPrevented: event.defaultPrevented,
        ...metadata(),
      });
    post("capture");
    // Post-dispatch microtask sample only. Never replay or infer history success.
    queueMicrotask(() => {
      if (enabled && generation === token) post("post-dispatch");
    });
  };
  const names = ["keydown", "keyup", "beforeinput", "input"];
  runtime.captureKeyboardFocus = () => {
    if (!enabled) return;
    runtime.post("folioKeyboardRouting", {
      chord: "none",
      event: "snapshot",
      phase: "capture",
      history: "none",
      sequence: ++sequence,
      time: performance.now(),
      alt: false,
      ctrl: false,
      meta: false,
      shift: false,
      repeat: false,
      isComposing: false,
      isTrusted: false,
      defaultPrevented: false,
      ...metadata(),
    });
  };
  const pagehide = () => setEnabled(false);
  const setEnabled = (value: boolean) => {
    if (enabled === value) return;
    enabled = value;
    generation++;
    if (enabled)
      window.addEventListener("pagehide", pagehide, {
        capture: true,
        passive: true,
      });
    else window.removeEventListener("pagehide", pagehide, true);
    for (const name of names) {
      if (enabled)
        window.addEventListener(name, listener, {
          capture: true,
          passive: true,
        });
      else window.removeEventListener(name, listener, true);
    }
  };
  return setEnabled;
}
