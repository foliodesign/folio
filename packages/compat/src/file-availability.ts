// Explicit read-only check in FolioDiagnostics after a retained file reload.
// Only a boolean leaves this world. Never inspect inputs or log page text.
export const isUnavailableFilePage = (doc: Document): boolean => {
  if (doc.querySelector("canvas, .gpu-view-content")) return false;
  const visible = (el: HTMLElement) => {
    const box = el.getBoundingClientRect();
    const css = getComputedStyle(el);
    return (
      box.width > 0 &&
      box.height > 0 &&
      css.display !== "none" &&
      css.visibility !== "hidden"
    );
  };
  const fixedText = (el: Element) =>
    (el.textContent ?? "")
      .slice(0, 256)
      .replace(/\u2019/g, "'")
      .replace(/\s+/g, " ")
      .trim();
  // These exact UI labels are observed in the maintainer's not-found screenshot.
  // Do not guess CSS-module names from a normal-editor DOM capture. Other languages
  // fail closed until their error-card structure is verified.
  const heading = Array.from(
    doc.querySelectorAll<HTMLElement>("h1, h2, h3, [role=heading], div, span"),
  )
    .slice(0, 400)
    .find(
      (el) =>
        el.childElementCount <= 1 &&
        visible(el) &&
        fixedText(el) === "Hmm, we couldn't find that one",
    );
  if (!heading) return false;
  let card = heading.parentElement;
  for (let depth = 0; card && depth < 5; depth++, card = card.parentElement) {
    const box = card.getBoundingClientRect();
    const css = getComputedStyle(card);
    const radius = parseFloat(css.borderRadius);
    if (
      !visible(card) ||
      box.width < 240 ||
      box.width > 900 ||
      box.height < 160 ||
      !Number.isFinite(radius) ||
      radius < 4 ||
      !css.boxShadow ||
      css.boxShadow === "none"
    )
      continue;
    const back = Array.from(
      card.querySelectorAll<HTMLElement>("a, button, [role=button]"),
    )
      .slice(0, 32)
      .some((el) => visible(el) && fixedText(el) === "Go back to Figma");
    if (back) return true;
  }
  return false;
};
// Positive editor evidence is independent of the slower not-found checks. Observe
// mounted DOM only, stop within one second, and return no page data.
export const waitForFileCanvas = (doc: Document): Promise<boolean> => {
  const mounted = () => Boolean(doc.querySelector("canvas, .gpu-view-content"));
  if (mounted()) return Promise.resolve(true);
  return new Promise((resolve) => {
    const deadline = performance.now() + 1_000;
    let finished = false;
    const finish = (healthy: boolean) => {
      if (finished) return;
      finished = true;
      observer.disconnect();
      clearTimeout(timer);
      resolve(healthy);
    };
    const observer = new MutationObserver(() => {
      if (performance.now() >= deadline) finish(false);
      else if (mounted()) finish(true);
    });
    const timer = setTimeout(() => finish(false), 1_000);
    observer.observe(doc, { childList: true, subtree: true });
    if (mounted()) finish(true);
  });
};
Object.assign(globalThis, {
  __folioUnavailableFile: () => isUnavailableFilePage(document),
  __folioWaitForFileCanvas: () => waitForFileCanvas(document),
});
