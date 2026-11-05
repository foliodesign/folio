import "./bridge";

// Tier 1 candidate: restore browser focus reveal of overflow:hidden ancestors.
// No Figma selectors, functions, focus overrides, input data or capability spoofing.
const runtime = globalThis.__folio;
if (runtime && !runtime.setFocusRevealGuard) {
  let enabled = false;
  let logging = false;
  let listening = false;
  let restored = 0;
  let ignored = 0;
  let armedUntil = 0;
  let focused: HTMLElement | undefined;
  const saved = new Map<Element, { x: number; y: number }>();
  const eligible = () =>
    (location.protocol === "https:" &&
      (!location.port || location.port === "443") &&
      ["figma.com", "www.figma.com"].includes(location.hostname) &&
      /^\/(design|file)\/[^/]+/.test(location.pathname)) ||
    (location.protocol === "file:" &&
      location.pathname.endsWith("/Compat/focus-lab.html"));
  const editable = (el: EventTarget | null): el is HTMLElement =>
    el instanceof HTMLElement &&
    (el.isContentEditable ||
      el instanceof HTMLTextAreaElement ||
      (el instanceof HTMLInputElement &&
        /^(text|search|url|tel|email|password|number)$/.test(el.type)));
  const axes = (el: Element) => {
    const style = getComputedStyle(el);
    return { x: style.overflowX === "hidden", y: style.overflowY === "hidden" };
  };
  const clear = () => {
    saved.clear();
    focused = undefined;
    armedUntil = 0;
  };
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
  const record = (event: string, el: Element, x: number, y: number) => {
    if (!logging) return;
    runtime.post("folioFocusLog", {
      event,
      tag: tags.has(el.tagName) ? el.tagName : "OTHER",
      inputType: "",
      innerWidth,
      innerHeight,
      width: el.clientWidth,
      height: el.clientHeight,
      offsetLeft: x,
      offsetTop: y,
      scale: 1,
      scrollX: window.scrollX,
      scrollY: window.scrollY,
      time: performance.now(),
    });
  };
  const snapshot = (target: EventTarget | null) => {
    clear();
    if (!enabled || !eligible() || !editable(target)) return;
    focused = target;
    for (let el = target.parentElement; el; el = el.parentElement) {
      if (el === document.scrollingElement) continue;
      const h = axes(el);
      if (h.x || h.y) saved.set(el, { x: el.scrollLeft, y: el.scrollTop });
    }
    armedUntil = performance.now() + 250;
  };
  const focusIn = (e: Event) => snapshot(e.target);
  const trigger = () => {
    if (!eligible() || !editable(document.activeElement)) {
      clear();
      return;
    }
    if (document.activeElement !== focused) snapshot(document.activeElement);
    if (saved.size) armedUntil = performance.now() + 250;
  };
  const scroll = (e: Event) => {
    const el = e.target;
    if (
      !(el instanceof Element) ||
      !eligible() ||
      !editable(document.activeElement) ||
      !el.contains(document.activeElement)
    )
      return;
    record("innerscroll", el, el.scrollLeft, el.scrollTop);
    const baseline = saved.get(el);
    if (!enabled || !baseline || focused !== document.activeElement) return;
    if (performance.now() > armedUntil) {
      ignored++;
      // A later editing trigger must not undo a legitimate earlier scroll.
      saved.set(el, { x: el.scrollLeft, y: el.scrollTop });
      return;
    }
    const h = axes(el),
      dx = el.scrollLeft - baseline.x,
      dy = el.scrollTop - baseline.y;
    if (!(h.x && dx) && !(h.y && dy)) return;
    if (h.x && dx) el.scrollLeft = baseline.x;
    if (h.y && dy) el.scrollTop = baseline.y;
    restored++;
    record("revealguard", el, h.x ? dx : 0, h.y ? dy : 0);
  };
  const updateListeners = () => {
    const next = enabled || logging;
    if (next === listening) return;
    listening = next;
    const action = next ? "addEventListener" : "removeEventListener";
    document[action]("focusin", focusIn, true);
    document[action]("focusout", clear, true);
    document[action]("scroll", scroll, true);
    document[action]("selectionchange", trigger, true);
    document[action]("beforeinput", trigger, true);
    document[action]("keydown", trigger, true);
    window[action]("blur", clear);
    window[action]("pagehide", clear);
    window[action]("popstate", clear);
  };
  runtime.setFocusRevealGuard = (next) => {
    if (enabled === next) return;
    enabled = next;
    clear();
    updateListeners();
    if (next) snapshot(document.activeElement);
  };
  runtime.setFocusRevealLogging = (next) => {
    logging = next;
    updateListeners();
  };
  runtime.focusRevealGuardStats = () => ({ restored, ignored });
  runtime.disposeFocusRevealGuard = () => {
    enabled = logging = false;
    updateListeners();
    clear();
    delete runtime.setFocusRevealGuard;
    delete runtime.setFocusRevealLogging;
    delete runtime.focusRevealGuardStats;
    delete runtime.disposeFocusRevealGuard;
  };
}
