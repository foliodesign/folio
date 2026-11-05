import "./bridge";

// Maintainer exception (2026-10-09): Google blocks OAuth in embedded WebKit, so Folio hides
// Figma's "Continue with Google" control on its own login/sign-up pages. Presentation only:
// no Figma script, request, input or form is touched; nothing matches, nothing happens.
const runtime = globalThis.__folio;
if (runtime && !runtime.setHideGoogle) {
  let enabled = false;
  let queued = false;
  const hidden = new Map<HTMLElement, string>();
  const eligible = () =>
    location.protocol === "https:" &&
    (!location.port || location.port === "443") &&
    ["figma.com", "www.figma.com"].includes(location.hostname) &&
    /^\/(login|signup|email_signup|join)(\/|$)/.test(location.pathname);
  const googleName =
    /^(continue|sign in|sign up|log in|login|signup)\s+with\s+google$/i;
  const text = (el: Element) => (el.textContent ?? "").trim();
  const isGoogle = (el: Element) =>
    googleName.test(text(el)) ||
    googleName.test((el.getAttribute("aria-label") ?? "").trim());
  const hide = (el: HTMLElement) => {
    if (hidden.has(el)) return;
    hidden.set(el, el.getAttribute("style") ?? "");
    el.style.setProperty("display", "none", "important");
    el.setAttribute("data-folio-hidden", "google");
  };
  const gone = (el: Element) => hidden.has(el as HTMLElement);
  const controls =
    "button,a,input,form,select,textarea,label,summary,details,iframe,object,embed,audio,video," +
    "[role=button],[role=link],[role=checkbox],[role=radio],[role=switch],[role=textbox]," +
    "[role=combobox],[role=slider],[role=spinbutton],[role=tab],[role=menuitem]," +
    "[role=menuitemcheckbox],[role=menuitemradio],[role=option],[role=treeitem]," +
    "[contenteditable],[tabindex]";
  const hasControls = (el: Element) =>
    el.matches(controls) || el.querySelector(controls) !== null;
  const isDivider = (el: Element) => /^or$/i.test(text(el)) && !hasControls(el);
  const visible = (el: Element): boolean => {
    if (gone(el) || el.hasAttribute("hidden")) return false;
    const style = getComputedStyle(el);
    if (style.display === "none" || style.visibility === "hidden") return false;
    if (
      !Array.from(el.getClientRects()).some((r) => r.width > 0 && r.height > 0)
    )
      return false;
    // A wrapper around the hidden Google control is empty even if it keeps a box.
    return (
      el.matches(controls + ",img,svg,video,canvas,iframe") ||
      Array.from(el.childNodes).some((node) =>
        node instanceof Element
          ? visible(node)
          : node.nodeType === 3 && !!node.textContent?.trim(),
      )
    );
  };
  const adjacent = (from: Element, dir: "previous" | "next") => {
    let el =
      dir === "next" ? from.nextElementSibling : from.previousElementSibling;
    while (el && !visible(el))
      el = dir === "next" ? el.nextElementSibling : el.previousElementSibling;
    return el;
  };
  const hideDivider = (target: HTMLElement) => {
    for (const dir of ["previous", "next"] as const) {
      const sibling = adjacent(target, dir);
      if (!(sibling instanceof HTMLElement) || !isDivider(sibling)) continue;
      // Check both complete sides in the divider's own container, including
      // other visible options inside target's wrapper.
      if (!adjacent(sibling, "previous") || !adjacent(sibling, "next"))
        hide(sibling);
    }
  };
  const scan = () => {
    queued = false;
    if (!enabled || !eligible()) return;
    for (const control of document.querySelectorAll<HTMLElement>(
      "button,a,[role=button]",
    )) {
      if (!isGoogle(control)) continue;
      // Climb to a wrapper that holds only this control (never a form or input).
      let target: HTMLElement = control;
      for (let i = 0; i < 2; i++) {
        const parent = target.parentElement;
        if (
          !parent ||
          parent.matches(controls) ||
          parent.querySelector("input,form,select,textarea") ||
          Array.from(parent.childNodes).some((node) =>
            node instanceof Element
              ? node !== target && !gone(node)
              : node.nodeType === 3 && !!node.textContent?.trim(),
          )
        )
          break;
        target = parent;
      }
      hide(target);
      // Inspect siblings at up to five levels, without entering a form/input
      // ancestor or hiding a wrapper that still contains another option.
      for (
        let level = 0, ancestor: HTMLElement | null = target;
        ancestor && level < 5;
        level++
      ) {
        if (
          ancestor.matches("input,form,select,textarea") ||
          ancestor.querySelector("input,form,select,textarea")
        )
          break;
        hideDivider(ancestor);
        ancestor = ancestor.parentElement;
      }
    }
  };
  const schedule = () => {
    if (queued || !enabled || !eligible()) return;
    queued = true;
    setTimeout(scan, 50);
  };
  const observer = new MutationObserver(schedule);
  const restore = () => {
    for (const [el, style] of hidden) {
      if (style) el.setAttribute("style", style);
      else el.removeAttribute("style");
      el.removeAttribute("data-folio-hidden");
    }
    hidden.clear();
  };
  runtime.setHideGoogle = (value) => {
    enabled = value;
    observer.disconnect();
    if (enabled) {
      observer.observe(document, { childList: true, subtree: true });
      schedule();
    } else restore();
  };
  runtime.disposeHideGoogle = () => {
    runtime.setHideGoogle?.(false);
    delete runtime.setHideGoogle;
    delete runtime.disposeHideGoogle;
  };
}
