import "./bridge";

// Tier 1 browser environment. No application code, styles, text or input values.
const runtime = globalThis.__folio;
if (runtime && !runtime.setFocusEnvironment) {
  let logging = false;
  let viewport = false;
  let assistant = false;
  let observedHead = false;
  const saved = new Map<HTMLMetaElement, string | null>();
  let added: HTMLMetaElement | undefined;
  const eligible = () =>
    (location.protocol === "https:" &&
      (!location.port || location.port === "443") &&
      ["figma.com", "www.figma.com"].includes(location.hostname) &&
      /^\/(design|file)\/[^/]+/.test(location.pathname)) ||
    (location.protocol === "file:" &&
      location.pathname.endsWith("/Compat/focus-lab.html"));
  const install = () => {
    if (!viewport || !eligible() || !document.head) return;
    if (!observedHead) {
      observer.disconnect();
      observedHead = true;
      observer.observe(document.head, observerOptions);
    }
    let metas = [
      ...document.querySelectorAll<HTMLMetaElement>('meta[name="viewport"]'),
    ];
    if (!metas.length) {
      added = document.createElement("meta");
      added.name = "viewport";
      added.content = "width=device-width, initial-scale=1";
      document.head.append(added);
      metas = [added];
    }
    for (const meta of metas) {
      if (!saved.has(meta)) saved.set(meta, meta.getAttribute("content"));
      const parts = (meta.content || "")
        .split(",")
        .map((p) => p.trim())
        .filter(
          (p) =>
            !/^\s*(maximum-scale|minimum-scale|user-scalable)\s*=/i.test(p),
        );
      const next = [...parts.filter((p) => p.trim()), "maximum-scale=1"].join(
        ", ",
      );
      if (meta.content !== next) meta.content = next;
    }
  };
  const observerOptions: MutationObserverInit = {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["content", "name"],
  };
  const observer = new MutationObserver(install);
  const restore = () => {
    observer.disconnect();
    observedHead = false;
    for (const [meta, content] of saved) {
      if (meta === added) continue;
      if (content === null) meta.removeAttribute("content");
      else meta.setAttribute("content", content);
    }
    saved.clear();
    added?.remove();
    added = undefined;
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
  const snapshot = (event: string, target?: EventTarget | null) => {
    if (!logging) return;
    const element = target instanceof Element ? target : document.activeElement;
    const type = element instanceof HTMLInputElement ? element.type : "";
    const v = window.visualViewport;
    runtime.post("folioFocusLog", {
      event,
      tag: element
        ? tags.has(element.tagName)
          ? element.tagName
          : "OTHER"
        : "",
      inputType: type ? (types.has(type) ? type : "other") : "",
      innerWidth,
      innerHeight,
      width: v?.width ?? innerWidth,
      height: v?.height ?? innerHeight,
      offsetLeft: v?.offsetLeft ?? 0,
      offsetTop: v?.offsetTop ?? 0,
      scale: v?.scale ?? 1,
      scrollX: window.scrollX,
      scrollY: window.scrollY,
      time: performance.now(),
    });
  };
  // Fixed boolean only, independent of logging. A hidden keyboard sink is not an editor.
  let lastEditing: boolean | undefined;
  const reportEditing = () => {
    const element = document.activeElement;
    window.webkit?.messageHandlers?.folioDOMEditorFocused?.postMessage(
      element instanceof HTMLElement &&
        (element.isContentEditable ||
          element instanceof HTMLInputElement ||
          element instanceof HTMLTextAreaElement),
    );
    let editing = false;
    if (
      element instanceof HTMLElement &&
      (element.isContentEditable ||
        element instanceof HTMLTextAreaElement ||
        (element instanceof HTMLInputElement &&
          /^(text|search|url|tel|email|password|number)$/.test(element.type)))
    ) {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      editing =
        rect.width > 1 &&
        rect.height > 1 &&
        rect.right > 0 &&
        rect.bottom > 0 &&
        rect.left < innerWidth &&
        rect.top < innerHeight &&
        style.visibility === "visible" &&
        Number(style.opacity) > 0 &&
        element.checkVisibility({
          opacityProperty: true,
          visibilityProperty: true,
        });
    }
    window.webkit?.messageHandlers?.folioVisibleTextEditing?.postMessage(
      editing,
    );
  };
  const editingObserver = new MutationObserver(reportEditing);
  const watchEditing = () => {
    editingObserver.disconnect();
    for (
      let element = document.activeElement;
      element;
      element = element.parentElement
    ) {
      editingObserver.observe(element, {
        attributes: true,
        attributeFilter: [
          "style",
          "class",
          "hidden",
          "contenteditable",
          "type",
        ],
      });
    }
    reportEditing();
  };
  const focus = (e: Event) => {
    watchEditing();
    // focusout can precede activeElement changing to the next editor.
    queueMicrotask(watchEditing);
    snapshot(e.type, e.target);
    if (assistant && eligible() && e.type === "focusin")
      runtime.post("folioFocusAssist", {});
  };
  const resize = () => {
    reportEditing();
    snapshot("windowresize");
  };
  const scroll = () => snapshot("windowscroll");
  const vr = () => snapshot("viewportresize");
  const vs = () => snapshot("viewportscroll");
  const nav = () => {
    restore();
    if (viewport) watch();
  };
  const watch = () => {
    observer.observe(document.head ?? document, observerOptions);
    observedHead = Boolean(document.head);
    install();
  };
  runtime.setFocusEnvironment = (next, hide) => {
    assistant = hide;
    if (viewport === next) {
      if (!eligible()) restore();
      else if (viewport) watch();
      return;
    }
    restore();
    viewport = next;
    if (viewport) watch();
  };
  runtime.setFocusLogging = (next) => {
    if (logging === next) return;
    logging = next;
    const action = next ? "addEventListener" : "removeEventListener";
    window[action]("scroll", scroll);
    window.visualViewport?.[action]("resize", vr);
    window.visualViewport?.[action]("scroll", vs);
    if (logging) snapshot("logging-enabled");
  };
  // Focus is also a fixed native assistant refresh request when that switch is enabled.
  window.addEventListener("focusin", focus, true);
  window.addEventListener("focusout", focus, true);
  window.addEventListener("popstate", nav);
  window.addEventListener("pageshow", reportEditing);
  window.addEventListener("resize", resize);
  window.addEventListener("DOMContentLoaded", watchEditing);
  runtime.disposeFocusEnvironment = () => {
    runtime.setFocusLogging?.(false);
    restore();
    editingObserver.disconnect();
    window.removeEventListener("pageshow", reportEditing);
    window.removeEventListener("resize", resize);
    window.removeEventListener("DOMContentLoaded", watchEditing);
    window.removeEventListener("focusin", focus, true);
    window.removeEventListener("focusout", focus, true);
    window.removeEventListener("popstate", nav);
    delete runtime.setFocusEnvironment;
    delete runtime.setFocusLogging;
    delete runtime.disposeFocusEnvironment;
  };
}
